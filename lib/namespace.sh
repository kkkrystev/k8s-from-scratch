# Namespace identity and process discovery. No etcd access here.
# All runtime commands run as root, in the same outer PID/mount namespaces.

namespace_identity() {
    # -L follows /proc/<pid>/ns/uts symlinks. It is not a mount check.
    stat -Lc '%d:%i' -- "$1"
}

namespace_mount_identity() {
    local path="$1" fs rc
    if fs=$(findmnt -rn -M "$path" -o FSTYPE); then
        if [[ "$fs" != nsfs ]]; then
            echo "Unexpected filesystem at namespace target: $path ($fs)" >&2
            return 1
        fi
        namespace_identity "$path" || return 1
    else
        rc=$?
        # findmnt returns 1 when this path is not a mount point.
        [[ $rc -eq 1 ]] || return "$rc"
    fi
    # Empty output means no namespace mount, including an ordinary target file.
}

namespace_processes() {
    # Output: outer PID, followed by 'init' or 'member'.
    # Empty output is a successful inspection with no live members.
    local identity="$1" path pid current status key value state
    local outer_ids=() ids=()
    while read -r key value; do
        [[ "$key" != NSpid: ]] || read -ra outer_ids <<< "$value"
    done < /proc/self/status
    [[ ${#outer_ids[@]} -gt 0 ]] || return 1

    for path in /proc/[0-9]*/ns/uts; do
        pid=${path#/proc/}
        pid=${pid%%/*}
        if ! status=$(cat "/proc/$pid/status" 2>/dev/null); then
            [[ ! -d "/proc/$pid" ]] && continue
            echo "Cannot inspect process $pid" >&2
            return 1
        fi
        state=""; ids=()
        while read -r key value; do
            case "$key" in
                State:) state=${value%% *} ;;
                NSpid:) read -ra ids <<< "$value" ;;
            esac
        done <<< "$status"
        [[ "$state" == Z || "$state" == X ]] && continue

        if ! current=$(namespace_identity "$path" 2>/dev/null); then
            # A process can exit between reading status and reading its namespace.
            if [[ ! -d "/proc/$pid" ]]; then continue; fi
            if status=$(cat "/proc/$pid/status" 2>/dev/null) &&
               [[ "$status" =~ State:[[:space:]]+[ZX] ]]; then
                continue
            fi
            echo "Cannot read UTS namespace for process $pid" >&2
            return 1
        fi
        [[ "$current" == "$identity" ]] || continue
        if [[ ${#ids[@]} -eq $((${#outer_ids[@]} + 1)) &&
              ${ids[${#ids[@]}-1]} == 1 ]]; then
            printf '%s init\n' "$pid"
        else
            printf '%s member\n' "$pid"
        fi
    done
}

run_isolated() {
    local container_name="$1" ns_uts_path="$2" ns_net_path="$3" fifo_path="$4" rootfs="$5"
    shift 5
    exec unshare "--uts=$ns_uts_path" "--net=$ns_net_path" --pid --fork --kill-child --mount -- \
        /bin/bash -c '
            set -euo pipefail
            rootfs="$1"; container_name="$2"; fifo_path="$3"
            shift 3
            hostname "$container_name"
            mount --make-rprivate /
            mount -t proc proc "$rootfs/proc"
            # Block until the host signals that networking is wired.
            # EOF (host closed without writing — wiring failed) exits non-zero.
            read -r -N 1 _ < "$fifo_path" || exit 1
            rm -f "$fifo_path"
            exec chroot "$rootfs" "$@"
        ' container-init "$rootfs" "$container_name" "$fifo_path" "$@"
}
