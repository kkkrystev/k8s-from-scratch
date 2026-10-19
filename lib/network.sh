# Host-side network operations for pod-to-pod connectivity.
# All functions run in the host network namespace and reach into pod netns via nsenter.
# No etcd access. No pod state beyond the paths passed in.
#
# Subnet: 10.244.0.0/24
#   .0   = network address
#   .1   = kfs0 bridge (project-owned L2 switch)
#   .2-.254 = allocatable pod addresses
#   .255 = broadcast

BRIDGE="kfs0"
BRIDGE_ADDR="10.244.0.1/24"

# Derive the host-side veth name for a pod.
# Format: kfsv + first 11 hex chars of sha256(name) = 15 chars total (IFNAMSIZ limit).
# Collision probability across 253 pods is negligible; documented as a known limit.
net_veth_name() {
    local name="$1"
    # kfsv + 10 hex chars = 14 chars, leaving room for a 'p' suffix on the pod-side peer.
    printf 'kfsv%s' "$(printf '%s' "$name" | sha256sum | cut -c1-10)"
}

# Ensure the project bridge exists with the expected address and is UP.
# Idempotent. Fails clearly if a non-bridge resource named kfs0 already exists.
net_ensure_bridge() {
    if ip link show "$BRIDGE" >/dev/null 2>&1; then
        # -d (detail) makes ip always emit linkinfo.info_kind for bridge links.
        local kind
        kind=$(ip -j -d link show "$BRIDGE" | jq -r '.[0].linkinfo.info_kind // empty')
        if [[ "$kind" != bridge ]]; then
            echo "net: '$BRIDGE' exists but is not a bridge (kind: ${kind:-unknown}); cannot proceed." >&2
            return 1
        fi
        if ! ip addr show "$BRIDGE" | grep -qF "${BRIDGE_ADDR%/*}"; then
            ip addr add "$BRIDGE_ADDR" dev "$BRIDGE" 2>/dev/null || true
        fi
        if ! ip link show "$BRIDGE" | grep -qw UP; then
            ip link set "$BRIDGE" up || return 1
        fi
        return 0
    fi
    ip link add "$BRIDGE" type bridge || return 1
    ip addr add "$BRIDGE_ADDR" dev "$BRIDGE" || return 1
    ip link set "$BRIDGE" up || return 1
}

# Wire a pod's network namespace: create a veth pair, move the pod end in,
# configure eth0 with the given IP and bring up both eth0 and lo.
# Arguments: <pod-name> <netns-path> <ip>
net_attach_pod() {
    local name="$1" netns="$2" ip="$3"
    local hveth pveth
    hveth=$(net_veth_name "$name")
    # Pod-side veth peer: same name with 'p' suffix, renamed to eth0 after moving into netns.
    # Avoids collision with the host's own eth0 interface.
    pveth="${hveth}p"

    # Idempotency: if already fully wired, return 0.
    if ip link show "$hveth" >/dev/null 2>&1; then
        local master
        master=$(ip -j link show "$hveth" | jq -r '.[0].master // empty')
        if [[ "$master" == "$BRIDGE" ]]; then
            local existing_ip
            existing_ip=$(nsenter --net="$netns" ip -j addr show eth0 2>/dev/null \
                | jq -r '.[0].addr_info[]? | select(.family=="inet") | .local // empty' 2>/dev/null) || true
            if [[ "$existing_ip" == "$ip" ]]; then
                return 0
            fi
        fi
        # Exists but not in the expected state — tear down and re-create.
        ip link del "$hveth" 2>/dev/null || true
    fi

    # Create veth pair. Pod end is named pveth in the host ns to avoid colliding with eth0.
    ip link add "$hveth" type veth peer name "$pveth" || return 1

    # Move pod end into the pod netns.
    if ! ip link set "$pveth" netns "$netns"; then
        ip link del "$hveth" 2>/dev/null || true
        return 1
    fi

    # Rename pod end to eth0 inside the netns.
    if ! nsenter --net="$netns" ip link set "$pveth" name eth0; then
        ip link del "$hveth" 2>/dev/null || true
        return 1
    fi

    # Enslave host end to the bridge and bring it up.
    if ! ip link set "$hveth" master "$BRIDGE" || ! ip link set "$hveth" up; then
        net_detach_pod "$name"
        return 1
    fi

    # Configure the pod end from the host via nsenter.
    if ! nsenter --net="$netns" ip addr add "${ip}/24" dev eth0 \
    || ! nsenter --net="$netns" ip link set eth0 up \
    || ! nsenter --net="$netns" ip link set lo up; then
        net_detach_pod "$name"
        return 1
    fi
}

# Remove the host-side veth for a pod. Auto-removes the pod end of the pair.
# Idempotent: no-op if the veth does not exist.
# Verifies the veth is enslaved to the project bridge before deleting.
net_detach_pod() {
    local name="$1"
    local hveth
    hveth=$(net_veth_name "$name")

    if ! ip link show "$hveth" >/dev/null 2>&1; then
        return 0
    fi

    local master
    master=$(ip -j link show "$hveth" | jq -r '.[0].master // empty')
    if [[ -n "$master" && "$master" != "$BRIDGE" ]]; then
        echo "net: '$hveth' exists but is enslaved to '$master', not '$BRIDGE'; not deleting." >&2
        return 1
    fi

    ip link del "$hveth" 2>/dev/null || true
}

# Read the IPv4 address currently assigned to eth0 inside a pod's netns.
# Prints the address (without prefix length) or nothing if unconfigured.
net_read_pod_ip() {
    local netns="$1"
    nsenter --net="$netns" ip -j addr show eth0 2>/dev/null \
        | jq -r '.[0].addr_info[]? | select(.family=="inet") | .local // empty' 2>/dev/null \
        || true
}
