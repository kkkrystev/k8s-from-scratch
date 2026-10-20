# Fixed project schemas, encoded/decoded by jq rather than regular expressions.
json_build_status() {
    jq -cn \
        --arg state "$1" \
        --arg started "${2:-null}" \
        --arg exited "${3:-null}" \
        --arg code "${4:-null}" \
        --arg log "${5:-null}" \
        --arg ip "${6:-null}" '
        {
            state: $state,
            started_at: ($started | fromjson),
            exited_at: ($exited | fromjson),
            exit_code: ($code | fromjson),
            log: (if $log == "null" then null else $log end),
            pod_ip: (if $ip == "null" then null else $ip end)
        }
    '
}

json_build_spec() {
    local name="$1"
    shift

    jq -cn --arg name "$name" --args \
        '{
            name: $name,
            containers: [{name: $name, command: $ARGS.positional}]
        }' -- "$@"
}

json_get_field() {
    # Missing status/field is ordinary absence, malformed JSON is an error.
    [[ -n "$1" ]] || return 0
    jq -r --arg field "$2" '.[$field] // empty' <<< "$1"
}

json_get_container_command() {
    # NUL delimiters preserve empty arguments, commas, quotes and newlines.
    jq -je '
        .containers[0].command |
        if type == "array" and length > 0 and
           all(.[]; type == "string" and (contains("\u0000")|not))
        then .[] | ., "\u0000"
        else error("command must be a nonempty array of strings without NUL") end
    ' <<< "$1"
}

json_get_container_name() {
    jq -r '.containers[0].name // empty' <<< "$1"
}
