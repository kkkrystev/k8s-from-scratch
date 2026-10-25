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
# New process sees committed data; damaged storage is not an empty cluster.
bash -c 'source "$1/lib/storage/store.sh"; source "$1/lib/storage/service.sh"; store_load' _ "$ROOT" | jq -e '.keys["demo/value"] == "quotes \" and spaces"' >/dev/null
printf 'broken\n' > "$ETCD_DIR/state.json"
assert_error '{"action":"health"}' invalid_state 2>/dev/null
printf 'PASS: storage lifecycle, stale UID protection, outage handling, Node filtering.\n'
