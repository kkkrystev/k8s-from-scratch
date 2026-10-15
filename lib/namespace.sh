run_isolated() {
    local container_name="$1" ns_uts_path="$2" rootfs="$3"
    shift 3

    exec unshare "--uts=${ns_uts_path}" --pid --fork --mount -- /bin/bash -c '
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
