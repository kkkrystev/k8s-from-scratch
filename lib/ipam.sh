# Requires etcd-client.sh and the caller's log() function.
# Stores reservations only; never configures network interfaces.

# IPAM: subnet 10.244.0.0/24, .2-.254 allocatable.
IPAM_PREFIX="ipam/10.244.0.0-24"

ipam_allocate() {
    local name="$1" key ip existing

    # Reuse an existing reservation for this pod name.
    local all_keys

    all_keys=$(etcd_list "$IPAM_PREFIX") || return 1

    if [[ -n "$all_keys" ]]; then

        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            existing=$(etcd_get "$key") || continue

            if [[ "$existing" == "$name" ]]; then
                ip="${key##*/}"
                printf '%s' "$ip"

                return 0
            fi
        done <<< "$all_keys"
    fi

    # Allocate the lowest free address.
    local last_octet

    for ((last_octet=2; last_octet<=254; last_octet++)); do
        ip="10.244.0.$last_octet"

        if ! etcd_get "$IPAM_PREFIX/$ip" >/dev/null 2>&1; then
            etcd_put "$IPAM_PREFIX/$ip" "$name" || return 1
            printf '%s' "$ip"

            return 0
        fi
    done
    log "ipam: address space exhausted (all 253 addresses allocated)."

    return 1
}

ipam_free() {
    local name="$1" key existing
    local all_keys

    all_keys=$(etcd_list "$IPAM_PREFIX") || return 1
    [[ -n "$all_keys" ]] || return 0

    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        existing=$(etcd_get "$key") || continue

        if [[ "$existing" == "$name" ]]; then
            etcd_delete "$key" || return 1

            return 0
        fi
    done <<< "$all_keys"
}

