#!/bin/bash
set -euo pipefail

ROOTFS="/var/lib/k8s-from-scratch/rootfs"

if [[ -v CONTAINER_ROOTFS && -n "$CONTAINER_ROOTFS" ]]; then
    ROOTFS="$CONTAINER_ROOTFS"
fi

CONTAINER_STATE_DIR="/var/lib/k8s-from-scratch/containers"
ETCD_DIR="/var/lib/k8s-from-scratch/etcd"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/validate.sh"
source "${SCRIPT_DIR}/lib/etcd-client.sh"
source "${SCRIPT_DIR}/lib/json.sh"
source "${SCRIPT_DIR}/lib/meta.sh"
source "${SCRIPT_DIR}/lib/namespace.sh"
source "${SCRIPT_DIR}/lib/create.sh"
source "${SCRIPT_DIR}/lib/list.sh"
source "${SCRIPT_DIR}/lib/get.sh"
source "${SCRIPT_DIR}/lib/delete.sh"

usage() {
    echo "Usage:"
    echo "  $0 create <name> <command> [args...]   # declare a pod (kubelet will start it)"
    echo "  $0 list                                # list all pods"
    echo "  $0 get <name>                          # show pod details"
    echo "  $0 delete <name> [name ...]            # mark pods for deletion"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        return 1
    fi

    local action="$1"
    shift

    case "$action" in
        create) create_container "$@" ;;
        list)   cmd_list "$@" ;;
        get)    cmd_get "$@" ;;
        delete) cmd_delete "$@" ;;
        *)
            echo "Unknown command: $action" >&2
            usage
            return 1
            ;;
    esac
}

main "$@"
