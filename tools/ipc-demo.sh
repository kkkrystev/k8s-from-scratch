#!/bin/bash
set -euo pipefail

reply_error() {
    printf '{"ok":false,"error":"%s"}\n' "$1"
}

handle_request() {
    local request action

    # Bound the wait and the amount of data read from one client.
    if ! IFS= read -r -t "$IPC_READ_TIMEOUT" -n 8193 request; then
        reply_error incomplete_request
        return
    fi
    if ((${#request} > 8192)); then
        reply_error request_too_large
        return
    fi
    if ! action=$(jq -ser '
        if length == 1 and (.[0] | type == "object") then
            .[0] | if keys == ["action"] and (.action | type == "string")
                   then .action else error("invalid request") end
        else error("invalid request") end
    ' <<< "$request" 2>/dev/null); then
        reply_error invalid_request
        return
    fi

    case "$action" in
        health) printf '{"ok":true}\n' ;;
        *) reply_error unsupported_action ;;
    esac
}

export LC_ALL=C
export IPC_READ_TIMEOUT="${IPC_READ_TIMEOUT:-3}"
[[ "$IPC_READ_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
    echo 'IPC_READ_TIMEOUT must be a positive integer.' >&2
    exit 1
}

# socat replaces itself with this handler after accepting one connection.
if [[ ${1:-} == --handle && $# -eq 1 ]]; then
    handle_request
    exit
fi

[[ $# -le 1 ]] || { echo "Usage: $0 [absolute-socket-path]" >&2; exit 1; }
socket="${1:-/tmp/kfs-ipc-$UID/demo.sock}"
[[ "$socket" == /* && "$socket" != *[[:space:],:]* && ${#socket} -lt 100 ]] || {
    echo 'Use an absolute socket path under 100 characters, without spaces, commas or colons.' >&2
    exit 1
}

for cmd in socat jq flock setpriv; do
    command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

umask 077
mkdir -p -- "$(dirname -- "$socket")"
exec 9>"$socket.lock"
flock -n 9 || { echo "Daemon already running: $socket" >&2; exit 1; }

# Never remove an ordinary file, directory or symlink at the socket path.
if [[ -L "$socket" || ( -e "$socket" && ! -S "$socket" ) ]]; then
    echo "Refusing to remove non-socket: $socket" >&2
    exit 1
fi
[[ ! -S "$socket" ]] || rm -- "$socket"

child=""
cleanup() {
    trap - EXIT INT TERM
    if [[ -n "$child" ]]; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    [[ ! -S "$socket" ]] || rm -- "$socket"
    # Keep the lock file: removing it could allow separate lock identities.
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

printf 'IPC demo listening on %s\n' "$socket" >&2
while true; do
    # One accept, one handler, then listen again. No concurrent handlers.
    # nofork keeps the listener and handler PID identical. Parent death stops it.
    setpriv --pdeathsig TERM socat \
        "UNIX-LISTEN:$socket,mode=0600,unlink-close=0" \
        'EXEC:bash ./ipc-demo.sh --handle,nofork' &
    child=$!
    if wait "$child"; then rc=0; else rc=$?; fi
    child=""
    [[ ! -S "$socket" ]] || rm -- "$socket"
    if ((rc != 0)); then
        echo "Listener/handler failed (exit $rc)." >&2
        exit "$rc"
    fi
done
