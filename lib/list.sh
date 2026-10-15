# list subcommand — pure reader.
# Reads all pod state from etcd. Never writes.
# State corrections are the kubelet's responsibility.
# Expects ETCD_DIR to be set and etcd-client.sh/json.sh sourced.

cmd_list() {
    local keys
    keys=$(etcd_list "pods") || true

    if [[ -z "$keys" ]]; then
        echo "No pods."
        return 0
    fi

    local names=()
    local key name
    while IFS= read -r key; do
        name=$(echo "$key" | sed 's|^pods/||;s|/.*||')
        local already=0
        local n
        for n in "${names[@]:-}"; do
            [[ "$n" == "$name" ]] && { already=1; break; }
        done
        [[ $already -eq 0 ]] && names+=("$name")
    done <<< "$keys"

    if [[ ${#names[@]} -eq 0 ]]; then
        echo "No pods."
        return 0
    fi

    printf "%-12s  %-36s  %s\n" "STATE" "NAME" "STARTED"

    local status_json state started_at human_ts
    for name in "${names[@]}"; do
        status_json=$(etcd_get "pods/${name}/status" 2>/dev/null) || status_json=""
        if [[ -z "$status_json" ]]; then
            state="unknown"
            started_at=""
        else
            state=$(json_get_field "$status_json" "state")
            started_at=$(json_get_field "$status_json" "started_at")
            [[ "$started_at" == "null" ]] && started_at=""
        fi

        human_ts=""
        if [[ -n "$started_at" ]]; then
            human_ts=$(date -d "@${started_at}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || date -r "$started_at"   '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || echo "$started_at")
        fi

        printf "%-12s  %-36s  %s\n" "$state" "$name" "$human_ts"
    done
}
