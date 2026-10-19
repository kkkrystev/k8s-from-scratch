# Enumerate declared objects, not arbitrary metadata keys.
cmd_list() {
    local names name status state started pod_ip

    names=$(etcd_pod_names) || return 1
    [[ -n "$names" ]] || { echo 'No pods.'; return 0; }

    printf '%-12s  %-15s  %-36s  %s\n' STATE IP NAME STARTED

    while IFS= read -r name; do
        status=$(etcd_get "pods/$name/status") || status=""
        state=$(json_get_field "$status" state) || return 1
        started=$(json_get_field "$status" started_at) || return 1
        pod_ip=$(json_get_field "$status" pod_ip) || return 1
        if [[ -n "$started" ]]; then started=$(date -d "@$started" '+%Y-%m-%d %H:%M:%S') || return 1; fi
        printf '%-12s  %-15s  %-36s  %s\n' "${state:-pending}" "${pod_ip:--}" "$name" "${started:--}"
    done <<< "$names"
}
