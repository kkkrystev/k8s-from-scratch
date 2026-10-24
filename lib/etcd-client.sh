# TCP JSON-lines client. Exit 2 means missing key; 1 means any other failure.
etcd_call() {
    local request="$1" response
    local endpoint="${ETCD_ENDPOINT:-127.0.0.1:2379}"
    local timeout="${ETCD_TIMEOUT:-5}" error

    if [[ ! "$endpoint" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*:[1-9][0-9]{0,4}$ ]]; then
        echo 'Invalid ETCD_ENDPOINT (host:port).' >&2
        return 1
    fi

    if (( ${endpoint##*:} > 65535 )); then
        echo 'Invalid ETCD_ENDPOINT (host:port).' >&2
        return 1
    fi

    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || return 1

    if ((${#request} > 65536)); then
        echo 'Storage request too large.' >&2
        return 1
    fi

    # Retry only connection establishment, never replay a sent mutation.
    response=$(printf '%s\n' "$request" | timeout --kill-after=1 "$timeout" \
        socat -t "$timeout" STDIO "TCP4-CONNECT:$endpoint,retry=20,interval=0.05") || {
        echo 'Storage unavailable or request outcome unknown.' >&2
        return 1
    }

    response=$(jq -cse '
        select(length == 1)
        | .[0]
        | select(
            type == "object"
            and (.ok | type == "boolean")
            and (if .ok then true else (.error | type == "string") end)
        )
    ' <<< "$response") || {
        echo 'Invalid storage response.' >&2
        return 1
    }

    if [[ $(jq -r '.ok' <<< "$response") != true ]]; then
        error=$(jq -r '.error' <<< "$response")
        [[ "$error" != not_found ]] || return 2
        printf 'Storage error: %s\n' "$error" >&2
        return 1
    fi

    printf '%s\n' "$response"
}

etcd_health() {
    etcd_call '{"action":"health"}'
}

etcd_get() {
    local response rc

    response=$(etcd_call "$(jq -cn --arg key "$1" '
        {action: "get", key: $key}
    ')") || {
        rc=$?
        return "$rc"
    }

    jq -er '.value | select(type == "string")' <<< "$response"
}

# Only absence becomes an empty successful result. Transport errors propagate.
etcd_get_optional() {
    local rc

    etcd_get "$1" && return 0
    rc=$?
    [[ "$rc" -eq 2 ]]
}

etcd_put() {
    etcd_call "$(jq -cn --arg key "$1" --arg value "$2" '
        {action: "put", key: $key, value: $value}
    ')" > /dev/null
}

etcd_delete() {
    etcd_call "$(jq -cn --arg key "$1" '
        {action: "delete", key: $key}
    ')" > /dev/null
}

etcd_list() {
    local response

    response=$(etcd_call "$(jq -cn --arg prefix "${1:-}" '
        {action: "list", prefix: $prefix}
    ')") || return 1

    jq -er '.keys | select(type == "array") | .[]' <<< "$response" ||
        [[ $(jq '.keys | length' <<< "$response") == 0 ]]
}

etcd_pod_names() {
    local keys key name

    keys=$(etcd_list pods) || return 1

    while IFS= read -r key; do
        [[ "$key" == pods/*/spec ]] || continue

        name=${key#pods/}
        name=${name%/spec}

        [[ "$name" != */* ]] || continue
        printf '%s\n' "$name"
    done <<< "$keys"
}

etcd_create_pod() {
    etcd_call "$(jq -cn --argjson spec "$1" '
        {action: "create_pod", spec: $spec}
    ')" > /dev/null
}

etcd_assign_pod() {
    local name="$1"
    local uid="$2"
    local node="$3"
    local request

    request=$(jq -cn \
        --arg name "$name" \
        --arg uid "$uid" \
        --arg node "$node" '
        {
            action: "assign_pod",
            name: $name,
            uid: $uid,
            node_name: $node
        }
    ') || return 1

    etcd_call "$request" > /dev/null
}

etcd_mark_pod() {
    etcd_call "$(jq -cn --arg name "$1" '
        {action: "mark_pod", name: $name}
    ')"
}

etcd_finish_pod() {
    etcd_call "$(jq -cn --arg name "$1" --arg uid "$2" '
        {action: "finish_pod", name: $name, uid: $uid}
    ')" > /dev/null
}

etcd_status_pod() {
    etcd_call "$(jq -cn --arg name "$1" --arg uid "$2" --arg value "$3" '
        {action: "status_pod", name: $name, uid: $uid, value: $value}
    ')" > /dev/null
}
