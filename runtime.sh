#!/bin/bash
set -euo pipefail

GLOBAL_ROOTFS="/var/lib/k8s-from-scratch/rootfs"
POD_STATE_DIR="/var/lib/k8s-from-scratch/pods"

if [[ -v CONTAINER_ROOTFS && -n "$CONTAINER_ROOTFS" ]]; then
    GLOBAL_ROOTFS="$CONTAINER_ROOTFS"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/meta.sh"
source "${SCRIPT_DIR}/lib/namespace.sh"
source "${SCRIPT_DIR}/lib/json.sh"

runtime_start() {
    local pod_name="$1"
    local pod_dir="${POD_STATE_DIR}/${pod_name}"
    local container_spec_file="${pod_dir}/container-spec.json"

    if [[ ! -f "$container_spec_file" ]]; then
        echo "[runtime] container-spec.json not found for pod '$pod_name'." >&2
        return 1
    fi

    local container_spec
    container_spec=$(cat "$container_spec_file")

    local container_name rootfs_path
    container_name=$(json_get_field "$container_spec" "name")
    rootfs_path=$(json_get_field "$container_spec" "rootfs")

    local cmd_args=()
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && cmd_args+=("$arg")
    done <<< "$(json_get_container_command "$container_spec")"

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        echo "[runtime] No command in container spec for pod '$pod_name'." >&2
        return 1
    fi

    cp -a "$GLOBAL_ROOTFS" "$rootfs_path"

    local pod_log="${pod_dir}/log"
    local started_at
    started_at=$(date +%s)

    write_meta "$pod_dir" state "starting"
    write_meta "$pod_dir" started_at "$started_at"

    run_isolated "$container_name" "$rootfs_path" "${cmd_args[@]}" </dev/null >"$pod_log" 2>&1 &
    local unshare_pid=$!

    local unshare_start
    unshare_start=$(read_pid_start "$unshare_pid")
    write_meta "$pod_dir" unshare_pid "$unshare_pid"
    write_meta "$pod_dir" unshare_start "$unshare_start"

    local workload_pid=""
    if workload_pid=$(find_workload_pid "$unshare_pid"); then
        local workload_start
        workload_start=$(read_pid_start "$workload_pid")
        write_meta "$pod_dir" workload_pid "$workload_pid"
        write_meta "$pod_dir" workload_start "$workload_start"
    else
        write_meta "$pod_dir" workload_pid ""
        write_meta "$pod_dir" workload_start ""
        workload_pid=""
    fi

    if ! kill -0 "$unshare_pid" 2>/dev/null; then
        local exit_code=0
        wait "$unshare_pid" 2>/dev/null || exit_code=$?
        local exited_at
        exited_at=$(date +%s)
        write_meta "$pod_dir" state "exited"
        write_meta "$pod_dir" exited_at "$exited_at"
        write_meta "$pod_dir" exit_code "$exit_code"
        return 0
    fi

    write_meta "$pod_dir" state "running"
}

runtime_stop() {
    local pod_name="$1"
    local pod_dir="${POD_STATE_DIR}/${pod_name}"

    if [[ -d "$pod_dir" ]]; then
        local workload_pid workload_start
        workload_pid=$(read_meta "$pod_dir" workload_pid)
        workload_start=$(read_meta "$pod_dir" workload_start)

        if [[ -n "$workload_pid" ]] && pid_is_ours "$workload_pid" "$workload_start"; then
            kill -SIGKILL "$workload_pid" 2>/dev/null || true
            local i
            for (( i = 0; i < 20; i++ )); do
                pid_is_ours "$workload_pid" "$workload_start" || break
                sleep 0.1
            done
        fi

        rm -rf "$pod_dir"
    fi
}

main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 start <pod-name> | stop <pod-name>" >&2
        return 1
    fi

    local action="$1" pod_name="$2"

    case "$action" in
        start) runtime_start "$pod_name" ;;
        stop)  runtime_stop  "$pod_name" ;;
        *)
            echo "Unknown action: $action" >&2
            return 1
            ;;
    esac
}

main "$@"
