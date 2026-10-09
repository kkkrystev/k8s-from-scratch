# Container namespace runner and create command.
# Expects ROOTFS and CONTAINER_STATE_DIR to be set by the caller (container.sh).
# Expects validate.sh and meta.sh to be sourced before this file.

# Launches the namespace-isolated workload.  Forks unshare, which in turn forks
# a short-lived bash that sets up hostname/mounts and exec's chroot.  After exec,
# the workload is PID 1 inside its own PID namespace.
run_isolated() {
    local name="$1"
    shift

    unshare --uts --pid --fork --mount -- /bin/bash -c '
        set -euo pipefail

        rootfs="$1"
        name="$2"
        shift 2

        hostname "$name"

        mount --make-rprivate /
        mount -t proc proc "$rootfs/proc"

        exec chroot "$rootfs" "$@"
    ' container-init "$ROOTFS" "$name" "$@"
}

create_container() {
    local detach=0

    if [[ "${1-}" == "-d" ]]; then
        detach=1
        shift
    fi

    if [[ $# -eq 0 ]]; then
        echo "Missing container name." >&2
        usage >&2
        return 1
    fi

    local name="$1"
    shift

    validate_name "$name"
    validate_rootfs

    # Prevent duplicate running containers with the same name.
    local cdir
    cdir=$(container_dir "$name")
    if [[ -d "$cdir" ]]; then
        local state
        state=$(read_meta "$cdir" state)
        if [[ "$state" == "running" ]]; then
            local upid ustart
            upid=$(read_meta "$cdir" unshare_pid)
            ustart=$(read_meta "$cdir" unshare_start)
            if pid_is_ours "$upid" "$ustart"; then
                echo "Container '$name' already exists and is running." >&2
                return 1
            fi
        fi
        # Exited or stale record: remove so the name can be reused.
        rm -rf "$cdir"
    fi

    if [[ $detach -eq 1 ]]; then
        if [[ $# -eq 0 ]]; then
            echo "Detached mode requires a command." >&2
            echo "Example: $0 create -d $name /bin/sleep 3600" >&2
            return 1
        fi
        _create_detached "$name" "$@"
    else
        if [[ $# -eq 0 ]]; then
            validate_default_shell
            run_isolated "$name" /bin/bash
        else
            run_isolated "$name" "$@"
        fi
    fi
}

_create_detached() {
    local name="$1"
    shift

    local cdir
    cdir=$(container_dir "$name")
    mkdir -p "$cdir"

    write_command "$cdir" "$@"
    write_meta "$cdir" state "starting"
    write_meta "$cdir" started_at "$(date +%s)"

    local log="${cdir}/log"

    # Launch unshare in the background: stdin closed, stdout+stderr captured.
    run_isolated "$name" "$@" </dev/null >"$log" 2>&1 &
    local unshare_pid=$!

    # Record the unshare PID and its start time before it can exit.
    local ustart
    ustart=$(read_pid_start "$unshare_pid")
    write_meta "$cdir" unshare_pid "$unshare_pid"
    write_meta "$cdir" unshare_start "$ustart"

    # Find the workload's outer PID (the child unshare forked).
    local workload_pid=""
    if workload_pid=$(find_workload_pid "$unshare_pid"); then
        local wstart
        wstart=$(read_pid_start "$workload_pid")
        write_meta "$cdir" workload_pid "$workload_pid"
        write_meta "$cdir" workload_start "$wstart"
    else
        # The command may have already exited; record empty so later
        # commands know the field is intentionally absent.
        write_meta "$cdir" workload_pid ""
        write_meta "$cdir" workload_start ""
    fi

    # Detect immediate startup failures.
    if ! kill -0 "$unshare_pid" 2>/dev/null; then
        local exit_code=0
        wait "$unshare_pid" 2>/dev/null || exit_code=$?
        write_meta "$cdir" state "exited"
        write_meta "$cdir" exited_at "$(date +%s)"
        write_meta "$cdir" exit_code "$exit_code"
        echo "Container '$name' failed at startup (exit $exit_code). See: $log" >&2
        return 1
    fi

    write_meta "$cdir" state "running"
    echo "Container '$name' started (unshare PID ${unshare_pid})."
    echo "  Log: $log"
}
