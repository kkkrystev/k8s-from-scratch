#!/bin/bash
set -euo pipefail

ROOTFS="/var/lib/k8s-from-scratch/rootfs"

usage() {
    echo "Usage: $0 create <name> [command [arguments...]]"
}

validate_name() {
    local name="$1"

    if [[ ${#name} -gt 63 ||
          ! "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        echo "Invalid container name: $name" >&2
        return 1
    fi
}

validate_rootfs() {
    if [[ ! -x "$ROOTFS/bin/bash" ]]; then
        echo "Root filesystem is missing. Run setup-rootfs.sh first." >&2
        return 1
    fi
}


run_isolated() {
	local name="$1"
	shift

	unshare --uts --pid --fork --mount-proc /bin/bash -c '
		set -euo pipefail

		rootfs="$1"
		name="$2"
		shift 2

		hostname "$name"

		mount --make-rprivate /
		mount -t proc proc "$rootfs/proc"

		exec chroot "$rootfs" "$@"	
	' container-init "$ROOTFS" "$name" "$@"
}

create_container() {
	local name="$1"
	shift

	validate_name "$name"
	validate_rootfs

	# Default to an interactive shell if no programme is passed
	if [[ $# -eq 0 ]]; then
	    run_isolated "$name" /bin/bash
	else
	    run_isolated "$name" "$@"
	fi	
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
            if [[ $# -eq 0 ]]; then
                echo "Missing container name." >&2
                usage
                return 1
            fi

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








