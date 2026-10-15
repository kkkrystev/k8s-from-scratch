# Expects ETCD_DIR to be set and etcd-client.sh / validate.sh / json.sh sourced.

cmd_delete() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 delete <name> [name ...]" >&2
        return 1
    fi

    local failed=0

    for name in "$@"; do
        if ! validate_name "$name"; then
            failed=1
            continue
        fi

        if ! etcd_get "pods/${name}/spec" >/dev/null 2>&1; then
            echo "Pod '$name' not found." >&2
            failed=1
            continue
        fi

        etcd_put "pods/${name}/deleting" "1"
        echo "Pod '$name' marked for deletion, waiting..."

        # Poll until kubelet writes terminated status, then clean up etcd.
        local status_json state
        while true; do
            status_json=$(etcd_get "pods/${name}/status" 2>/dev/null) || true
            state=$(json_get_field "$status_json" "state")
            [[ "$state" == "terminated" ]] && break
            sleep 1
        done

        rm -rf "${ETCD_DIR}/pods/${name}"
        echo "Pod '$name' deleted."
    done

    return $failed
}
