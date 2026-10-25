#!/bin/bash
# Focused tests with an in-process transport; no Docker/root/network resources.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/daemons/kubelet"
source "$ROOT/lib/storage/store.sh"
source "$ROOT/lib/storage/service.sh"
source "$ROOT/lib/cli/create.sh"
source "$ROOT/lib/cli/delete.sh"
ETCD_DIR=$(mktemp -d)
trap 'rm -rf -- "$ETCD_DIR"' EXIT
store_commit '{"version":1,"keys":{}}'
# Exercise the real client encoding/decoding; substitute only the TCP transport.
timeout() { shift 2; "$@"; }
socat() { local request; IFS= read -r request; store_dispatch "$request"; }
assert_error() {
    local result
    result=$(store_dispatch "$1")
    jq -e --arg e "$2" '.ok == false and .error == $e' <<< "$result" >/dev/null
}
etcd_health >/dev/null
[[ -z $(etcd_get_optional missing) ]]
rc=0; etcd_get missing >/dev/null || rc=$?; [[ $rc == 2 ]]
assert_error '{"action":"put","key":"../escape","value":"x"}' invalid_key
assert_error '{"action":"health","extra":1}' invalid_request
etcd_put demo/value 'quotes " and spaces'
[[ $(etcd_get demo/value) == 'quotes " and spaces' ]]
create_pod --node node01 app-a /bin/sleep 3600 >/dev/null
spec=$(etcd_get pods/app-a/spec); uid=$(jq -r .uid <<< "$spec")
assert_error "$(jq -cn --argjson spec "$(jq 'del(.uid)' <<< "$spec")" '{action:"create_pod",spec:$spec}')" already_exists
assert_error '{"action":"put","key":"pods/app-a/spec","value":"{}"}' protected_key
assert_error "$(jq -cn --arg uid "$uid" '{action:"finish_pod",name:"app-a",uid:$uid}')" not_terminated
# An unavailable server must not become absence, nor start a workload.
socat() { return 1; }
rc=0; etcd_get_optional missing >/dev/null 2>&1 || rc=$?; [[ $rc == 1 ]]
NODE_NAME=node01
runtime_status() {
    printf '%s\n' "status $1" >> "$ETCD_DIR/runtime-calls"
    echo exited
}
export ETCD_DIR
rc=0; reconcile_pod app-a 2>/dev/null || rc=$?; [[ $rc == 1 && ! -e "$ETCD_DIR/runtime-calls" ]]
socat() { local request; IFS= read -r request; store_dispatch "$request"; }
NODE_NAME=node02
reconcile_pod app-a
[[ ! -e "$ETCD_DIR/runtime-calls" ]]
# Local ownership reaches launch; foreign ownership never touches runtime.
NODE_NAME=node01
launch_pod() { printf '%s\n' "$1" > "$ETCD_DIR/launched"; }
reconcile_pod app-a
[[ $(cat "$ETCD_DIR/launched") == app-a ]]
# Finish old generation, reuse name, reject delayed status/delete for old UID.
etcd_mark_pod app-a >/dev/null
etcd_status_pod app-a "$uid" "$(json_build_status terminated)"
etcd_finish_pod app-a "$uid"
create_pod --node node02 app-a /bin/sleep 3600 >/dev/null
new_uid=$(etcd_get pods/app-a/spec | jq -r .uid)
[[ "$new_uid" != "$uid" ]]
assert_error "$(jq -cn --arg uid "$uid" '{action:"finish_pod",name:"app-a",uid:$uid}')" conflict
assert_error "$(jq -cn --arg uid "$uid" '{action:"status_pod",name:"app-a",uid:$uid,value:"{\"state\":\"running\"}"}')" conflict
[[ $(etcd_get pods/app-a/spec | jq -r .uid) == "$new_uid" ]]
# CLI deletion finishes an already acknowledged deletion.
etcd_mark_pod app-a >/dev/null
etcd_status_pod app-a "$new_uid" "$(json_build_status terminated)"
cmd_delete app-a >/dev/null
[[ -z $(etcd_pod_names) ]]
# Run dispatch directly under errexit, as in the daemon handler. Each semantic
# reply must leave the process alive, and rejected writes must retain state.
ETCD_DIR="$ETCD_DIR/strict" bash -euo pipefail -s -- "$ROOT" <<'STRICT'
root="$1"
source "$root/lib/validate.sh"
source "$root/lib/storage/store.sh"
source "$root/lib/storage/service.sh"
mkdir -p "$ETCD_DIR"
store_commit '{"version":1,"keys":{}}'
store_dispatch '{"action":"get","key":"missing"}' > "$ETCD_DIR/reply"
jq -e '.ok == false and .error == "not_found"' "$ETCD_DIR/reply" >/dev/null
store_dispatch '{"action":"list","prefix":""}' > "$ETCD_DIR/reply"
jq -e '.ok == true and .keys == []' "$ETCD_DIR/reply" >/dev/null
store_dispatch '{"action":"mark_pod","name":"missing"}' > "$ETCD_DIR/reply"
jq -e '.error == "not_found"' "$ETCD_DIR/reply" >/dev/null
before=$(store_load)
store_dispatch '{"action":"put","key":"pods/forbidden","value":"x"}' > "$ETCD_DIR/reply"
jq -e '.error == "protected_key"' "$ETCD_DIR/reply" >/dev/null
[[ $(store_load) == "$before" ]]
store_dispatch '{"action":"create_pod","spec":{"name":"strict","containers":[{"name":"strict","command":["/bin/sleep","60"]}]}}' > "$ETCD_DIR/reply"
uid=$(jq -er '.uid | select(length > 0)' "$ETCD_DIR/reply")
[[ $(store_load | jq -r '.keys["pods/strict/spec"] | fromjson | .uid') == "$uid" ]]
before=$(store_load)
store_dispatch '{"action":"create_pod","spec":{"name":"strict"}}' > "$ETCD_DIR/reply"
jq -e '.error == "already_exists"' "$ETCD_DIR/reply" >/dev/null
store_dispatch '{"action":"assign_pod","name":"strict","uid":"old","node_name":"node01"}' > "$ETCD_DIR/reply"
jq -e '.error == "conflict"' "$ETCD_DIR/reply" >/dev/null
[[ $(store_load) == "$before" ]]
store_dispatch '{"action":"mark_pod","name":"strict"}' > "$ETCD_DIR/reply"
jq -e --arg uid "$uid" '.ok == true and .uid == $uid' "$ETCD_DIR/reply" >/dev/null
STRICT

# New process sees committed data; damaged storage is not an empty cluster.
bash -c 'source "$1/lib/storage/store.sh"; source "$1/lib/storage/service.sh"; store_load' _ "$ROOT" | jq -e '.keys["demo/value"] == "quotes \" and spaces"' >/dev/null
printf 'broken\n' > "$ETCD_DIR/state.json"
assert_error '{"action":"health"}' invalid_state 2>/dev/null
printf 'PASS: storage lifecycle, stale UID protection, outage handling, Node filtering.\n'
