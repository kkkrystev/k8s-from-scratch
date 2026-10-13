# create subcommand.
# Expects ROOTFS, CONTAINER_STATE_DIR, ETCD_DIR to be set and all lib files sourced.

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

    local cdir
    cdir=$(container_dir "$name")
    if [[ -d "$cdir" ]]; then
        if container_is_running "$cdir"; then
            echo "Container '$name' already exists and is running." >&2
            return 1
        fi
        rm -rf "$cdir"
    fi

    if [[ $detach -eq 1 ]]; then
        if [[ $# -eq 0 ]]; then
            echo "Detached mode requires a command." >&2
            echo "Example: $0 create -d $name /bin/sleep 3600" >&2
            return 1
        fi
        # Write the pod spec to etcd so the kubelet and other components
        # know what this pod is supposed to be running.
        etcd_put "containers/${name}/spec" "$(json_build_spec "$name" "$@")"
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
    local started_at
    started_at=$(read_meta "$cdir" started_at)

    # Write initial status to etcd so other components see the pod immediately.
    etcd_put "containers/${name}/status" \
        "$(json_build_status "starting" "$started_at" null null null "$log")"

    run_isolated "$name" "$@" </dev/null >"$log" 2>&1 &
    local unshare_pid=$!

    local ustart
    ustart=$(read_pid_start "$unshare_pid")
    write_meta "$cdir" unshare_pid "$unshare_pid"
    write_meta "$cdir" unshare_start "$ustart"

    local workload_pid=""
    if workload_pid=$(find_workload_pid "$unshare_pid"); then
        local wstart
        wstart=$(read_pid_start "$workload_pid")
        write_meta "$cdir" workload_pid "$workload_pid"
        write_meta "$cdir" workload_start "$wstart"
    else
        write_meta "$cdir" workload_pid ""
        write_meta "$cdir" workload_start ""
        workload_pid=""
    fi

    if ! kill -0 "$unshare_pid" 2>/dev/null; then
        local exit_code=0
        wait "$unshare_pid" 2>/dev/null || exit_code=$?
        local exited_at
        exited_at=$(date +%s)
        write_meta "$cdir" state "exited"
        write_meta "$cdir" exited_at "$exited_at"
        write_meta "$cdir" exit_code "$exit_code"
        etcd_put "containers/${name}/status" \
            "$(json_build_status "exited" "$started_at" "$exited_at" "$exit_code" "$workload_pid" "$log")"
        if [[ $exit_code -eq 0 ]]; then
            echo "Container '$name' ran and exited successfully."
        else
            echo "Container '$name' failed at startup (exit $exit_code). See: $log" >&2
            return 1
        fi
        return 0
    fi

    # The process exists — namespace setup may still be in progress.
    # 'running' means the workload process is alive, not that it is fully ready.
    write_meta "$cdir" state "running"
    etcd_put "containers/${name}/status" \
        "$(json_build_status "running" "$started_at" null null "$workload_pid" "$log")"

    echo "Container '$name' started (PID ${workload_pid:-${unshare_pid}})."
    echo "  Log: $log"
}
