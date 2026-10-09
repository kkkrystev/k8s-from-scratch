#!/bin/bash
set -euo pipefail

# Use the default unless a nonempty environment variable overrides it.
ROOTFS="/var/lib/k8s-from-scratch/rootfs"

if [[ -v CONTAINER_ROOTFS ]]; then
    if [[ -n "$CONTAINER_ROOTFS" ]]; then
        ROOTFS="$CONTAINER_ROOTFS"
    fi
fi

CONTAINER_STATE_DIR="/var/lib/k8s-from-scratch/containers"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/validate.sh"
source "${SCRIPT_DIR}/lib/meta.sh"
source "${SCRIPT_DIR}/lib/run.sh"

usage() {
    echo "Usage:"
    echo "  $0 create <name>                              # foreground /bin/bash"
    echo "  $0 create <name> <command> [arguments...]     # foreground command"
    echo "  $0 create -d <name> <command> [arguments...]  # background command"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        return 1
    fi

    local action="$1"
    shift

    case "$action" in
        create)
            create_container "$@"
            ;;
        *)
            echo "Unknown command: $action" >&2
            usage
            return 1
            ;;
    esac
}

main "$@"
