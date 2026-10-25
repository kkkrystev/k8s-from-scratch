cmd_get() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 get <name>" >&2
        return 1
    fi

    local name="$1"
    local spec status node request_code
    local state started exited code log pod_ip

    validate_name "$name" || return 1

    if spec=$(etcd_get "pods/$name/spec"); then
        node=$(jq -r '.node_name' <<< "$spec") || return 1
    else
        request_code=$?

        if [[ "$request_code" -eq 2 ]]; then
            echo "Pod '$name' not found." >&2
        fi

        return "$request_code"
    fi

    status=$(etcd_get_optional "pods/$name/status") || return 1

    printf 'Node:      %s\n' "${node:--}"

    state=$(json_get_field "$status" state) || return 1
    started=$(json_get_field "$status" started_at) || return 1
    exited=$(json_get_field "$status" exited_at) || return 1
    code=$(json_get_field "$status" exit_code) || return 1
    log=$(json_get_field "$status" log) || return 1
    pod_ip=$(json_get_field "$status" pod_ip) || return 1

    if [[ -n "$started" ]]; then
        started=$(date -d "@$started" '+%Y-%m-%d %H:%M:%S') || return 1
    fi

    if [[ -n "$exited" ]]; then
        exited=$(date -d "@$exited" '+%Y-%m-%d %H:%M:%S') || return 1
    fi

    printf 'Name:      %s\n' "$name"
    printf 'State:     %s\n' "${state:-pending}"
    printf 'IP:        %s\n' "${pod_ip:--}"
    printf 'Started:   %s\n' "${started:--}"

    if [[ -n "$exited" ]]; then
        printf 'Exited:    %s\n' "$exited"
    fi

    if [[ -n "$code" ]]; then
        printf 'Exit code: %s\n' "$code"
    fi

    printf 'Log:       %s\n' "${log:--}"
}