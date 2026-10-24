#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/etcd-client.sh"

usage() {
    echo "Usage:"
    echo "  $0 health"
    echo "  $0 put <key> <value>   # write a value"
    echo "  $0 get <key>           # read a value"
    echo "  $0 delete <key>        # remove a key"
    echo "  $0 list [<prefix>]     # list keys under prefix"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        return 1
    fi

    local action="$1"
    shift

    case "$action" in
        health) etcd_health ;;
        put)
            if [[ $# -lt 2 ]]; then
                echo "Usage: $0 put <key> <value>" >&2
                return 1
            fi
            etcd_put "$1" "$2"
            ;;
        get)
            if [[ $# -eq 0 ]]; then
                echo "Usage: $0 get <key>" >&2
                return 1
            fi
            local rc
            if etcd_get "$1"; then :; else
                rc=$?
                [[ "$rc" != 2 ]] || echo "Key not found: $1" >&2
                return "$rc"
            fi
            echo
            ;;
        delete)
            if [[ $# -eq 0 ]]; then
                echo "Usage: $0 delete <key>" >&2
                return 1
            fi
            etcd_delete "$1"
            ;;
        list)
            etcd_list "${1:-}"
            ;;
        *)
            echo "Unknown command: $action" >&2
            usage
            return 1
            ;;
    esac
}

ETCD_ENDPOINT=$(etcd_resolve_endpoint) || exit 1

main "$@"
