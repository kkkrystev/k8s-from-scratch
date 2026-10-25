cmd_list() {
    local names name spec status
    local node state started pod_ip
    local row_format='%-12s  %-15s  %-16s  %-36s  %s\n'

    names=$(etcd_pod_names) || return 1

    if [[ -z "$names" ]]; then
        echo 'No pods.'
        return 0
    fi

    printf "$row_format" STATE IP NODE NAME STARTED

    while IFS= read -r name; do
        spec=$(etcd_get_optional "pods/$name/spec") || return 1

        if [[ -z "$spec" ]]; then
            continue
        fi

        node=$(jq -r '.node_name' <<< "$spec") || return 1
        status=$(etcd_get_optional "pods/$name/status") || return 1

        state=$(json_get_field "$status" state) || return 1
        started=$(json_get_field "$status" started_at) || return 1
        pod_ip=$(json_get_field "$status" pod_ip) || return 1

        if [[ -n "$started" ]]; then
            started=$(date -d "@$started" '+%Y-%m-%d %H:%M:%S') || return 1
        fi

        printf "$row_format" \
            "${state:-pending}" \
            "${pod_ip:--}" \
            "${node:--}" \
            "$name" \
            "${started:--}"
    done <<< "$names"
}