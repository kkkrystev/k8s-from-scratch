# Container metadata helpers.
# Expects CONTAINER_STATE_DIR to be set by the caller (container.sh).

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

# Store argv as NUL-delimited bytes so spaces in arguments survive.
write_command() {
    local dir="$1"
    shift
    printf '%s\0' "$@" > "${dir}/command"
}

# Field 22 of /proc/<pid>/stat is starttime in clock ticks since boot.
# Returns empty string if the file is gone.
read_pid_start() {
    local pid="$1"
    awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true
}

# Return true (0) if the recorded PID still refers to the same process.
# A mismatch means the PID was reused after our process exited.
pid_is_ours() {
    local pid="$1" recorded_start="$2"

    [[ -f "/proc/${pid}/stat" ]] || return 1

    local current_start
    current_start=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null) || return 1

    [[ "$current_start" == "$recorded_start" ]]
}

# Find the workload PID: the direct child of the unshare process.
# unshare --fork creates one child; we read it from the Linux procfs
# children file.  We retry up to ~1 s because the child may not have
# appeared in the file immediately after the background launch.
# Prints the PID on success; returns 1 if the child never appears
# (e.g. the command exited before we could observe it).
# Return true (0) if the container's workload is still alive.
# Checks workload_pid first (stable, lives for the full container lifetime).
# Falls back to unshare_pid only when workload_pid is empty, which can happen
# for commands that exit before find_workload_pid captures the child.
container_is_running() {
    local cdir="$1"
    local state
    state=$(read_meta "$cdir" state)
    [[ "$state" == "running" ]] || return 1

    local wpid wstart
    wpid=$(read_meta "$cdir" workload_pid)
    wstart=$(read_meta "$cdir" workload_start)

    if [[ -n "$wpid" ]]; then
        pid_is_ours "$wpid" "$wstart"
        return
    fi

    local upid ustart
    upid=$(read_meta "$cdir" unshare_pid)
    ustart=$(read_meta "$cdir" unshare_start)
    pid_is_ours "$upid" "$ustart"
}

# Resolve the live state of a container, correcting stale "running" records.
# Prints one of: running, exited, unknown
resolve_state() {
    local cdir="$1"
    local recorded
    recorded=$(read_meta "$cdir" state)

    if [[ "$recorded" == "running" ]]; then
        if container_is_running "$cdir"; then
            echo "running"
        else
            # Process is gone but state was never updated — fix it now.
            # exited_at records when termination was detected, not when it occurred.
            # The exit code cannot be recovered at this point.
            write_meta "$cdir" state "exited"
            [[ -z "$(read_meta "$cdir" exited_at)" ]] && \
                write_meta "$cdir" exited_at "$(date +%s)"
            # Mirror the correction into etcd so other components see it.
            local pod_name exited_at started_at
            pod_name=$(basename "$cdir")
            started_at=$(read_meta "$cdir" started_at)
            exited_at=$(read_meta "$cdir" exited_at)
            etcd_put "containers/${pod_name}/status" \
                "$(json_build_status "exited" "$started_at" "$exited_at" null null "$(read_meta "$cdir" log)")"
            echo "exited"
        fi
        return
    fi

    if [[ -n "$recorded" ]]; then
        echo "$recorded"
    else
        echo "unknown"
    fi
}

find_workload_pid() {
    local unshare_pid="$1"
    local children_file="/proc/${unshare_pid}/task/${unshare_pid}/children"
    local workload_pid
    local i

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
