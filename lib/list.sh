# list subcommand.
# Expects CONTAINER_STATE_DIR, ETCD_DIR to be set and meta.sh/etcd-client.sh/json.sh sourced.

cmd_list() {
    local keys
    keys=$(etcd_list "containers") || true

    if [[ -z "$keys" ]]; then
        echo "No containers."
        return 0
    fi

    # Collect unique container names from keys of the form containers/<name>/spec or containers/<name>/status.
    local names=()
    local key name
    while IFS= read -r key; do
        name=$(echo "$key" | sed 's|^containers/||;s|/.*||')
        # Deduplicate.
        local already=0
        local n
        for n in "${names[@]:-}"; do
            [[ "$n" == "$name" ]] && { already=1; break; }
        done
        [[ $already -eq 0 ]] && names+=("$name")
    done <<< "$keys"

    if [[ ${#names[@]} -eq 0 ]]; then
        echo "No containers."
        return 0
    fi

    printf "%-12s  %-36s  %s\n" "STATE" "NAME" "STARTED"

    local status_json state started_at human_ts cdir
    for name in "${names[@]}"; do
        status_json=$(etcd_get "containers/${name}/status" 2>/dev/null) || status_json=""
        if [[ -z "$status_json" ]]; then
            state="unknown"
            started_at=""
        else
            state=$(json_get_field "$status_json" "state")
            started_at=$(json_get_field "$status_json" "started_at")
            [[ "$started_at" == "null" ]] && started_at=""

            # For running pods, do a live PID check and correct if stale.
            if [[ "$state" == "running" ]]; then
                cdir=$(container_dir "$name")
                if [[ -d "$cdir" ]]; then
                    state=$(resolve_state "$cdir")
                else
                    state="unknown"
                fi
            fi
        fi

        local human_ts=""
        if [[ -n "$started_at" ]]; then
            human_ts=$(date -d "@${started_at}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || date -r "$started_at"   '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || echo "$started_at")
        fi

        printf "%-12s  %-36s  %s\n" "$state" "$name" "$human_ts"
    done
}
