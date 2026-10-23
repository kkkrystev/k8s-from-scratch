# Local IPv4 /24 allocator. Caller holds IPAM_STATE.lock on descriptor 8.
# The old lib/ipam.sh stays untouched until kubelet integration.

ipam_config() {
    local subnet="$IPAM_SUBNET" octet
    local parts=()

    [[ "$subnet" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]] || return 1
    parts=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
    for octet in "${parts[@]}"; do
        [[ "$octet" == 0 || "$octet" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
    IPAM_BASE="${subnet%.0/24}"
}

ipam_load() {
    [[ -f "$IPAM_STATE" && ! -L "$IPAM_STATE" ]] || return 1
    jq -cse --arg subnet "$IPAM_SUBNET" --arg base "$IPAM_BASE" '
        if length != 1 then error("invalid state") else .[0] end |
        select(type == "object") |
        select(keys == ["leases", "subnet"]) |
        select(.subnet == $subnet and (.leases | type == "object")) |
        select(all(.leases | to_entries[];
            (.key | length <= 63 and test("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$")) and
            (.value | type == "string") and
            (.value | startswith($base + ".")) and
            (.value | split(".") | length == 4) and
            (.value | split(".")[-1] | test("^([2-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$"))
        )) |
        select(([.leases[]] | length) == ([.leases[]] | unique | length))
    ' "$IPAM_STATE" 2>/dev/null
}

ipam_save() {
    local state="$1" tmp
    tmp=$(mktemp "${IPAM_STATE}.XXXXXX") || return 1
    if ! printf '%s\n' "$state" > "$tmp" || ! mv -f -- "$tmp" "$IPAM_STATE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

ipam_init() {
    # Never silently reset malformed state or change its subnet.
    if [[ -e "$IPAM_STATE" || -L "$IPAM_STATE" ]]; then
        ipam_load >/dev/null
    else
        local state
        state=$(jq -cn --arg subnet "$IPAM_SUBNET" '{subnet:$subnet,leases:{}}') || return 1
        ipam_save "$state"
    fi
}

ipam_dispatch() {
    local request="$1" action pod state ip next

    if ! request=$(jq -cse '
        if length == 1 and (.[0] | type == "object") then .[0]
        else error("invalid request") end |
        if (.action | type) != "string" then error("invalid action")
        elif .action == "health" then select(keys == ["action"])
        elif .action == "allocate" or .action == "release" then
            select(keys == ["action", "pod"]) |
            select(.pod | type == "string") |
            select(.pod | length <= 63 and test("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$"))
        else . end
    ' <<< "$request" 2>/dev/null); then
        reply_error invalid_request
        return
    fi
    if ! jq -e '.action == "health" or .action == "allocate" or .action == "release"' \
        <<< "$request" >/dev/null; then
        reply_error unsupported_action
        return
    fi
    action=$(jq -r '.action' <<< "$request")

    if ! state=$(ipam_load); then
        reply_error invalid_state
        return
    fi
    if [[ "$action" == health ]]; then
        printf '{"ok":true}\n'
        return
    fi
    pod=$(jq -r '.pod' <<< "$request")
    if [[ "$action" == release ]]; then
        next=$(jq -c --arg pod "$pod" 'del(.leases[$pod])' <<< "$state") || return 1
        if [[ "$next" != "$state" ]] && ! ipam_save "$next"; then
            reply_error storage_error
            return
        fi
        printf '{"ok":true}\n'
        return
    fi

    ip=$(jq -r --arg pod "$pod" '.leases[$pod] // empty' <<< "$state") || return 1
    if [[ -z "$ip" ]]; then
        ip=$(jq -r --arg base "$IPAM_BASE" '
            [.leases[]] as $used |
            first(range(2;255) | ($base + "." + tostring) as $ip |
                  select(($used | index($ip)) == null) | $ip) // empty
        ' <<< "$state") || return 1
        if [[ -z "$ip" ]]; then
            reply_error address_pool_exhausted
            return
        fi
        next=$(jq -c --arg pod "$pod" --arg ip "$ip" '.leases[$pod]=$ip' <<< "$state") || return 1
        if ! ipam_save "$next"; then
            reply_error storage_error
            return
        fi
    fi
    # A reservation is written before success is sent to the client.
    jq -cn --arg ip "$ip" --arg gateway "$IPAM_BASE.1" \
        '{ok:true,ip:$ip,prefix:24,gateway:$gateway}'
}
