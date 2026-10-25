# Validate and execute requests in the persistent daemon process.
source "$(dirname -- "${BASH_SOURCE[0]}")/pod.sh"

runtime_error_reply() {
    jq -cn --arg error "$1" '{ok: false, error: $error}'
}

runtime_validate_request() {
    jq -cse '
        def pod_name:
            type == "string" and length <= 63
            and test("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$");
        def argument:
            type == "string" and (contains("\u0000") | not);
        if length == 1 then .[0] else error("expected one request") end |
        if type != "object" then error("expected object") else . end |
        if .action == "health" then
            select(keys == ["action"])
        elif .action == "start" then
            select(keys == ["action", "command", "gateway", "ip", "pod", "prefix"])
            | select(.pod | pod_name)
            | select(.ip | type == "string")
            | select(.gateway | type == "string")
            | select(.prefix == 24)
            | select(.command | type == "array" and length > 0
                and all(.[]; argument) and (.[0] | length > 0))
        elif (.action | IN("stop", "status", "ip")) then
            select(keys == ["action", "pod"])
            | select(.pod | pod_name)
        else
            error("unknown action")
        end
    '
}

runtime_execute_request() {
    local request="$1"
    local action pod_name ip prefix gateway
    local payload="$RUNTIME_WORK_DIR/payload"
    local command_file="$RUNTIME_WORK_DIR/command"
    local command=()

    action=$(jq -r .action <<< "$request") || return 1
    if [[ "$action" == health ]]; then
        printf '{"ok":true}\n'
        return 0
    fi

    pod_name=$(jq -r .pod <<< "$request") || return 1
    lock_pod "$pod_name" || return 1

    # Call directly, without $(...), so launchers remain children of this daemon.
    case "$action" in
        start)
            ip=$(jq -r .ip <<< "$request") || return 1
            prefix=$(jq -r .prefix <<< "$request") || return 1
            gateway=$(jq -r .gateway <<< "$request") || return 1
            jq -j '.command[] | ., "\u0000"' <<< "$request" > "$command_file" || return 1
            mapfile -d '' -t command < "$command_file" || return 1
            pod_start "$pod_name" "$ip" "$prefix" "$gateway" -- "${command[@]}" > "$payload" || return 1
            jq -ce '{ok: true, result: .}' "$payload"
            ;;
        status)
            pod_status "$pod_name" > "$payload" || return 1
            jq -cn --arg result "$(cat "$payload")" '{ok: true, result: $result}'
            ;;
        ip)
            pod_ip "$pod_name" > "$payload" || return 1
            jq -cn --arg result "$(cat "$payload")" '{ok: true, result: $result}'
            ;;
        stop)
            pod_stop "$pod_name" >&2 || return 1
            printf '{"ok":true}\n'
            ;;
    esac
}

runtime_dispatch() {
    local request
    local failed=0

    if ! request=$(runtime_validate_request <<< "$1"); then
        runtime_error_reply invalid_request
        return 0
    fi

    runtime_execute_request "$request" || failed=1
    # The per-Pod lock must end with this request, not with the daemon.
    exec 9>&-

    if ((failed)); then
        runtime_error_reply operation_failed
    fi
}
