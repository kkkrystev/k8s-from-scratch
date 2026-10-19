# Pure etcd reader: spec determines existence, status is the last observation.

cmd_get() {
    [[ $# -eq 1 ]] || { echo "Usage: $0 get <name>" >&2; return 1; }
    local name="$1" status state started exited code log pod_ip
    validate_name "$name" || return 1
    if ! etcd_get "pods/$name/spec" >/dev/null; then
        echo "Pod '$name' not found." >&2
        return 1
    fi
    status=$(etcd_get "pods/$name/status") || status=""
    state=$(json_get_field "$status" state) || return 1
    started=$(json_get_field "$status" started_at) || return 1
    exited=$(json_get_field "$status" exited_at) || return 1
    code=$(json_get_field "$status" exit_code) || return 1
    log=$(json_get_field "$status" log) || return 1
    pod_ip=$(json_get_field "$status" pod_ip) || return 1
    if [[ -n "$started" ]]; then started=$(date -d "@$started" '+%Y-%m-%d %H:%M:%S') || return 1; fi
    if [[ -n "$exited" ]]; then exited=$(date -d "@$exited" '+%Y-%m-%d %H:%M:%S') || return 1; fi
    printf 'Name:      %s\nState:     %s\nIP:        %s\nStarted:   %s\n' \
        "$name" "${state:-pending}" "${pod_ip:--}" "${started:--}"
    if [[ -n "$exited" ]]; then printf 'Exited:    %s\n' "$exited"; fi
    if [[ -n "$code" ]]; then printf 'Exit code: %s\n' "$code"; fi
    printf 'Log:       %s\n' "${log:--}"
}
