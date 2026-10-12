# delete subcommand.
# Expects CONTAINER_STATE_DIR to be set and meta.sh/validate.sh sourced.

cmd_delete() {
    if [[ $# -eq 0 ]]; then
        echo "Missing container name." >&2
        echo "Usage: $0 delete <name> [name ...]" >&2
        return 1
    fi

    local failed=0
    local name cdir wpid wstart

    for name in "$@"; do
        if ! validate_name "$name"; then
            failed=1
            continue
        fi

        cdir=$(container_dir "$name")
        if [[ ! -d "$cdir" ]]; then
            echo "Container '$name' not found." >&2
            failed=1
            continue
        fi

        if container_is_running "$cdir"; then
            wpid=$(read_meta "$cdir" workload_pid)
            wstart=$(read_meta "$cdir" workload_start)
            if [[ -n "$wpid" ]] && pid_is_ours "$wpid" "$wstart"; then
                kill -SIGKILL "$wpid" 2>/dev/null || true
                # Wait up to 2 s for the process to disappear.
                local i
                for (( i = 0; i < 20; i++ )); do
                    pid_is_ours "$wpid" "$wstart" || break
                    sleep 0.1
                done
            fi
        fi

        rm -rf "$cdir"
        echo "Deleted '$name'."
    done

    return $failed
}
