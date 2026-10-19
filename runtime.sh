#!/bin/bash
set -euo pipefail

GLOBAL_ROOTFS="${ROOTFS:-/var/lib/k8s-from-scratch/rootfs}"
POD_STATE_DIR="${POD_STATE_DIR:-/var/lib/k8s-from-scratch/pods}"
NAMESPACE_DIR="${NAMESPACE_DIR:-/run/k8s-from-scratch}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/namespace.sh"
source "$SCRIPT_DIR/lib/json.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/network.sh"

runtime_status() {
    local name="$1" identity members pid role actual_root expected_root
    identity=$(namespace_mount_identity "$NAMESPACE_DIR/$name/uts") || return 1
    if [[ -z "$identity" ]]; then echo exited; return 0; fi
    members=$(namespace_processes "$identity") || return 1
    while read -r pid role; do
        [[ "$role" == init ]] || continue
        # PID 1 must have reached chroot, not just the setup shell.
        expected_root=$(namespace_identity "$POD_STATE_DIR/$name/rootfs") || return 1
        if actual_root=$(namespace_identity "/proc/$pid/root" 2>/dev/null) &&
           [[ "$actual_root" == "$expected_root" ]]; then
            echo running
            return 0
        fi
    done <<< "$members"
    echo exited
}

runtime_release_namespace() {
    local name="$1" identity members pid role current attempt
    local ns_dir="$NAMESPACE_DIR/$name"
    local fifo="$POD_STATE_DIR/$name/net-ready"

    # Detach network before killing processes — the veth lives independently.
    net_detach_pod "$name" || return 1

    # Remove FIFO if the workload never consumed it (e.g. wiring failed).
    [[ -p "$fifo" ]] && rm -f "$fifo"

    identity=$(namespace_mount_identity "$ns_dir/uts") || return 1
    if [[ -n "$identity" ]]; then
        # SIGKILL is deliberate: keep the project's force-stop semantics.
        # Killing the wrapper also kills its child (--kill-child).
        for ((attempt=0; attempt<50; attempt++)); do
            members=$(namespace_processes "$identity") || return 1
            [[ -n "$members" ]] || break
            while read -r pid role; do
                # Recheck immediately before signaling. A small PID-reuse race
                # still exists; Bash does not provide pidfd-based signaling.
                if ! current=$(namespace_identity "/proc/$pid/ns/uts" 2>/dev/null); then
                    continue  # Next scan distinguishes exit from inspection failure.
                fi
                [[ "$current" == "$identity" ]] || continue
                if ! kill -KILL "$pid" 2>/dev/null; then
                    if current=$(namespace_identity "/proc/$pid/ns/uts" 2>/dev/null) &&
                       [[ "$current" == "$identity" ]]; then
                        echo "Cannot stop process $pid for pod '$name'." >&2
                        return 1
                    fi
                fi
            done <<< "$members"
            sleep 0.1
        done
        members=$(namespace_processes "$identity") || return 1
        if [[ -n "$members" ]]; then
            echo "Stop timed out for '$name'; resources retained." >&2
            return 1
        fi
        umount -- "$ns_dir/uts" || return 1
    fi
    rm -f -- "$ns_dir/uts" || return 1

    # Unmount net namespace handle if it is still mounted.
    if findmnt -rn -M "$ns_dir/net" >/dev/null 2>&1; then
        umount -- "$ns_dir/net" || return 1
    fi
    rm -f -- "$ns_dir/net" || true

    if [[ -d "$ns_dir" ]]; then
        rmdir -- "$ns_dir" || return 1
    fi
}

runtime_stop() {
    runtime_release_namespace "$1" || return 1
    rm -rf -- "$POD_STATE_DIR/$1" || return 1
}

