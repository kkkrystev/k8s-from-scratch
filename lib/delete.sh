cmd_delete() {
    [[ $# -gt 0 ]] || { echo "Usage: $0 delete <name> [name ...]" >&2; return 1; }
    local timeout="${DELETE_TIMEOUT:-30}"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || return 1
    local name response uid spec status deadline failed=0 done_deleting rc
    for name in "$@"; do
        validate_name "$name" || { failed=1; continue; }
        if response=$(etcd_mark_pod "$name"); then :; else
            rc=$?
            [[ "$rc" != 2 ]] || echo "Pod '$name' not found." >&2
            failed=1; continue
        fi
        uid=$(jq -er '.uid' <<< "$response") || return 1
        echo "Pod '$name' marked for deletion, waiting..."
        deadline=$((SECONDS + timeout)); done_deleting=0
        while ((SECONDS < deadline)); do
            # A concurrent delete may finish, then someone may reuse the name.
            spec=$(etcd_get_optional "pods/$name/spec") || break
            if [[ -z "$spec" || $(jq -r '.uid' <<< "$spec") != "$uid" ]]; then
                done_deleting=1; break
            fi
            status=$(etcd_get_optional "pods/$name/status") || break
            if [[ $(json_get_field "$status" state) == terminated ]]; then
                if etcd_finish_pod "$name" "$uid"; then done_deleting=1; break; fi
                # Re-read after a possible concurrent finish; never delete a new UID.
            fi
            sleep 0.2
        done
        if ((done_deleting)); then
            echo "Pod '$name' deleted."
        else
            echo "Deletion not confirmed for '$name'. Check server/kubelet; request is retained if accepted." >&2
            failed=1
        fi
    done
    return "$failed"
}
