# Static route management for cross-Node networking.
# NET_ROUTES is a JSON object mapping subnet strings to gateway IPs.

net_routes() {
    local mode="$1" dest via routes

    while IFS=$'\t' read -r dest via; do
        [[ -n "$dest" ]] || continue

        routes=$(ip -j -4 route show exact "$dest") || return 1

        if [[ "$routes" == '[]' && "$mode" == setup ]]; then
            ip route add "$dest" via "$via" || return 1
        elif ! jq -e --arg via "$via" 'length == 1 and .[0].gateway == $via' \
            <<< "$routes" > /dev/null; then
            echo "Missing or conflicting route: $dest via $via" >&2
            return 1
        fi
    done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<< "$NET_ROUTES")
}