runtime_start() {
    local name="$1"
    shift

    # Parse --ip <addr> before --.
    local pod_ip=""
    while [[ $# -gt 0 && ${1:-} != -- ]]; do
        case "$1" in
            --ip) pod_ip="$2"; shift 2 ;;
            *) echo "Unknown flag: $1" >&2; return 1 ;;
        esac
    done
    [[ ${1:-} == -- ]] && shift
    [[ $# -gt 0 ]] || { echo 'Missing workload command.' >&2; return 1; }
    [[ -n "$pod_ip" ]] || { echo 'Missing --ip <address>.' >&2; return 1; }

    local state started_at launcher attempt exit_code
    local pod_dir="$POD_STATE_DIR/$name" ns_dir="$NAMESPACE_DIR/$name"
    local ns_net_path="$ns_dir/net" fifo="$pod_dir/net-ready"

    state=$(runtime_status "$name") || return 1
    if [[ "$state" == running ]]; then
        local existing_ip
        existing_ip=$(net_read_pod_ip "$ns_net_path") || existing_ip=""
        json_build_status running null null null "$pod_dir/log" "${existing_ip:-null}"
        return 0
    fi

    ROOTFS="$GLOBAL_ROOTFS" validate_rootfs || return 1
    runtime_stop "$name" || return 1
    mkdir -p -- "$pod_dir" "$ns_dir" || return 1
    touch -- "$ns_dir/uts" "$ns_dir/net" || return 1
    cp -a -- "$GLOBAL_ROOTFS" "$pod_dir/rootfs" || return 1
    mkfifo "$fifo" || return 1
    started_at=$(date +%s)

    # Do not let the background workload inherit our per-pod flock or kubelet flock.
    run_isolated "$name" "$ns_dir/uts" "$ns_net_path" "$fifo" "$pod_dir/rootfs" "$@" \
        8>&- 9>&- </dev/null >"$pod_dir/log" 2>&1 &
    launcher=$!

    # Poll until the net namespace handle is a live nsfs mount.
    local net_ready=0
    for ((attempt=0; attempt<50; attempt++)); do
        if ! kill -0 "$launcher" 2>/dev/null; then
            break
        fi
        if namespace_mount_identity "$ns_net_path" >/dev/null 2>&1 && \
           [[ -n "$(namespace_mount_identity "$ns_net_path")" ]]; then
            net_ready=1
            break
        fi
        sleep 0.1
    done

    if [[ $net_ready -eq 0 ]]; then
        # Launcher died before the net namespace was ready.
        if kill -0 "$launcher" 2>/dev/null; then
            kill -KILL "$launcher" 2>/dev/null || true
        fi
        wait "$launcher" 2>/dev/null || true
        echo "Net namespace handle not ready for '$name'; log: $pod_dir/log" >&2
        runtime_release_namespace "$name" || true
        return 1
    fi

    # Wire the network. On failure, close the FIFO (sending EOF) to unblock the
    # wrapper so it exits, then clean up.
    if ! net_ensure_bridge || ! net_attach_pod "$name" "$ns_net_path" "$pod_ip"; then
        echo "Network wiring failed for '$name'." >&2
        # Close FIFO: wrapper gets EOF and exits non-zero.
        exec {fd}<>"$fifo" && exec {fd}>&-
        rm -f "$fifo"
        wait "$launcher" 2>/dev/null || true
        runtime_release_namespace "$name" || true
        return 1
    fi

    # Signal the workload: networking is ready.
    printf 'x' > "$fifo"

    # Wait for the workload to reach chroot (state == running).
    for ((attempt=0; attempt<50; attempt++)); do
        if ! state=$(runtime_status "$name"); then
            break
        fi
        if [[ "$state" == running ]]; then
            json_build_status running "$started_at" null null "$pod_dir/log" "$pod_ip"
            return 0
        fi
        if ! kill -0 "$launcher" 2>/dev/null; then
            exit_code=0
            wait "$launcher" || exit_code=$?
            runtime_release_namespace "$name" || return 1
            json_build_status exited "$started_at" "$(date +%s)" "$exit_code" "$pod_dir/log" null
            return 0
        fi
        sleep 0.1
    done

    # Cancel the still-owned launch process before removing anything it may use.
    if kill -0 "$launcher" 2>/dev/null; then
        kill -KILL "$launcher" || return 1
    fi
    wait "$launcher" 2>/dev/null || true
    echo "Startup failed or timed out for '$name'; log: $pod_dir/log" >&2
    runtime_release_namespace "$name" || return 1
    return 1
}

main() {
    [[ $# -ge 2 ]] || {
        echo "Usage: $0 start <name> [--ip <addr>] -- <command> [args...]" >&2
        echo "       $0 stop <name>" >&2
        echo "       $0 status <name>" >&2
        return 1
    }
    local action="$1" name="$2" path
    shift 2
    validate_name "$name" || return 1
    [[ $EUID -eq 0 ]] || { echo 'Runtime requires root.' >&2; return 1; }
    case "$action" in start|stop|status) ;; *) echo "Unknown action: $action" >&2; return 1 ;; esac
    for path in "$POD_STATE_DIR" "$NAMESPACE_DIR" "$GLOBAL_ROOTFS"; do
        [[ "$path" == /* && "$path" != / ]] || return 1
    done
    # Lock files live outside the per-pod directory that stop removes.
    mkdir -p "$NAMESPACE_DIR/.locks" || return 1
    exec 9>"$NAMESPACE_DIR/.locks/$name" || return 1
    flock -x 9 || return 1
    "runtime_$action" "$name" "$@"
}

main "$@"
