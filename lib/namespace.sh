# Low-level namespace launcher.
# Expects ROOTFS to be set by the caller (container.sh).

run_isolated() {
    local name="$1"
    shift

    exec unshare --uts --pid --fork --mount -- /bin/bash -c '
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
