#!/bin/bash
set -euo pipefail

ETCD_DIR="/var/lib/k8s-from-scratch/etcd"
POD_STATE_DIR="/var/lib/k8s-from-scratch/pods"
KUBELET_LOG="/var/log/kubelet.log"
RECONCILE_INTERVAL=5

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SCRIPT="${SCRIPT_DIR}/runtime.sh"

source "${SCRIPT_DIR}/lib/etcd-client.sh"
source "${SCRIPT_DIR}/lib/json.sh"
source "${SCRIPT_DIR}/lib/validate.sh"
source "${SCRIPT_DIR}/lib/meta.sh"

mkdir -p "$(dirname "$KUBELET_LOG")"
log() { echo "[kubelet] $*" | tee -a "$KUBELET_LOG"; }

_launch() {
    local pod_name="$1"
    local spec_json="$2"

    local container_name
    container_name=$(json_get_container_name "$spec_json")

    local cmd_args=()
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && cmd_args+=("$arg")
    done <<< "$(json_get_container_command "$spec_json")"

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        log "Pod '$pod_name' has no command in spec, skipping." >&2
        return 1
    fi

    local pod_dir
    pod_dir=$(pod_dir "$pod_name")
    rm -rf "$pod_dir"
    mkdir -p "$pod_dir"

    local rootfs_path="${pod_dir}/rootfs"
    local pod_log="${pod_dir}/log"
    local started_at
    started_at=$(date +%s)

    json_build_container_spec "$container_name" "$rootfs_path" "${cmd_args[@]}" \
        > "${pod_dir}/container-spec.json"

    etcd_put "pods/${pod_name}/status" \
        "$(json_build_status "starting" "$started_at" null null null "$pod_log")"

    "$RUNTIME_SCRIPT" start "$pod_name"

    local state
    state=$(read_meta "$pod_dir" state)

    if [[ "$state" == "running" ]]; then
        local workload_pid
        workload_pid=$(read_meta "$pod_dir" workload_pid)
        started_at=$(read_meta "$pod_dir" started_at)
        etcd_put "pods/${pod_name}/status" \
            "$(json_build_status "running" "$started_at" null null "$workload_pid" "$pod_log")"
        log "Pod '$pod_name' started (PID $workload_pid)."
    else
        local exit_code exited_at
        exit_code=$(read_meta "$pod_dir" exit_code)
        exited_at=$(read_meta "$pod_dir" exited_at)
        started_at=$(read_meta "$pod_dir" started_at)
        etcd_put "pods/${pod_name}/status" \
            "$(json_build_status "exited" "$started_at" "$exited_at" "$exit_code" null "$pod_log")"
        log "Pod '$pod_name' exited immediately (code $exit_code)."
    fi
}

_delete_pod() {
    local pod_name="$1"
    "$RUNTIME_SCRIPT" stop "$pod_name"
    rm -rf "${ETCD_DIR}/pods/${pod_name}"
    log "Pod '$pod_name' deleted."
}

reconcile_once() {
    local keys
    keys=$(etcd_list "pods") || true
    [[ -z "$keys" ]] && return 0

    local names=()
    local key pod_name
    while IFS= read -r key; do
        [[ "$key" == */spec ]] || continue
        pod_name=$(echo "$key" | sed 's|^pods/||;s|/spec$||')
        names+=("$pod_name")
    done <<< "$keys"

    local spec_json actual_state pod_dir
    for pod_name in "${names[@]:-}"; do
        [[ -z "$pod_name" ]] && continue

        # deletion branch: always checked first
        if etcd_get "pods/${pod_name}/deleting" >/dev/null 2>&1; then
            _delete_pod "$pod_name"
            continue
        fi

        spec_json=$(etcd_get "pods/${pod_name}/spec" 2>/dev/null) || continue

        pod_dir=$(pod_dir "$pod_name")
        actual_state=$(read_actual_state "$pod_dir")

        if [[ "$actual_state" == "running" ]]; then
            local status_json etcd_state
            status_json=$(etcd_get "pods/${pod_name}/status" 2>/dev/null) || true
            etcd_state=$(json_get_field "$status_json" "state")
            if [[ "$etcd_state" != "running" ]]; then
                local started_at workload_pid pod_log
                started_at=$(read_meta "$pod_dir" started_at)
                workload_pid=$(read_meta "$pod_dir" workload_pid)
                pod_log="${pod_dir}/log"
                etcd_put "pods/${pod_name}/status" \
                    "$(json_build_status "running" "$started_at" null null "$workload_pid" "$pod_log")"
            fi
            continue
        fi

        # exited or not_started: (re)launch
        log "Pod '$pod_name' is '$actual_state', launching."
        _launch "$pod_name" "$spec_json"
    done
}

log "Starting. Reconcile interval: ${RECONCILE_INTERVAL}s"
log "Press Ctrl+C to stop."

while true; do
    reconcile_once
    sleep "$RECONCILE_INTERVAL"
done
