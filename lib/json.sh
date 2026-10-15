# JSON helpers for the fixed schemas used in this project.
# Not a general-purpose JSON library — only handles the shapes defined here.

# Usage: json_build_status <state> <started_at> <exited_at> <exit_code> <log>
json_build_status() {
    local state="$1" started_at="$2" exited_at="$3" exit_code="$4" log="$5"

    local started_at_val exited_at_val exit_code_val log_val

    [[ "$started_at" == "null" || -z "$started_at" ]] && started_at_val="null" || started_at_val="$started_at"
    [[ "$exited_at"  == "null" || -z "$exited_at"  ]] && exited_at_val="null"  || exited_at_val="$exited_at"
    [[ "$exit_code"  == "null" || -z "$exit_code"  ]] && exit_code_val="null"  || exit_code_val="$exit_code"
    [[ "$log"        == "null" || -z "$log"        ]] && log_val="null"        || log_val="\"$log\""

    printf '{"state":"%s","started_at":%s,"exited_at":%s,"exit_code":%s,"log":%s}' \
        "$state" "$started_at_val" "$exited_at_val" "$exit_code_val" "$log_val"
}

# Pod spec with a containers array.
# Usage: json_build_spec <pod-name> <executable> [arg1 arg2 ...]
json_build_spec() {
    local pod_name="$1"
    shift
    local args_json="" arg
    for arg in "$@"; do
        [[ -n "$args_json" ]] && args_json+=","
        args_json+="\"$arg\""
    done
    printf '{"name":"%s","containers":[{"name":"%s","command":[%s]}]}' \
        "$pod_name" "$pod_name" "$args_json"
}

# Extract a scalar field value from a JSON object.
# Returns the value without surrounding quotes for strings.
# Usage: json_get_field <json> <fieldname>
json_get_field() {
    local json="$1" field="$2"
    echo "$json" \
        | grep -oE "\"${field}\":(\"[^\"]*\"|[0-9]+|null)" \
        | sed -E "s/\"${field}\"://;s/^\"|\"$//g"
}

# Extract the command from the first container in a pod spec, one arg per line.
# Usage: json_get_container_command <spec_json>
json_get_container_command() {
    local spec_json="$1"
    echo "$spec_json" \
        | grep -oE '"command":\[[^]]*\]' \
        | head -1 \
        | sed 's/"command":\[//;s/\]//' \
        | tr ',' '\n' \
        | sed 's/^"//;s/"$//'
}

# Extract the name of the first container in a pod spec.
# Usage: json_get_container_name <spec_json>
json_get_container_name() {
    local spec_json="$1"
    echo "$spec_json" \
        | grep -oE '"containers":\[\{"name":"[^"]*"' \
        | sed 's/.*"containers":\[{"name":"//;s/"//'
}
