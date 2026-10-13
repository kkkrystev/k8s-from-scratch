# JSON helpers for the fixed pod status schema.
# These functions only handle the schemas defined in this project.
# They are not a general-purpose JSON library.

# Emit a status JSON string.
# Pass literal null (unquoted) for absent numeric/null fields.
# Pass an empty string or null for absent string fields.
#
# Usage: json_build_status <state> <started_at> <exited_at> <exit_code> <workload_pid> <log>
json_build_status() {
    local state="$1"
    local started_at="$2"
    local exited_at="$3"
    local exit_code="$4"
    local workload_pid="$5"
    local log="$6"

    local started_at_val exited_at_val exit_code_val workload_pid_val log_val

    # Integers and null are unquoted; strings are quoted.
    if [[ "$started_at" == "null" || -z "$started_at" ]]; then
        started_at_val="null"
    else
        started_at_val="$started_at"
    fi

    if [[ "$exited_at" == "null" || -z "$exited_at" ]]; then
        exited_at_val="null"
    else
        exited_at_val="$exited_at"
    fi

    if [[ "$exit_code" == "null" || -z "$exit_code" ]]; then
        exit_code_val="null"
    else
        exit_code_val="$exit_code"
    fi

    if [[ "$workload_pid" == "null" || -z "$workload_pid" ]]; then
        workload_pid_val="null"
    else
        workload_pid_val="$workload_pid"
    fi

    if [[ "$log" == "null" || -z "$log" ]]; then
        log_val="null"
    else
        log_val="\"$log\""
    fi

    printf '{"state":"%s","started_at":%s,"exited_at":%s,"exit_code":%s,"workload_pid":%s,"log":%s}' \
        "$state" "$started_at_val" "$exited_at_val" "$exit_code_val" "$workload_pid_val" "$log_val"
}

# Emit a spec JSON string.
# command_args are the individual argv elements.
#
# Usage: json_build_spec <name> <command_arg1> [command_arg2 ...]
json_build_spec() {
    local name="$1"
    shift
    local args_json=""
    local arg
    for arg in "$@"; do
        if [[ -n "$args_json" ]]; then
            args_json+=","
        fi
        args_json+="\"$arg\""
    done
    printf '{"name":"%s","command":[%s]}' "$name" "$args_json"
}

# Extract the value of a field from a status or spec JSON string.
# Returns the raw value: a quoted string without its outer quotes,
# an integer, or the literal null.
#
# Usage: json_get_field <json> <fieldname>
json_get_field() {
    local json="$1" field="$2"
    # Match: "field":VALUE where VALUE is "string", integer, or null.
    # Strip surrounding quotes from string values.
    echo "$json" \
        | grep -oE "\"${field}\":(\"[^\"]*\"|[0-9]+|null)" \
        | sed -E "s/\"${field}\"://;s/^\"|\"$//g"
}

# Extract the command array from a spec JSON string as separate lines.
# Each element is printed on its own line (quotes stripped).
#
# Usage: json_get_command <spec_json>
json_get_command() {
    local json="$1"
    echo "$json" \
        | grep -oE '"command":\[[^]]*\]' \
        | sed 's/"command":\[//;s/\]//' \
        | tr ',' '\n' \
        | sed 's/^"//;s/"$//'
}
