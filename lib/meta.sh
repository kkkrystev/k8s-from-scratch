# Requires etcd-client.sh and json.sh to be sourced before this file.
# Expects CONTAINER_STATE_DIR to be set by the caller.

container_dir() {
    echo "${CONTAINER_STATE_DIR}/$1"
}

write_meta() {
    local dir="$1" key="$2" value="$3"
    printf '%s' "$value" > "${dir}/${key}"
}

read_meta() {
    local dir="$1" key="$2"
    cat "${dir}/${key}" 2>/dev/null || true
}

write_command() {
    local dir="$1"
    shift
    printf '%s\0' "$@" > "${dir}/command"
}

read_pid_start() {
    local pid="$1"
    awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true
}

pid_is_ours() {
    local pid="$1" recorded_start="$2"
    [[ -f "/proc/${pid}/stat" ]] || return 1
    local current_start
    current_start=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null) || return 1
    [[ "$current_start" == "$recorded_start" ]]
}

find_workload_pid() {
    local unshare_pid="$1"
    local children_file="/proc/${unshare_pid}/task/${unshare_pid}/children"
    local workload_pid i

    for (( i = 0; i < 20; i++ )); do
        if [[ -f "$children_file" ]]; then
            workload_pid=$(awk '{print $1}' "$children_file" 2>/dev/null)
            if [[ -n "$workload_pid" ]]; then
                echo "$workload_pid"
                return 0
            fi
        fi
        sleep 0.05
    done

    return 1
}

# Pure read — never writes anything.
# Returns the live state of a container based on the local state dir and /proc.
# Prints one of: running, exited, not_started
# A container stuck in "starting" for more than 10s with no workload PID is treated as exited.
read_actual_state() {
    local cdir="$1"

    if [[ ! -d "$cdir" ]]; then
        echo "not_started"
        return
    fi

    local recorded
    recorded=$(read_meta "$cdir" state)

    if [[ "$recorded" == "running" ]]; then
        local wpid wstart
        wpid=$(read_meta "$cdir" workload_pid)
        wstart=$(read_meta "$cdir" workload_start)

        if [[ -n "$wpid" ]]; then
            pid_is_ours "$wpid" "$wstart" && echo "running" || echo "exited"
            return
        fi

        # workload_pid not captured yet — fall back to unshare_pid
        local upid ustart
        upid=$(read_meta "$cdir" unshare_pid)
        ustart=$(read_meta "$cdir" unshare_start)
        pid_is_ours "$upid" "$ustart" && echo "running" || echo "exited"
        return
    fi

    if [[ "$recorded" == "starting" ]]; then
        local wpid started_at now
        wpid=$(read_meta "$cdir" workload_pid)
        started_at=$(read_meta "$cdir" started_at)
        now=$(date +%s)

        if [[ -z "$wpid" && -n "$started_at" && $(( now - started_at )) -gt 10 ]]; then
            echo "exited"
        else
            echo "starting"
        fi
        return
    fi

    [[ "$recorded" == "exited" ]] && echo "exited" || echo "not_started"
}
