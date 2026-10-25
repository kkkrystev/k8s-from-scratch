# Validate and dispatch network requests in the single-connection networkd process.
# Infrastructure functions live in config.sh, bridge.sh, routes.sh, and pod.sh.
# reply_error is defined by networkd before sourcing this file.

network_dispatch() {
    local request="$1" action pod config ns ip link

    if ! request=$(jq -cse '
        if length == 1 and (.[0] | type == "object") then .[0] else error("request") end |
        select(.action | type == "string") |
        if .action == "health" then
            select(keys == ["action"])
        elif .action == "reserve" or .action == "release" or .action == "detach" then
            select(keys == ["action", "pod"])
        elif .action == "attach" then
            select(keys == ["action", "gateway", "ip", "netns", "pod", "prefix"]) |
            select(.prefix == 24 and (.ip | type == "string") and
                   (.gateway | type == "string") and (.netns | type == "string"))
        else error("action") end |
        if .action == "health" then .
        else
            select(.pod | type == "string") |
            select(.pod | length <= 63
                and test("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$"))
        end
    ' <<< "$request" 2>/dev/null); then
        net_error invalid_request
        return
    fi

    action=$(jq -r '.action' <<< "$request")
    pod=$(jq -r '.pod // empty' <<< "$request")

    case "$action" in
        health)
            if net_bridge_ok && net_routes check &&
               [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] && ipam_health > /dev/null; then
                printf '{"ok":true}\n'
            else
                net_error not_ready
            fi
            ;;

        reserve)
            net_reserve "$pod" || true
            ;;

        attach)
            if ! config=$(net_reserve "$pod"); then
                printf '%s\n' "$config"
                return
            fi

            if ! jq -e --argjson config "$config" '
                .ip == $config.ip and .prefix == $config.prefix and .gateway == $config.gateway
            ' <<< "$request" > /dev/null; then
                net_error reservation_mismatch
                return
            fi

            ns=$(jq -r '.netns' <<< "$request")
            ip=$(jq -r '.ip' <<< "$config")

            if net_bridge_ok && net_attach "$pod" "$ns" "$ip"; then
                printf '{"ok":true}\n'
            else
                net_error attach_failed
            fi
            ;;

        detach)
            if net_detach "$pod"; then
                printf '{"ok":true}\n'
            else
                net_error detach_failed
            fi
            ;;

        release)
            if ! link=$(net_link "$(net_veth "$pod")"); then
                net_error inspection_failed
                return
            fi

            if [[ -n "$link" ]]; then
                net_error still_attached
                return
            fi

            if config=$(ipam_release "$pod"); then
                printf '%s\n' "$config"
            else
                net_error ipam_unavailable_or_rejected
            fi
            ;;
    esac
}
