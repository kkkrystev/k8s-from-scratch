create_pod() {
    if [[ $# -lt 4 || $1 != --node ]]; then
        echo "Usage: $0 create --node <node> <name> <command> [args...]" >&2
        return 1
    fi
    local node="$2" pod_name="$3" spec
    shift 3
    validate_name "$node" && validate_name "$pod_name" || return 1
    spec=$(json_build_spec "$pod_name" "$@" | jq -c --arg node "$node" '. + {node_name:$node}') || return 1
    etcd_create_pod "$spec" || return 1
    echo "Pod '$pod_name' created on '$node'."
}
