# Expects ETCD_DIR to be set and etcd-client.sh / json.sh / validate.sh sourced.

create_pod() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 create <name> <command> [args...]" >&2
        return 1
    fi

    local pod_name="$1"
    shift

    validate_name "$pod_name"

    if etcd_get "pods/${pod_name}/spec" >/dev/null 2>&1; then
        echo "Pod '$pod_name' already exists." >&2
        return 1
    fi
    
    # Metadata without a spec belongs to no declared pod.
    etcd_delete "pods/${pod_name}/status" || return 1
    etcd_delete "pods/${pod_name}/deleting" || return 1
    local spec
    spec=$(json_build_spec "$pod_name" "$@") || return 1
    etcd_put "pods/${pod_name}/spec" "$spec" || return 1
    echo "Pod '$pod_name' created."
}
