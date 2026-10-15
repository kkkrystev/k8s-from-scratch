# get subcommand — pure reader.
# Reads all pod state from etcd. Never writes.
# State corrections are the kubelet's responsibility.
# Expects ETCD_DIR to be set and etcd-client.sh/json.sh/validate.sh sourced.

cmd_get() {
    if [[ $# -eq 0 ]]; then
        echo "Missing pod name." >&2
        echo "Usage: $0 get <name>" >&2
        return 1
    fi

    local name="$1"
    validate_name "$name"

    local status_json
    status_json=$(etcd_get "pods/${name}/status" 2>/dev/null) || true

    if [[ -z "$status_json" ]]; then
        echo "Pod '$name' not found." >&2
        return 1
    fi

    local state started_at exited_at exit_code workload_pid log_path
    state=$(json_get_field "$status_json" "state")
    started_at=$(json_get_field "$status_json" "started_at")
    exited_at=$(json_get_field "$status_json" "exited_at")
    exit_code=$(json_get_field "$status_json" "exit_code")
    workload_pid=$(json_get_field "$status_json" "workload_pid")
    log_path=$(json_get_field "$status_json" "log")

    _fmt_ts() {
        local t="$1"
        if [[ -n "$t" && "$t" != "null" ]]; then
            date -d "@${t}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || date -r "$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || echo "$t"
        fi
    }

    echo "Name:          $name"
    echo "State:         $state"
    echo "Started:       $(_fmt_ts "$started_at")"
    [[ -n "$exited_at" && "$exited_at" != "null" ]] && echo "Exited:        $(_fmt_ts "$exited_at")"
    [[ -n "$exit_code" && "$exit_code" != "null" ]] && echo "Exit code:     $exit_code"
    echo "Workload PID:  ${workload_pid:-}"
    echo "Log:           ${log_path:-}"
}
