# get subcommand.
# Expects CONTAINER_STATE_DIR to be set and meta.sh/validate.sh sourced.

cmd_get() {
    if [[ $# -eq 0 ]]; then
        echo "Missing container name." >&2
        echo "Usage: $0 get <name>" >&2
        return 1
    fi

    local name="$1"
    validate_name "$name"

    local cdir
    cdir=$(container_dir "$name")

    if [[ ! -d "$cdir" ]]; then
        echo "Container '$name' not found." >&2
        return 1
    fi

    local ts human_ts
    _fmt_ts() {
        local t="$1"
        if [[ -n "$t" ]]; then
            date -d "@${t}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || date -r "$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || echo "$t"
        fi
    }

    echo "Name:          $name"
    echo "State:         $(resolve_state "$cdir")"
    echo "Started:       $(_fmt_ts "$(read_meta "$cdir" started_at)")"

    local exited_at
    exited_at=$(read_meta "$cdir" exited_at)
    [[ -n "$exited_at" ]] && echo "Exited:        $(_fmt_ts "$exited_at")"

    local exit_code
    exit_code=$(read_meta "$cdir" exit_code)
    [[ -n "$exit_code" ]] && echo "Exit code:     $exit_code"

    echo "Workload PID:  $(read_meta "$cdir" workload_pid)"
    echo "Log:           ${cdir}/log"
}
