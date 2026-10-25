# Source this library; it loads the existing RPC client.
source "$(dirname -- "${BASH_SOURCE[0]}")/../rpc.sh"

ipam_health() {
    rpc_call "${IPAM_SOCKET:-/run/k8s-from-scratch/ipam.sock}" '{"action":"health"}'
}

ipam_allocate() {
    [[ $# -eq 1 ]] || { echo 'Usage: ipam_allocate <pod>' >&2; return 1; }
    local request
    request=$(jq -cn --arg pod "$1" '{action:"allocate",pod:$pod}') || return 1
    rpc_call "${IPAM_SOCKET:-/run/k8s-from-scratch/ipam.sock}" "$request"
}

ipam_release() {
    [[ $# -eq 1 ]] || { echo 'Usage: ipam_release <pod>' >&2; return 1; }
    local request
    request=$(jq -cn --arg pod "$1" '{action:"release",pod:$pod}') || return 1
    rpc_call "${IPAM_SOCKET:-/run/k8s-from-scratch/ipam.sock}" "$request"
}
