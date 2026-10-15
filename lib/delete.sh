# Expects ETCD_DIR to be set and etcd-client.sh / validate.sh sourced.

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
        echo "Pod '$name' marked for deletion."
    done

    return $failed
}
