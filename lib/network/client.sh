source "$(dirname -- "${BASH_SOURCE[0]}")/../rpc.sh"

network_call() {
    # Provisioner may itself wait up to RPC_TIMEOUT (default 5s) for IPAM.
    RPC_TIMEOUT="${NETWORK_TIMEOUT:-10}" \
        rpc_call "${NETWORK_SOCKET:-/run/k8s-from-scratch/network.sock}" "$1"
}

network_health() { network_call '{"action":"health"}'; }

network_pod_call() {
    local request
    request=$(jq -cn --arg action "$1" --arg pod "$2" '{action:$action,pod:$pod}') || return 1
    network_call "$request"
}

network_reserve() {
    [[ $# -eq 1 ]] || { echo 'Usage: network_reserve <pod>' >&2; return 1; }
    network_pod_call reserve "$1"
}

network_detach() {
    [[ $# -eq 1 ]] || { echo 'Usage: network_detach <pod>' >&2; return 1; }
    network_pod_call detach "$1"
}

network_release() {
    [[ $# -eq 1 ]] || { echo 'Usage: network_release <pod>' >&2; return 1; }
    network_pod_call release "$1"
}

# Pass the JSON result from network_reserve as the third argument.
network_attach() {
    [[ $# -eq 3 ]] || { echo 'Usage: network_attach <pod> <netns> <config-json>' >&2; return 1; }
    local request
    request=$(jq -cn --arg pod "$1" --arg ns "$2" --argjson config "$3" '
        {action:"attach",pod:$pod,netns:$ns,
         ip:$config.ip,prefix:$config.prefix,gateway:$config.gateway}
    ') || return 1
    network_call "$request"
}
