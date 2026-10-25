# Node-wide network configuration and derived globals.
# net_config is called once at networkd startup; helpers read NET_BASE/NET_GATEWAY.

net_error() {
    printf '{"ok":false,"error":"%s"}\n' "$1"
}

net_config() {
    local part

    [[ "$NET_SUBNET" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]] || return 1

    for part in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; do
        [[ "$part" == 0 || "$part" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done

    NET_BASE=${NET_SUBNET%.0/24}
    NET_GATEWAY="$NET_BASE.1"

    [[ "$NET_BRIDGE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || return 1
    [[ "$NETNS_DIR" == /* && "$NETNS_DIR" != / ]] || return 1
    [[ ! -L "$NETNS_DIR" ]] || return 1
    [[ "$(realpath -m -- "$NETNS_DIR")" == "$NETNS_DIR" ]] || return 1

    jq -e --arg own "$NET_SUBNET" '
        def ipv4: split(".") as $p | ($p | length) == 4 and
            all($p[]; test("^(0|[1-9][0-9]{0,2})$") and (tonumber <= 255));
        type == "object" and all(to_entries[];
            (.key != $own) and (.key | endswith(".0/24")) and
            (.key | split("/")[0] | ipv4) and
            (.value | type == "string") and (.value | ipv4))
    ' <<< "$NET_ROUTES" > /dev/null 2>&1
}
