# get subcommand.
# Expects CONTAINER_STATE_DIR, ETCD_DIR to be set and meta.sh/validate.sh/etcd-client.sh/json.sh sourced.

cmd_get() {
    if [[ $# -eq 0 ]]; then
        echo "Missing pod name." >&2
        echo "Usage: $0 get <name>" >&2
        return 1
    fi

    local name="$1"
    validate_name "$name"

    local status_json
    status_json=$(etcd_get "containers/${name}/status" 2>/dev/null) || true

    if [[ -z "$status_json" ]]; then
        echo "Container '$name' not found." >&2
        return 1
    fi

    local state started_at exited_at exit_code workload_pid log_path
    state=$(json_get_field "$status_json" "state")
    started_at=$(json_get_field "$status_json" "started_at")
    exited_at=$(json_get_field "$status_json" "exited_at")
    exit_code=$(json_get_field "$status_json" "exit_code")
    workload_pid=$(json_get_field "$status_json" "workload_pid")
    log_path=$(json_get_field "$status_json" "log")

    # For running pods, do a live PID check and correct if stale.
    if [[ "$state" == "running" ]]; then
        local cdir
        cdir=$(container_dir "$name")
        if [[ -d "$cdir" ]]; then
            state=$(resolve_state "$cdir")
            # Re-read exited_at in case resolve_state just wrote it.
            if [[ "$state" == "exited" ]]; then
                exited_at=$(read_meta "$cdir" exited_at)
            fi
        else
            state="unknown"
        fi
    fi

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
