#!/bin/bash
# No sockets, namespaces or production services. Real Bash children, locks and FIFOs.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
    local pid
    for pid in "${!RUNTIME_CHILDREN[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf -- "$tmp"
}
declare -A RUNTIME_CHILDREN=()
trap cleanup EXIT
export RUNTIME_WORK_DIR="$tmp/work" POD_STATE_DIR="$tmp/pods" NAMESPACE_DIR="$tmp/ns"
export RUNTIME_TIMEOUT=3
mkdir -p "$RUNTIME_WORK_DIR" "$POD_STATE_DIR" "$NAMESPACE_DIR"
source "$ROOT/lib/runtime/service.sh"
source "$ROOT/lib/runtime/transport.sh"

reply="$tmp/reply"
for request in \
    '{"action":"health","extra":1}' \
    '{"action":"status","pod":"../escape"}' \
    '{"action":"health"} {"action":"health"}' \
    '{"action":"start","pod":"x","ip":"10.245.1.2","prefix":24,"gateway":"10.245.1.1","command":["/bin/echo","\u0000"]}' \
    '{"action":"start","pod":"x","ip":"10.245.1.2","prefix":24,"gateway":"10.245.1.1","command":[]}'; do
    runtime_dispatch "$request" > "$reply" 2> "$tmp/expected-errors"
    jq -e '.ok == false and .error == "invalid_request"' "$reply" >/dev/null
done
runtime_dispatch '{"action":"health"}' > "$reply"
jq -e '.ok == true' "$reply" >/dev/null

# Exercise real pod_start orchestration, replacing only privileged setup and readiness.
pod_status() { echo exited; }
prepare_pod_files() { mkdir -p "$POD_STATE_DIR/$1"; }
wait_for_network_namespace() { return 0; }
network_attach() { return 0; }
signal_network_ready() { return 0; }
run_isolated() {
    shift 5
    jq -cn --args '$ARGS.positional' -- "$@" > "$tmp/arguments"
    exec sleep 30
}
wait_for_workload_start() { printf '{"state":"running","pod_ip":"10.245.1.2"}\n'; }

exec {RUNTIME_LOCK_FD}>"$tmp/lifetime.lock"
flock -n "$RUNTIME_LOCK_FD"
exec {RUNTIME_SOCKET_LOCK_FD}>"$tmp/socket.lock"
flock -n "$RUNTIME_SOCKET_LOCK_FD"
mkfifo "$RUNTIME_WORK_DIR/inbox"
exec {RUNTIME_INBOX_FD}<>"$RUNTIME_WORK_DIR/inbox"
runtime_dispatch '{"action":"start","pod":"sample","ip":"10.245.1.2","prefix":24,"gateway":"10.245.1.1","command":["/bin/echo","two words","","--flag"]}' > "$reply"
jq -e '.ok and .result.state == "running"' "$reply" >/dev/null
[[ ${#RUNTIME_CHILDREN[@]} == 1 ]]
for ((attempt=0; attempt<50; attempt++)); do
    [[ ! -f "$tmp/arguments" ]] || break
    sleep 0.02
done
jq -e '. == ["/bin/echo", "two words", "", "--flag"]' "$tmp/arguments" >/dev/null
exec {RUNTIME_LOCK_FD}>&- {RUNTIME_SOCKET_LOCK_FD}>&-
flock -n "$tmp/lifetime.lock" true
flock -n "$tmp/socket.lock" true
flock -n "$NAMESPACE_DIR/.locks/sample" true
for pid in "${!RUNTIME_CHILDREN[@]}"; do kill -TERM "$pid"; done
sleep 0.1
runtime_reap_children
[[ ${#RUNTIME_CHILDREN[@]} == 0 ]]

network_attach() { return 1; }
pod_release_namespace() { return 0; }
runtime_dispatch '{"action":"start","pod":"failed-start","ip":"10.245.1.2","prefix":24,"gateway":"10.245.1.1","command":["/bin/sleep","30"]}' > "$reply" 2> "$tmp/expected-errors"
jq -e '.ok == false and .error == "operation_failed"' "$reply" >/dev/null
for pid in "${!RUNTIME_CHILDREN[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then echo 'FAIL: failed startup left a launcher running.' >&2; exit 1; fi
done
runtime_reap_children
[[ ${#RUNTIME_CHILDREN[@]} == 0 ]]
[[ -d "$POD_STATE_DIR/failed-start" ]]
flock -n "$NAMESPACE_DIR/.locks/failed-start" true

pod_status() { return 1; }
runtime_dispatch '{"action":"status","pod":"sample"}' > "$reply"
jq -e '.ok == false and .error == "operation_failed"' "$reply" >/dev/null
flock -n "$NAMESPACE_DIR/.locks/sample" true

# Real connection handler -> FIFO -> persistent dispatcher -> atomic reply -> handler.
printf '{"action":"health"}\n' | bash "$ROOT/daemons/runtimed" --handle > "$tmp/handler-reply" &
handler_pid=$!
IFS= read -r -t 5 directory <&"$RUNTIME_INBOX_FD"
runtime_process_directory "$directory"
wait "$handler_pid"
jq -e '.ok == true' "$tmp/handler-reply" >/dev/null
[[ ! -e "$directory" ]]
printf '{' | bash "$ROOT/daemons/runtimed" --handle > "$tmp/handler-reply"
jq -e '.ok == false and .error == "incomplete_request"' "$tmp/handler-reply" >/dev/null

# Client encoding and extraction, substituting only rpc_call.
source "$ROOT/lib/runtime/client.sh"
rpc_call() {
    printf '%s\n' "$2" > "$tmp/client-request"
    printf '{"ok":true,"result":{"state":"running"}}\n'
}
runtime_start sample 10.245.1.2 24 10.245.1.1 -- /bin/echo 'two words' '' --flag > "$reply"
jq -e '.command == ["/bin/echo", "two words", "", "--flag"]' "$tmp/client-request" >/dev/null
jq -e '.state == "running"' "$reply" >/dev/null
rpc_call() { printf '{"ok":false,"error":"failed"}\n'; return 1; }
if runtime_status sample > "$reply" 2>/dev/null; then exit 1; fi
[[ ! -s "$reply" ]]
printf 'PASS: validation, start orchestration, child ownership/reaping, FD isolation, per-Pod lock release, FIFO request/reply and client errors.\n'
