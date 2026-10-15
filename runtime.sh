#!/bin/bash
set -euo pipefail

GLOBAL_ROOTFS="/var/lib/k8s-from-scratch/rootfs"
POD_STATE_DIR="/var/lib/k8s-from-scratch/pods"
NAMESPACE_DIR="/run/k8s-from-scratch"

if [[ -v ROOTFS && -n "$ROOTFS" ]]; then
    GLOBAL_ROOTFS="$ROOTFS"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/namespace.sh"
source "${SCRIPT_DIR}/lib/json.sh"

runtime_start() {
    local pod_name="$1"
    shift
    # remaining args: -- <executable> [args...]
    if [[ "${1:-}" == "--" ]]; then shift; fi

    local cmd_args=("$@")

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        echo "[runtime] No command given for pod '$pod_name'." >&2
        return 1
    fi

    local pod_dir="${POD_STATE_DIR}/${pod_name}"
    local ns_dir="${NAMESPACE_DIR}/${pod_name}"
    local ns_uts_path="${ns_dir}/uts"
    local rootfs_path="${pod_dir}/rootfs"
    local pod_log="${pod_dir}/log"

    rm -rf "$pod_dir"
    mkdir -p "$pod_dir"
    mkdir -p "$ns_dir"

    # Create the bind-mount target file — unshare requires it to exist.
    touch "$ns_uts_path"

    cp -a "$GLOBAL_ROOTFS" "$rootfs_path"

    local started_at
    started_at=$(date +%s)

    run_isolated "$pod_name" "$ns_uts_path" "$rootfs_path" "${cmd_args[@]}" \
        </dev/null >"$pod_log" 2>&1 &
    local unshare_pid=$!

    # Give the process a moment to either establish its namespace or exit.
    sleep 0.2

    if ! kill -0 "$unshare_pid" 2>/dev/null; then
        local exit_code=0
        wait "$unshare_pid" 2>/dev/null || exit_code=$?
        local exited_at
        exited_at=$(date +%s)
        rm -f "$ns_uts_path"
        rmdir "$ns_dir" 2>/dev/null || true
        json_build_status "exited" "$started_at" "$exited_at" "$exit_code" "$pod_log"
        return 0
    fi

    json_build_status "running" "$started_at" null null "$pod_log"
}

runtime_stop() {
    local pod_name="$1"
    local ns_uts_path="${NAMESPACE_DIR}/${pod_name}/uts"
    local pod_dir="${POD_STATE_DIR}/${pod_name}"

    if [[ -f "$ns_uts_path" ]]; then
        local ns_inode
        ns_inode=$(stat -c %i "$ns_uts_path" 2>/dev/null) || true

        if [[ -n "$ns_inode" ]]; then
            local pid_ns_path pid
            for pid_ns_path in /proc/[0-9]*/ns/uts; do
                [[ -e "$pid_ns_path" ]] || continue
                pid=$(echo "$pid_ns_path" | grep -oE '[0-9]+')
                if [[ $(stat -c %i "$pid_ns_path" 2>/dev/null) == "$ns_inode" ]]; then
                    kill -SIGKILL "$pid" 2>/dev/null || true
                fi
            done
        fi

        rm -f "$ns_uts_path"
        rmdir "${NAMESPACE_DIR}/${pod_name}" 2>/dev/null || true
    fi

    rm -rf "$pod_dir"
}

runtime_status() {
    local pod_name="$1"
    local ns_uts_path="${NAMESPACE_DIR}/${pod_name}/uts"

    if [[ -f "$ns_uts_path" ]]; then
        echo "running"
    else
        echo "exited"
    fi
}

main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 start <pod-name> -- <cmd> [args...] | stop <pod-name> | status <pod-name>" >&2
        return 1
    fi

    local action="$1"
    shift

    case "$action" in
        start)  runtime_start  "$@" ;;
        stop)   runtime_stop   "$1" ;;
        status) runtime_status "$1" ;;
        *)
            echo "Unknown action: $action" >&2
            return 1
            ;;
    esac
}

main "$@"
