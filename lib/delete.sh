# delete subcommand.
# Expects CONTAINER_STATE_DIR, ETCD_DIR to be set and meta.sh/validate.sh/etcd-client.sh sourced.

cmd_delete() {
    if [[ $# -eq 0 ]]; then
        echo "Missing pod name." >&2
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
        local in_etcd=0
        etcd_get "containers/${name}/status" >/dev/null 2>&1 && in_etcd=1

        if [[ ! -d "$cdir" && $in_etcd -eq 0 ]]; then
            echo "Container '$name' not found." >&2
            failed=1
            continue
        fi

        if [[ -d "$cdir" ]] && container_is_running "$cdir"; then
            wpid=$(read_meta "$cdir" workload_pid)
            wstart=$(read_meta "$cdir" workload_start)
            if [[ -n "$wpid" ]] && pid_is_ours "$wpid" "$wstart"; then
                kill -SIGKILL "$wpid" 2>/dev/null || true
                local i
                for (( i = 0; i < 20; i++ )); do
                    pid_is_ours "$wpid" "$wstart" || break
                    sleep 0.1
                done
            fi
        fi

        [[ -d "$cdir" ]] && rm -rf "$cdir"
        etcd_delete "containers/${name}/spec"
        etcd_delete "containers/${name}/status"
        echo "Deleted '$name'."
    done

    return $failed
}
