#!/bin/bash
# Real sockets, daemon processes and children; substitute only Pod isolation/networking.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for command in socat jq flock setpriv; do
    command -v "$command" >/dev/null || { echo "SKIP: missing $command"; exit 77; }
done
[[ $EUID == 0 ]] || { echo 'SKIP: run as root in an Ubuntu Node.'; exit 77; }

tmp=$(mktemp -d)
daemon_pid=''
child_pid=''
cleanup() {
    if [[ -n "$daemon_pid" ]]; then
        kill -TERM "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    if [[ -n "$child_pid" ]]; then
        kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/project"
cp -a "$ROOT/lib" "$tmp/project/"
cp "$ROOT/runtimed" "$ROOT/runtime.sh" "$tmp/project/"
sed -i "s|/run/k8s-from-scratch/runtimed.lock|$tmp/runtime.lock|g" "$tmp/project/runtimed"

# Keep the real service, transport, client and reaper; replace privileged operations.
cat >> "$tmp/project/lib/runtime-pod.sh" <<'FIXTURE'
network_health() { printf '{"ok":true}\n'; }
pod_status() {
    local pid
    if [[ -f "$POD_STATE_DIR/$1/pid" ]]; then
        read -r pid < "$POD_STATE_DIR/$1/pid"
        if kill -0 "$pid" 2>/dev/null; then echo running; return; fi
    fi
    echo exited
}
pod_ip() { echo 10.245.1.2; }
pod_start() {
    local name="$1" pid
    shift
    mkdir -p "$POD_STATE_DIR/$name"
    if [[ $(pod_status "$name") != running ]]; then
        (
            exec {RUNTIME_LOCK_FD}>&- {RUNTIME_SOCKET_LOCK_FD}>&- {RUNTIME_INBOX_FD}>&- 9>&-
            exec sleep 120
        ) </dev/null >/dev/null 2>&1 &
        pid=$!
        RUNTIME_CHILDREN["$pid"]="$name"
        printf '%s\n' "$pid" > "$POD_STATE_DIR/$name/pid"
        printf '%s\n' "$BASHPID" > "$POD_STATE_DIR/$name/owner"
    fi
    jq -cn --args '$ARGS.positional' -- "$@" > "$POD_STATE_DIR/$name/arguments"
    printf '{"state":"running","pod_ip":"10.245.1.2"}\n'
}
pod_stop() {
    local pid
    if [[ -f "$POD_STATE_DIR/$1/pid" ]]; then
        read -r pid < "$POD_STATE_DIR/$1/pid"
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$POD_STATE_DIR/$1/pid"
    fi
}
FIXTURE

export RUNTIME_SOCKET="$tmp/runtime.sock" RUNTIME_TIMEOUT=5
export POD_STATE_DIR="$tmp/pods" NAMESPACE_DIR="$tmp/namespaces" ROOTFS="$tmp/rootfs"
source "$tmp/project/lib/runtime-client.sh"

start_daemon() {
    bash "$tmp/project/runtimed" > "$tmp/daemon.log" 2>&1 &
    daemon_pid=$!
    for ((attempt=0; attempt<50; attempt++)); do
        if runtime_health >/dev/null 2>&1; then return 0; fi
        if ! kill -0 "$daemon_pid" 2>/dev/null; then
            if grep -q 'socket(.*Operation not permitted' "$tmp/daemon.log"; then
                echo 'SKIP: this environment forbids UNIX sockets; run inside an Ubuntu Node.'
                return 77
            fi
            cat "$tmp/daemon.log" >&2
            return 1
        fi
        sleep 0.05
    done
    cat "$tmp/daemon.log" >&2
    return 1
}

start_daemon
[[ $(runtime_status sample) == exited ]]
runtime_start sample 10.245.1.2 24 10.245.1.1 -- /bin/echo 'two words' '' '--flag' | jq -e '.state == "running"' >/dev/null
read -r child_pid < "$POD_STATE_DIR/sample/pid"
[[ $(cat "$POD_STATE_DIR/sample/owner") == "$daemon_pid" ]]
jq -e '.[4:] == ["/bin/echo", "two words", "", "--flag"]' "$POD_STATE_DIR/sample/arguments" >/dev/null
[[ $(runtime_status sample) == running ]]
[[ $(runtime_ip sample) == 10.245.1.2 ]]
runtime_start sample 10.245.1.2 24 10.245.1.1 -- /bin/sleep 120 >/dev/null
[[ $(cat "$POD_STATE_DIR/sample/pid") == "$child_pid" ]]

if bash "$tmp/project/runtimed" > "$tmp/duplicate.log" 2>&1; then
    echo 'FAIL: duplicate daemon accepted.' >&2
    exit 1
fi
if runtime_call '{"action":"stop","pod":"../escape"}' >/dev/null 2>&1; then exit 1; fi
if runtime_call '{"action":"health","extra":true}' >/dev/null 2>&1; then exit 1; fi
if runtime_call '{"action":"start","pod":"x","ip":"10.245.1.2","prefix":24,"gateway":"10.245.1.1","command":["/bin/echo","\u0000"]}' >/dev/null 2>&1; then exit 1; fi

# Stopping the daemon releases its lock while the simulated Pod remains alive.
kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=''
kill -0 "$child_pid"
flock -n "$tmp/runtime.lock" true
[[ ! -S "$RUNTIME_SOCKET" ]]
start_daemon
[[ $(runtime_status sample) == running ]]
[[ $(bash "$tmp/project/runtime.sh" status sample) == running ]]
runtime_stop sample
runtime_stop sample
[[ $(runtime_status sample) == exited ]]
child_pid=''

# Abrupt daemon death must not retain the lifetime lock in its listener.
kill -KILL "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=''
for ((attempt=0; attempt<50; attempt++)); do
    if flock -n "$tmp/runtime.lock" true && flock -n "$RUNTIME_SOCKET.lock" true; then break; fi
    sleep 0.05
done
start_daemon
runtime_health >/dev/null
printf 'PASS: real IPC, argument boundaries, direct child ownership, repeat start/stop, validation, duplicate prevention, graceful restart and crash recovery.\n'
