run_isolated() {
    local container_name="$1" rootfs="$2"
    shift 2

    exec unshare --uts --pid --fork --mount -- /bin/bash -c '
        set -euo pipefail

        rootfs="$1"
        container_name="$2"
        shift 2

        hostname "$container_name"

        mount --make-rprivate /
        mount -t proc proc "$rootfs/proc"

        exec chroot "$rootfs" "$@"
    ' container-init "$rootfs" "$container_name" "$@"
}
