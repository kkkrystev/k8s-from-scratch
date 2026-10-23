create_pod() {
    local node=''
    local pod_name spec

    if [[ ${1:-} == --node ]]; then
        if [[ $# -lt 4 ]]; then
            echo "Usage: $0 create [--node <node>] <name> <command> [args...]" >&2
            return 1
        fi

        node="$2"
        validate_name "$node" || return 1
        shift 2
    fi

    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 create [--node <node>] <name> <command> [args...]" >&2
        return 1
    fi

    pod_name="$1"
    shift

    validate_name "$pod_name" || return 1

    spec=$(json_build_spec "$pod_name" "$@") || return 1
    spec=$(jq -c --arg node "$node" '
        . + {
            node_name: $node
        }
    ' <<< "$spec") || return 1

    etcd_create_pod "$spec" || return 1

    if [[ -n "$node" ]]; then
        echo "Pod '$pod_name' created on '$node'."
    else
        echo "Pod '$pod_name' created; awaiting Node assignment."
    fi
}
