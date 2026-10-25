# Bridge and veth link inspection and creation.
# Depends on NET_BRIDGE, NET_SUBNET, NET_GATEWAY set by net_config.

net_link() {
    local links
    links=$(ip -j -d link show) || return 1
    jq -c --arg name "$1" '.[] | select(.ifname == $name)' <<< "$links"
}

net_veth() {
    printf 'kfsn%s' "$(printf '%s/%s' "$NET_BRIDGE" "$1" | sha256sum | cut -c1-10)"
}

net_bridge_ok() {
    local link addr

    link=$(net_link "$NET_BRIDGE") || return 1

    jq -e --arg tag "kfs-network-bridge:$NET_SUBNET" '
        .linkinfo.info_kind == "bridge" and .ifalias == $tag and
        (.flags | index("UP") != null)
    ' <<< "$link" > /dev/null || return 1

    addr=$(ip -j -4 addr show dev "$NET_BRIDGE") || return 1

    jq -e --arg gateway "$NET_GATEWAY" '
        [.[].addr_info[] | select(.family == "inet")] |
        length == 1 and .[0].local == $gateway and .[0].prefixlen == 24
    ' <<< "$addr" > /dev/null
}
