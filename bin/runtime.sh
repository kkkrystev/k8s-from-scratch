#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/runtime/client.sh"

usage() {
    echo "Usage: $0 health | status <pod> | ip <pod> | stop <pod>" >&2
    echo "       $0 start <pod> --ip <ip> --prefix <prefix> --gateway <gateway> -- <command> [args...]" >&2
}

main() {
    [[ $# -ge 1 ]] || { usage; return 1; }
    local action="$1"
    shift
    if [[ "$action" == health ]]; then
        [[ $# == 0 ]] || { usage; return 1; }
        runtime_health
        return
    fi
    [[ $# -ge 1 ]] || { usage; return 1; }
    local pod_name="$1"
    shift
    case "$action" in
        status) runtime_status "$pod_name" "$@" ;;
        ip) runtime_ip "$pod_name" "$@" ;;
        stop) runtime_stop "$pod_name" "$@" ;;
        start)
            local ip='' prefix='' gateway='' option
            while [[ $# -gt 0 && "$1" != -- ]]; do
                [[ $# -ge 2 && "$2" != -- ]] || { usage; return 1; }
                option="$1"
                case "$option" in
                    --ip) [[ -z "$ip" ]] || return 1; ip="$2" ;;
                    --prefix) [[ -z "$prefix" ]] || return 1; prefix="$2" ;;
                    --gateway) [[ -z "$gateway" ]] || return 1; gateway="$2" ;;
                    *) usage; return 1 ;;
                esac
                shift 2
            done
            [[ "${1:-}" == -- ]] || { usage; return 1; }
            shift
            runtime_start "$pod_name" "$ip" "$prefix" "$gateway" -- "$@"
            ;;
        *) usage; return 1 ;;
    esac
}

main "$@"
