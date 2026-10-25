# Prepare a Pod, launch it, attach networking and observe startup.
# Called directly by the permanent daemon, never through command substitution.

prepare_pod_files() {
    local pod_name="$1"
    local pod_dir="$POD_STATE_DIR/$pod_name"
    local ns_dir="$NAMESPACE_DIR/$pod_name"

    ROOTFS="$GLOBAL_ROOTFS" validate_rootfs || return 1

    pod_stop "$pod_name" || return 1

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
    pod_release_namespace "$pod_name" || return 1
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
        observed_state=$(pod_status "$pod_name") || return 1

        if [[ "$observed_state" == running ]]; then
            json_build_status running "$started_at" null null "$log_path" "$pod_ip"
            return $?
        fi

        if ! kill -0 "$launcher_pid" 2>/dev/null; then
            exit_code=0
            wait "$launcher_pid" || exit_code=$?

            pod_release_namespace "$pod_name" || return 1
            exited_at=$(date +%s) || return 1

            json_build_status exited "$started_at" "$exited_at" "$exit_code" "$log_path" null
            return $?
        fi

        sleep "$POLL_INTERVAL"
    done

    return 1
}

pod_start() {
    local pod_name="$1"
    local pod_ip="$2"
    local prefix="$3"
    local gateway="$4"
    local config
    shift 4

    if [[ $# -lt 2 || "$1" != -- || -z "$2" ]]; then
        runtime_error 'Missing workload command.'
        return 1
    fi
    shift

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

    observed_state=$(pod_status "$pod_name") || return 1

    if [[ "$observed_state" == running ]]; then
        existing_ip=$(pod_ip "$pod_name") || return 1

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
    (
        # Workloads must not retain the daemon's lifetime lock or inbox.
        if [[ -n "${RUNTIME_LOCK_FD:-}" ]]; then
            exec {RUNTIME_LOCK_FD}>&-
        fi
        if [[ -n "${RUNTIME_SOCKET_LOCK_FD:-}" ]]; then
            exec {RUNTIME_SOCKET_LOCK_FD}>&-
        fi
        if [[ -n "${RUNTIME_INBOX_FD:-}" ]]; then
            exec {RUNTIME_INBOX_FD}>&-
        fi
        run_isolated "$pod_name" \
            "$ns_dir/uts" "$net_path" \
            "$fifo_path" "$pod_dir/rootfs" "$@"
    ) 9>&- </dev/null >"$pod_dir/log" 2>&1 &

    launcher_pid=$!
    RUNTIME_CHILDREN["$launcher_pid"]="$pod_name"

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
