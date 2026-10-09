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
