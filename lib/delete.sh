cmd_delete() {
    [[ $# -gt 0 ]] || { echo "Usage: $0 delete <name> [name ...]" >&2; return 1; }
    local timeout="${DELETE_TIMEOUT:-30}"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'DELETE_TIMEOUT must be positive seconds.' >&2; return 1; }
    local name status state deadline failed=0 done_deleting
    for name in "$@"; do
        if ! validate_name "$name"; then failed=1; continue; fi
        if ! etcd_get "pods/$name/spec" >/dev/null; then
            echo "Pod '$name' not found." >&2
            failed=1
            continue
        fi
        if ! etcd_put "pods/$name/deleting" 1; then failed=1; continue; fi
        echo "Pod '$name' marked for deletion, waiting..."
        deadline=$((SECONDS + timeout))
        done_deleting=0
        while ((SECONDS < deadline)); do
            status=$(etcd_get "pods/$name/status") || status=""
            if ! state=$(json_get_field "$status" state); then break; fi
            if [[ "$state" == terminated ]]; then
                if rm -rf -- "$ETCD_DIR/pods/$name"; then
                    echo "Pod '$name' deleted."
                    done_deleting=1
                fi
                break
            fi
            sleep 0.2
        done
        if [[ $done_deleting -eq 0 ]]; then
            echo "Deletion not completed within ${timeout}s for '$name'. Request retained; check kubelet and retry delete." >&2
            failed=1
        fi
    done
    return "$failed"
}
