# Observe local Pod processes, namespaces and IP addresses. No storage calls.

pod_ip() {
    local addresses
    addresses=$(nsenter --net="$NAMESPACE_DIR/$1/net" ip -j -4 addr show dev eth0) || return 1

    jq -er '
        [.[].addr_info[] | select(.family == "inet") | .local] |
        if length == 1 then .[0] else error("Expected one Pod IPv4 address") end
    ' <<< "$addresses"
}

pod_status() {
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
