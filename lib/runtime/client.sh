# Client functions for the local runtime daemon.
source "$(dirname -- "${BASH_SOURCE[0]}")/../rpc.sh"

runtime_call() {
    local request="$1"
    local response

    if response=$(
        RPC_TIMEOUT="${RUNTIME_TIMEOUT:-60}" \
            rpc_call "${RUNTIME_SOCKET:-/run/k8s-from-scratch/runtime.sock}" "$request"
    ); then
        printf '%s\n' "$response"
    else
        if [[ -n "$response" ]]; then
            printf '%s\n' "$response" >&2
        fi

        return 1
    fi
}

runtime_health() {
    runtime_call '{"action":"health"}'
}

runtime_pod_call() {
    local action="$1"
    local pod_name="$2"
    local request

    request=$(jq -cn \
        --arg action "$action" \
        --arg pod "$pod_name" \
        '{action: $action, pod: $pod}'
    ) || return 1

    runtime_call "$request"
}

runtime_status() {
    if [[ $# -ne 1 ]]; then
        echo 'Usage: runtime_status <pod>' >&2
        return 1
    fi

    local response
    response=$(runtime_pod_call status "$1") || return 1

    jq -er '
        .result |
        if . == "running" or . == "exited" then
            .
        else
            error("invalid runtime status response")
        end
    ' <<< "$response"
}

runtime_ip() {
    if [[ $# -ne 1 ]]; then
        echo 'Usage: runtime_ip <pod>' >&2
        return 1
    fi

    local response
    response=$(runtime_pod_call ip "$1") || return 1

    jq -er '
        .result |
        if type == "string" and length > 0 then
            .
        else
            error("invalid runtime IP response")
        end
    ' <<< "$response"
}

runtime_stop() {
    if [[ $# -ne 1 ]]; then
        echo 'Usage: runtime_stop <pod>' >&2
        return 1
    fi

    runtime_pod_call stop "$1" >/dev/null
}

runtime_start() {
    if [[ $# -lt 6 || "${5:-}" != -- || -z "${6:-}" ]]; then
        echo 'Usage: runtime_start <pod> <ip> <prefix> <gateway> -- <command> [args...]' >&2
        return 1
    fi

    local pod_name="$1"
    local pod_ip="$2"
    local prefix="$3"
    local gateway="$4"
    local request response
    shift 5

    request=$(jq -cn \
        --arg pod "$pod_name" \
        --arg ip "$pod_ip" \
        --argjson prefix "$prefix" \
        --arg gateway "$gateway" \
        --args \
        '{action: "start", pod: $pod, ip: $ip, prefix: $prefix,
          gateway: $gateway, command: $ARGS.positional}' \
        -- "$@"
    ) || return 1

    response=$(runtime_call "$request") || return 1

    jq -ce '
        .result |
        if type == "object" then
            .
        else
            error("invalid runtime start response")
        end
    ' <<< "$response"
}
