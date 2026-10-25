# Local Pod operations. This file never reads or writes etcdd.
GLOBAL_ROOTFS="${ROOTFS:-/var/lib/k8s-from-scratch/rootfs}"
POD_STATE_DIR="${POD_STATE_DIR:-/var/lib/k8s-from-scratch/pods}"
NAMESPACE_DIR="${NAMESPACE_DIR:-/run/k8s-from-scratch}"
POLL_ATTEMPTS=50
POLL_INTERVAL=0.1
NETWORK_SIGNAL_TIMEOUT=5

declare -Ag RUNTIME_CHILDREN=()
source "$(dirname -- "${BASH_SOURCE[0]}")/namespace.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/json.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/validate.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/network-client.sh"

runtime_error() {
    printf 'runtime: %s\n' "$*" >&2
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

lock_pod() {
    local pod_name="$1"

    # This file survives removal of the pod's directories.
    mkdir -p -- "$NAMESPACE_DIR/.locks" || return 1

    exec 9>"$NAMESPACE_DIR/.locks/$pod_name" || return 1
    flock -x 9 || return 1
}

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

pod_release_namespace() {
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

pod_stop() {
    local pod_name="$1"

    pod_release_namespace "$pod_name" || return 1

    # Explicit stop removes the writable filesystem and the previous log.
    rm -rf -- "${POD_STATE_DIR:?}/$pod_name" || return 1
}

runtime_reap_children() {
    local pid
    local running_file="$RUNTIME_WORK_DIR/running"
    local running

    jobs -pr > "$running_file"
    running=$(cat "$running_file") || return 1

    for pid in "${!RUNTIME_CHILDREN[@]}"; do
        if [[ $'\n'"$running"$'\n' != *$'\n'"$pid"$'\n'* ]]; then
            wait "$pid" 2>/dev/null || true
            unset 'RUNTIME_CHILDREN[$pid]'
        fi
    done
}

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-inspect.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-start.sh"
