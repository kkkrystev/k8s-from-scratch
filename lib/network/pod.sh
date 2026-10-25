# Per-Pod network operations: IP reservation, veth wiring, and teardown.
# Depends on NET_BASE, NET_BRIDGE, NET_GATEWAY, NETNS_DIR set by net_config,
# and on net_link/net_veth from bridge.sh, ipam_* from ipam/client.sh.

net_setup() {
    local link addr

    link=$(net_link "$NET_BRIDGE") || return 1

    if [[ -z "$link" ]]; then
        ip link add "$NET_BRIDGE" type bridge || return 1

        if ! ip link set dev "$NET_BRIDGE" alias "kfs-network-bridge:$NET_SUBNET"; then
            ip link del "$NET_BRIDGE" || true
            return 1
        fi

        ip addr add "$NET_GATEWAY/24" dev "$NET_BRIDGE" || return 1
    else
        # Refuse to take over an old runtime bridge or an unrelated interface.
        jq -e --arg tag "kfs-network-bridge:$NET_SUBNET" '
            .linkinfo.info_kind == "bridge" and .ifalias == $tag
        ' <<< "$link" > /dev/null || return 1

        addr=$(ip -j -4 addr show dev "$NET_BRIDGE") || return 1

        if jq -e '[.[].addr_info[] | select(.family == "inet")] | length == 0' \
            <<< "$addr" > /dev/null; then
            ip addr add "$NET_GATEWAY/24" dev "$NET_BRIDGE" || return 1
        fi
    fi

    ip link set "$NET_BRIDGE" up || return 1
    net_bridge_ok || return 1
    sysctl -q -w net.ipv4.ip_forward=1 >&2 || return 1
    net_routes setup
}

net_reserve() {
    local config

    if ! config=$(ipam_allocate "$1"); then
        net_error ipam_unavailable_or_rejected
        return 1
    fi

    if ! jq -e --arg base "$NET_BASE." --arg gateway "$NET_GATEWAY" '
        .ok == true and .prefix == 24 and .gateway == $gateway and
        (.ip | type == "string") and (.ip | startswith($base)) and
        (.ip | split(".") | length == 4) and
        (.ip | split(".")[-1] | test("^([2-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$"))
    ' <<< "$config" > /dev/null; then
        net_error ipam_config_mismatch
        return 1
    fi

    printf '%s\n' "$config"
}

net_detach() {
    local pod="$1" h link

    h=$(net_veth "$pod")
    link=$(net_link "$h") || return 1

    [[ -n "$link" ]] || return 0

    jq -e --arg tag "kfs-network:$NET_BRIDGE:$pod:" --arg bridge "$NET_BRIDGE" '
        .linkinfo.info_kind == "veth" and ((.ifalias // "") | startswith($tag)) and
        ((.master // "") == "" or .master == $bridge)
    ' <<< "$link" > /dev/null || return 1

    ip link del "$h"
}

net_wire() {
    local h="$1" p="$2" ns="$3" ip="$4"

    ip link set "$p" netns "$ns" || return 1
    nsenter --net="$ns" ip link set "$p" name eth0 || return 1
    ip link set "$h" master "$NET_BRIDGE" || return 1
    ip link set "$h" up || return 1
    nsenter --net="$ns" ip link set eth0 up || return 1
    nsenter --net="$ns" ip link set lo up || return 1
    nsenter --net="$ns" ip addr add "$ip/24" dev eth0 || return 1
    nsenter --net="$ns" ip route add default via "$NET_GATEWAY"
}

net_attach() {
    local pod="$1" ns="$2" ip="$3" h p id tag link peer addr routes

    [[ "$ns" == "$NETNS_DIR/$pod/net" && ! -L "$ns" ]] || return 1
    [[ "$(realpath -m -- "$ns")" == "$ns" ]] || return 1
    [[ "$(findmnt -rn -M "$ns" -o FSTYPE)" == nsfs ]] || return 1

    # Verify that this handle is specifically a network namespace.
    nsenter --net="$ns" true || return 1

    id=$(stat -Lc '%d:%i' -- "$ns") || return 1
    h=$(net_veth "$pod"); p="${h}p"
    tag="kfs-network:$NET_BRIDGE:$pod:$id"
    link=$(net_link "$h") || return 1

    if [[ -n "$link" ]]; then
        jq -e --arg tag "$tag" --arg bridge "$NET_BRIDGE" '
            .linkinfo.info_kind == "veth" and .ifalias == $tag and .master == $bridge
        ' <<< "$link" > /dev/null || return 1

        peer=$(nsenter --net="$ns" ip -j link show eth0) || return 1
        jq -e --argjson host "$link" \
            '.[0].ifindex == $host.link_index and .[0].link_index == $host.ifindex' \
            <<< "$peer" > /dev/null || return 1

        addr=$(nsenter --net="$ns" ip -j -4 addr show eth0) || return 1
        jq -e --arg ip "$ip" '
            [.[].addr_info[] | select(.family == "inet")] |
            length == 1 and .[0].local == $ip and .[0].prefixlen == 24
        ' <<< "$addr" > /dev/null || return 1

        routes=$(nsenter --net="$ns" ip -j -4 route show default) || return 1
        jq -e --arg gateway "$NET_GATEWAY" \
            'length == 1 and .[0].gateway == $gateway and .[0].dev == "eth0"' \
            <<< "$routes" > /dev/null || return 1

        ip link set "$h" up || return 1
        nsenter --net="$ns" ip link set eth0 up || return 1
        nsenter --net="$ns" ip link set lo up
        return
    fi

    # Do not disturb an existing eth0 inside a namespace supplied by the caller.
    peer=$(nsenter --net="$ns" ip -j link show) || return 1
    jq -e 'all(.[]; .ifname != "eth0")' <<< "$peer" > /dev/null || return 1

    ip link add "$h" type veth peer name "$p" || return 1

    if ! ip link set dev "$h" alias "$tag"; then
        ip link del "$h" || true
        return 1
    fi

    if ! net_wire "$h" "$p" "$ns" "$ip"; then
        net_detach "$pod" || echo "Cleanup failed for $pod; reservation retained." >&2
        return 1
    fi
}
