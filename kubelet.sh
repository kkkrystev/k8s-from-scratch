#!/bin/bash
set -euo pipefail

ETCD_DIR="/var/lib/k8s-from-scratch/etcd"
CONTAINER_STATE_DIR="/var/lib/k8s-from-scratch/containers"
ROOTFS="/var/lib/k8s-from-scratch/rootfs"
RECONCILE_INTERVAL=5

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/etcd-client.sh"
source "${SCRIPT_DIR}/lib/json.sh"
source "${SCRIPT_DIR}/lib/validate.sh"
source "${SCRIPT_DIR}/lib/meta.sh"
source "${SCRIPT_DIR}/lib/namespace.sh"

_launch() {
    local name="$1"
    local spec_json="$2"

    local cmd_json cmd_args=()
    cmd_json=$(json_get_command "$spec_json")
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && cmd_args+=("$arg")
    done <<< "$cmd_json"

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        echo "[kubelet] Pod '$name' has no command in spec, skipping." >&2
        return 1
    fi

    local cdir
    cdir=$(container_dir "$name")
    rm -rf "$cdir"
    mkdir -p "$cdir"

    write_command "$cdir" "${cmd_args[@]}"
    write_meta "$cdir" state "starting"
    write_meta "$cdir" started_at "$(date +%s)"

    local log="${cdir}/log"
    local started_at
    started_at=$(read_meta "$cdir" started_at)

    etcd_put "containers/${name}/status" \
        "$(json_build_status "starting" "$started_at" null null null "$log")"

    run_isolated "$name" "${cmd_args[@]}" </dev/null >"$log" 2>&1 &
    local unshare_pid=$!

    local ustart
    ustart=$(read_pid_start "$unshare_pid")
    write_meta "$cdir" unshare_pid "$unshare_pid"
    write_meta "$cdir" unshare_start "$ustart"

    local workload_pid=""
    if workload_pid=$(find_workload_pid "$unshare_pid"); then
        local wstart
        wstart=$(read_pid_start "$workload_pid")
        write_meta "$cdir" workload_pid "$workload_pid"
        write_meta "$cdir" workload_start "$wstart"
    else
        write_meta "$cdir" workload_pid ""
        write_meta "$cdir" workload_start ""
        workload_pid=""
    fi

    if ! kill -0 "$unshare_pid" 2>/dev/null; then
        local exit_code=0
        wait "$unshare_pid" 2>/dev/null || exit_code=$?
        local exited_at
        exited_at=$(date +%s)
        write_meta "$cdir" state "exited"
        write_meta "$cdir" exited_at "$exited_at"
        write_meta "$cdir" exit_code "$exit_code"
        etcd_put "containers/${name}/status" \
            "$(json_build_status "exited" "$started_at" "$exited_at" "$exit_code" "$workload_pid" "$log")"
        echo "[kubelet] Pod '$name' exited immediately (code $exit_code)."
        return 0
    fi

    write_meta "$cdir" state "running"
    etcd_put "containers/${name}/status" \
        "$(json_build_status "running" "$started_at" null null "$workload_pid" "$log")"
    echo "[kubelet] Pod '$name' started (PID ${workload_pid:-${unshare_pid}})."
}

_delete_pod() {
    local name="$1"
    local cdir
    cdir=$(container_dir "$name")

    if [[ -d "$cdir" ]]; then
        local wpid wstart
        wpid=$(read_meta "$cdir" workload_pid)
        wstart=$(read_meta "$cdir" workload_start)
        if [[ -n "$wpid" ]] && pid_is_ours "$wpid" "$wstart"; then
            kill -SIGKILL "$wpid" 2>/dev/null || true
            local i
            for (( i = 0; i < 20; i++ )); do
                pid_is_ours "$wpid" "$wstart" || break
                sleep 0.1
            done
        fi
        rm -rf "$cdir"
    fi

    etcd_delete "containers/${name}/spec"
    etcd_delete "containers/${name}/status"
    etcd_delete "containers/${name}/deleting"
    echo "[kubelet] Pod '$name' deleted."
}

reconcile_once() {
    local keys
    keys=$(etcd_list "containers") || true
    [[ -z "$keys" ]] && return 0

    local names=()
    local key name
    while IFS= read -r key; do
        [[ "$key" == */spec ]] || continue
        name=$(echo "$key" | sed 's|^containers/||;s|/spec$||')
        names+=("$name")
    done <<< "$keys"

    local spec_json actual cdir
    for name in "${names[@]:-}"; do
        [[ -z "$name" ]] && continue

        # deletion branch: always checked first
        if etcd_get "containers/${name}/deleting" >/dev/null 2>&1; then
            _delete_pod "$name"
            continue
        fi

        spec_json=$(etcd_get "containers/${name}/spec" 2>/dev/null) || continue

        cdir=$(container_dir "$name")
        actual=$(read_actual_state "$cdir")

        if [[ "$actual" == "running" ]]; then
            # correct stale etcd status if needed
            local etcd_state
            etcd_state=$(etcd_get "containers/${name}/status" 2>/dev/null \
                | (grep -o '"state":"[^"]*"' || true) \
		| sed 's/"state":"//;s/"//')
            if [[ "$etcd_state" != "running" ]]; then
                local started_at wpid log
                started_at=$(read_meta "$cdir" started_at)
                wpid=$(read_meta "$cdir" workload_pid)
                log=$(read_meta "$cdir" log 2>/dev/null || echo "${cdir}/log")
                etcd_put "containers/${name}/status" \
                    "$(json_build_status "running" "$started_at" null null "$wpid" "$log")"
            fi
            continue
        fi

        # exited or not_started: (re)launch
        echo "[kubelet] Pod '$name' is '$actual', launching."
        _launch "$name" "$spec_json"
    done
}

echo "[kubelet] Starting. Reconcile interval: ${RECONCILE_INTERVAL}s"
echo "[kubelet] Press Ctrl+C to stop."

while true; do
    reconcile_once
    sleep "$RECONCILE_INTERVAL"
done
