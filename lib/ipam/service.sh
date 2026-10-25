# Validate and execute IPAM requests in the single-connection ipamd process.
# ipam_config/ipam_load/ipam_save/ipam_init live in store.sh.
# reply_error is defined by ipamd before sourcing this file.

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
            select(.pod | length <= 63
                and test("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$"))
        else . end
    ' <<< "$request" 2>/dev/null); then
        reply_error invalid_request
        return
    fi

    if ! jq -e '.action == "health" or .action == "allocate" or .action == "release"' \
        <<< "$request" > /dev/null; then
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

    # allocate: return the existing lease or pick the next free address.
    ip=$(jq -r --arg pod "$pod" '.leases[$pod] // empty' <<< "$state") || return 1

    if [[ -z "$ip" ]]; then
        ip=$(jq -r --arg base "$IPAM_BASE" '
            [.leases[]] as $used |
            first(
                range(2; 255)
                | ($base + "." + tostring) as $ip
                | select(($used | index($ip)) == null)
                | $ip
            ) // empty
        ' <<< "$state") || return 1

        if [[ -z "$ip" ]]; then
            reply_error address_pool_exhausted
            return
        fi

        next=$(jq -c --arg pod "$pod" --arg ip "$ip" '.leases[$pod] = $ip' <<< "$state") || return 1

        if ! ipam_save "$next"; then
            reply_error storage_error
            return
        fi
    fi

    # A reservation is written before success is sent to the client.
    jq -cn --arg ip "$ip" --arg gateway "$IPAM_BASE.1" \
        '{ok: true, ip: $ip, prefix: 24, gateway: $gateway}'
}
