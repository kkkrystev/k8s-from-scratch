#!/bin/bash

set -euo pipefail

ROOTFS="/var/lib/k8s-from-scratch/rootfs"

if [[ ! -x "$ROOTFS/bin/bash" ]]; then
    echo "Root filesystem is missing. Run setup-rootfs.sh first."
    exit 1
fi

# Start Bash if no command was supplied.
if [[ $# -eq 0 ]]; then
    set -- /bin/bash
fi

unshare --uts --pid --fork --mount -- /bin/bash -c '
    set -euo pipefail

    rootfs="$1"
    shift

    hostname learning-container

    mount --make-rprivate /
    mount -t proc proc "$rootfs/proc"

    exec chroot "$rootfs" "$@"
' container-init "$ROOTFS" "$@"
