#!/bin/bash
set -euo pipefail

# Configuration and dependencies
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

GLOBAL_ROOTFS="${ROOTFS:-/var/lib/k8s-from-scratch/rootfs}"
POD_STATE_DIR="${POD_STATE_DIR:-/var/lib/k8s-from-scratch/pods}"
NAMESPACE_DIR="${NAMESPACE_DIR:-/run/k8s-from-scratch}"

POLL_ATTEMPTS=50
POLL_INTERVAL=0.1
NETWORK_SIGNAL_TIMEOUT=5

source "$SCRIPT_DIR/lib/namespace.sh"
source "$SCRIPT_DIR/lib/json.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/network-client.sh"

runtime_error() {
    printf 'runtime: %s\n' "$*" >&2
}

print_usage() {
    printf 'Usage:\n' >&2
    printf '  %s start <name> --ip <address> --prefix <length> --gateway <address> -- <command> [args...]\n' "$0" >&2
    printf '  %s stop <name>\n' "$0" >&2
    printf '  %s ip <name>\n' "$0" >&2
    printf '  %s status <name>\n' "$0" >&2
}

validate_runtime_directories() {
    local path

    for path in "$POD_STATE_DIR" "$NAMESPACE_DIR" "$GLOBAL_ROOTFS"; do
        if [[ "$path" != /* || "$path" == / ]]; then
            runtime_error "Directory must be absolute and must not be /: $path"
            return 1
        fi
    done
}

# Keep validation aligned with the current IPAM contract: /24, gateway .1.
validate_network_config() {
    local address octet
    local -a octets

    for address in "$1" "$3"; do
        [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        IFS=. read -r -a octets <<< "$address"

        for octet in "${octets[@]}"; do
            [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
            ((10#$octet <= 255)) || return 1
        done
    done

    [[ "$2" == 24 && "$3" == "${1%.*}.1" ]] || return 1
    octet="${1##*.}"
    ((10#$octet >= 2 && 10#$octet <= 254))
}

runtime_pod_ip() {
    local addresses
    addresses=$(nsenter --net="$NAMESPACE_DIR/$1/net" ip -j -4 addr show dev eth0) || return 1

    jq -er '
        [.[].addr_info[] | select(.family == "inet") | .local] |
        if length == 1 then .[0] else error("Expected one Pod IPv4 address") end
    ' <<< "$addresses"
}

lock_pod() {
    local pod_name="$1"

    # This file survives removal of the pod's directories.
    mkdir -p -- "$NAMESPACE_DIR/.locks" || return 1

    exec 9>"$NAMESPACE_DIR/.locks/$pod_name" || return 1
    flock -x 9 || return 1
}

# Inspection: running means an init process has reached the pod rootfs.
# It does not mean that the application or the network is ready.
runtime_status() {
    local pod_name="$1"
    local uts_id
    local members
    local pid role
    local other_pid other_role
    local proc_root_id rootfs_id

    uts_id=$(namespace_mount_identity "$NAMESPACE_DIR/$pod_name/uts") || return 1

    if [[ -z "$uts_id" ]]; then
        printf 'exited\n'
        return 0
    fi

    members=$(namespace_processes "$uts_id") || return 1

    while read -r pid role; do
        [[ "$role" == init ]] || continue

        rootfs_id=$(namespace_identity "$POD_STATE_DIR/$pod_name/rootfs") || return 1

        if ! proc_root_id=$(namespace_identity "/proc/$pid/root" 2>/dev/null); then
            # Re-scan to distinguish a process that exited from an inspection error.
            members=$(namespace_processes "$uts_id") || return 1

            while read -r other_pid other_role; do
                if [[ "$other_pid" == "$pid" && "$other_role" == init ]]; then
                    runtime_error "Cannot inspect root directory of process $pid."
                    return 1
                fi
            done <<< "$members"

            continue
        fi

        if [[ "$proc_root_id" == "$rootfs_id" ]]; then
            printf 'running\n'
            return 0
        fi
    done <<< "$members"

    printf 'exited\n'
}

# Stop processes before releasing the namespace references used to find them.
stop_namespace_processes() {
    local uts_id="$1"
    local members
    local pid role current_identity
    local attempt

    for ((attempt=0; attempt<POLL_ATTEMPTS; attempt++)); do
        members=$(namespace_processes "$uts_id") || return 1

        if [[ -z "$members" ]]; then
            return 0
        fi

        while read -r pid role; do
            # Recheck ownership immediately before signaling; a PID-reuse race remains.
            if ! current_identity=$(namespace_identity "/proc/$pid/ns/uts" 2>/dev/null); then
                continue
            fi

            [[ "$current_identity" == "$uts_id" ]] || continue

            if ! kill -KILL "$pid" 2>/dev/null; then
                if current_identity=$(namespace_identity "/proc/$pid/ns/uts" 2>/dev/null); then
                    if [[ "$current_identity" == "$uts_id" ]]; then
                        runtime_error "Cannot stop process $pid."
                        return 1
                    fi
                fi
            fi
        done <<< "$members"

        sleep "$POLL_INTERVAL"
    done

    members=$(namespace_processes "$uts_id") || return 1

    if [[ -n "$members" ]]; then
        runtime_error 'Stopping processes timed out; namespace handles retained.'
        return 1
    fi
}

remove_namespace_handle() {
    local ns_path="$1"
    local ns_id

    ns_id=$(namespace_mount_identity "$ns_path") || return 1

    if [[ -n "$ns_id" ]]; then
        umount -- "$ns_path" || return 1
    fi

    rm -f -- "$ns_path" || return 1
}

runtime_release_namespace() {
    local pod_name="$1"
    local ns_dir="$NAMESPACE_DIR/$pod_name"
    local fifo_path="$POD_STATE_DIR/$pod_name/net-ready"
    local uts_id

    uts_id=$(namespace_mount_identity "$ns_dir/uts") || return 1

    if [[ -n "$uts_id" ]]; then
        stop_namespace_processes "$uts_id" || return 1
    fi

    if ! network_detach "$pod_name" >&2; then
        runtime_error "Detach failed for '$pod_name'; namespace handles retained."
        return 1
    fi

    rm -f -- "$fifo_path" || return 1

    remove_namespace_handle "$ns_dir/net" || return 1
    remove_namespace_handle "$ns_dir/uts" || return 1

    if [[ -d "$ns_dir" ]]; then
        rmdir -- "$ns_dir" || return 1
    fi
}

runtime_stop() {
    local pod_name="$1"

    runtime_release_namespace "$pod_name" || return 1

    # Explicit stop removes the writable filesystem and the previous log.
    rm -rf -- "$POD_STATE_DIR/$pod_name" || return 1
}

# Preparation creates ordinary mount targets, a rootfs copy and a synchronization FIFO.
prepare_pod_files() {
    local pod_name="$1"
    local pod_dir="$POD_STATE_DIR/$pod_name"
    local ns_dir="$NAMESPACE_DIR/$pod_name"

    ROOTFS="$GLOBAL_ROOTFS" validate_rootfs || return 1

    runtime_stop "$pod_name" || return 1

    mkdir -p -- "$pod_dir" "$ns_dir" || return 1
    touch -- "$ns_dir/uts" "$ns_dir/net" || return 1

    cp -a -- "$GLOBAL_ROOTFS" "$pod_dir/rootfs" || return 1

    mkfifo -- "$pod_dir/net-ready" || return 1
}

wait_for_network_namespace() {
    local net_path="$1"
    local launcher_pid="$2"
    local net_id
    local attempt

    for ((attempt=0; attempt<POLL_ATTEMPTS; attempt++)); do
        if ! kill -0 "$launcher_pid" 2>/dev/null; then
            return 1
        fi

        net_id=$(namespace_mount_identity "$net_path") || return 1

        if [[ -n "$net_id" ]]; then
            return 0
        fi

        sleep "$POLL_INTERVAL"
    done

    return 1
}

signal_network_ready() {
    local fifo_path="$1"

    if [[ ! -p "$fifo_path" ]]; then
        runtime_error "Missing network readiness FIFO: $fifo_path"
        return 1
    fi

    # A dead reader must not leave runtime blocked forever when opening the FIFO.
    timeout --kill-after=1 "$NETWORK_SIGNAL_TIMEOUT" \
        /bin/bash -c 'printf x > "$1"' network-ready "$fifo_path" 9>&-
}

cancel_pod_start() {
    local pod_name="$1"
    local launcher_pid="$2"

    # Kill our launch process first; unshare --kill-child also kills its child.
    # Do not rely on opening/closing a FIFO to wake a reader during failure cleanup.
    if kill -0 "$launcher_pid" 2>/dev/null; then
        kill -KILL "$launcher_pid" 2>/dev/null || true
    fi

    wait "$launcher_pid" 2>/dev/null || true

    # Preserve rootfs/log for diagnosis. A later start or explicit stop removes them.
    runtime_release_namespace "$pod_name" || return 1
}

wait_for_workload_start() {
    local pod_name="$1"
    local pod_ip="$2"
    local launcher_pid="$3"
    local started_at="$4"
    local log_path="$POD_STATE_DIR/$pod_name/log"
    local observed_state exit_code exited_at
    local attempt

    for ((attempt=0; attempt<POLL_ATTEMPTS; attempt++)); do
        observed_state=$(runtime_status "$pod_name") || return 1

        if [[ "$observed_state" == running ]]; then
            json_build_status running "$started_at" null null "$log_path" "$pod_ip"
            return $?
        fi

        if ! kill -0 "$launcher_pid" 2>/dev/null; then
            exit_code=0
            wait "$launcher_pid" || exit_code=$?

            runtime_release_namespace "$pod_name" || return 1
            exited_at=$(date +%s) || return 1

            json_build_status exited "$started_at" "$exited_at" "$exit_code" "$log_path" null
            return $?
        fi

        sleep "$POLL_INTERVAL"
    done

    return 1
}

# Start orchestration: validate, prepare, launch, wire networking, release the workload.
runtime_start() {
    local pod_name="$1"
    shift

    local pod_ip="" prefix="" gateway="" config option

    while [[ $# -gt 0 && "$1" != -- ]]; do
        case "$1" in
            --ip|--prefix|--gateway)
                option="$1"

                if [[ $# -lt 2 || "$2" == -- ]]; then
                    runtime_error "Missing value after $option."
                    return 1
                fi

                case "$option" in
                    --ip)
                        [[ -z "$pod_ip" ]] || { runtime_error "Duplicate --ip."; return 1; }
                        pod_ip="$2"
                        ;;
                    --prefix)
                        [[ -z "$prefix" ]] || { runtime_error "Duplicate --prefix."; return 1; }
                        prefix="$2"
                        ;;
                    --gateway)
                        [[ -z "$gateway" ]] || { runtime_error "Duplicate --gateway."; return 1; }
                        gateway="$2"
                        ;;
                esac
                shift 2
                ;;

            *)
                runtime_error "Unknown start option: $1"
                return 1
                ;;
        esac
    done

    if [[ ${1:-} != -- ]]; then
        runtime_error 'Expected -- before the workload command.'
        return 1
    fi

    shift

    if [[ $# -eq 0 || -z "$1" ]]; then
        runtime_error 'Missing workload command.'
        return 1
    fi

    if ! validate_network_config "$pod_ip" "$prefix" "$gateway"; then
        runtime_error 'Expected a /24 Pod address (.2-.254) and gateway .1 in the same subnet.'
        return 1
    fi

    config=$(jq -cn --arg ip "$pod_ip" --argjson prefix "$prefix" --arg gateway "$gateway" \
        '{ip:$ip,prefix:$prefix,gateway:$gateway}') || return 1

    local pod_dir="$POD_STATE_DIR/$pod_name"
    local ns_dir="$NAMESPACE_DIR/$pod_name"
    local net_path="$ns_dir/net"
    local fifo_path="$pod_dir/net-ready"
    local observed_state existing_ip started_at launcher_pid

    observed_state=$(runtime_status "$pod_name") || return 1

    if [[ "$observed_state" == running ]]; then
        existing_ip=$(runtime_pod_ip "$pod_name") || return 1

        # Do not silently report success for an existing pod with a different/missing IP.
        if [[ "$existing_ip" != "$pod_ip" ]]; then
            runtime_error "Pod '$pod_name' is running, but its observed IP '${existing_ip:-missing}' differs from '$pod_ip'."
            return 1
        fi

        # Let Provisioner verify the existing attachment and requested configuration.
        network_attach "$pod_name" "$net_path" "$config" >&2 || return 1

        json_build_status running null null null "$pod_dir/log" "$existing_ip"
        return $?
    fi

    if ! prepare_pod_files "$pod_name"; then
        runtime_error "Cannot prepare files for '$pod_name'."
        return 1
    fi

    started_at=$(date +%s) || return 1

    # Keep the workload independent of our per-pod lock and terminal input.
    run_isolated "$pod_name" \
        "$ns_dir/uts" "$net_path" \
        "$fifo_path" "$pod_dir/rootfs" "$@" \
        9>&- </dev/null >"$pod_dir/log" 2>&1 &

    launcher_pid=$!

    if ! wait_for_network_namespace "$net_path" "$launcher_pid"; then
        runtime_error "Network namespace not ready for '$pod_name'; see $pod_dir/log."
        cancel_pod_start "$pod_name" "$launcher_pid" || return 1
        return 1
    fi

    if ! network_attach "$pod_name" "$net_path" "$config" >&2; then
        runtime_error "Network setup failed for '$pod_name'; see $pod_dir/log."
        cancel_pod_start "$pod_name" "$launcher_pid" || return 1
        return 1
    fi

    if ! signal_network_ready "$fifo_path"; then
        runtime_error "Cannot signal network readiness for '$pod_name'."
        cancel_pod_start "$pod_name" "$launcher_pid" || return 1
        return 1
    fi

    if ! wait_for_workload_start "$pod_name" "$pod_ip" "$launcher_pid" "$started_at"; then
        runtime_error "Startup failed or timed out for '$pod_name'; see $pod_dir/log."
        cancel_pod_start "$pod_name" "$launcher_pid" || return 1
        return 1
    fi
}

# Command-line entry point
main() {
    if [[ $# -lt 2 ]]; then
        print_usage
        return 1
    fi

    local action="$1"
    local pod_name="$2"
    shift 2

    validate_name "$pod_name" || return 1

    if [[ $EUID -ne 0 ]]; then
        runtime_error 'Run as root inside the development container.'
        return 1
    fi

    validate_runtime_directories || return 1

    case "$action" in
        start)
            lock_pod "$pod_name" || return 1
            runtime_start "$pod_name" "$@"
            ;;

        stop)
            if [[ $# -ne 0 ]]; then
                print_usage
                return 1
            fi

            lock_pod "$pod_name" || return 1
            runtime_stop "$pod_name"
            ;;

        ip)
            [[ $# -eq 0 ]] || { print_usage; return 1; }
            lock_pod "$pod_name" || return 1
            runtime_pod_ip "$pod_name"
            ;;

        status)
            if [[ $# -ne 0 ]]; then
                print_usage
                return 1
            fi

            lock_pod "$pod_name" || return 1
            runtime_status "$pod_name"
            ;;

        *)
            runtime_error "Unknown action: $action"
            print_usage
            return 1
            ;;
    esac
}

main "$@"
