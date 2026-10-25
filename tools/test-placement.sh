#!/bin/bash
# Configuration and scheduling contracts; no production services are started.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
source "$ROOT/lib/node-config.sh"
source "$ROOT/lib/node-process.sh"

# All combinations of independent responsibilities are valid except no services.
for etcd in false true; do
    for worker in false true; do
        for scheduler in false true; do
            cat > "$tmp/node.env" <<ENV
NODE_NAME=test
ETCD_ENDPOINT=127.0.0.1:2379
RUN_ETCD=$etcd
RUN_WORKER=$worker
RUN_SCHEDULER=$scheduler
SCHEDULER_NODES=["a","b"]
NODE_IP=172.29.240.11
POD_SUBNET=10.245.1.0/24
ENV
            if [[ "$etcd$worker$scheduler" == falsefalsefalse ]]; then
                if node_config "$tmp/node.env" > /dev/null 2>&1; then exit 1; fi
                continue
            fi
            config=$(node_config "$tmp/node.env")
            SNAPSHOT=$(jq -cn --argjson env "$config" '{env:$env}')
            node_services
            expected=()
            [[ "$etcd" != true ]] || expected+=(etcdd)
            [[ "$worker" != true ]] || expected+=(ipamd networkd runtimed kubelet)
            [[ "$scheduler" != true ]] || expected+=(scheduler)
            [[ "${SERVICES[*]}" == "${expected[*]}" ]]
        done
    done
done
# Scheduler-only placement emits its own config and preserves the workers list.
jq '.scheduler = {name:"control", interval:"3"}' "$ROOT/config/cluster.json" > "$tmp/cluster.json"
bash "$ROOT/tools/generate-node-configs" "$tmp/cluster.json" "$tmp/generated" > /dev/null
node_config "$tmp/generated/control.env" | jq -e '
    .RUN_SCHEDULER == "true" and .RUN_WORKER == "false" and .RUN_ETCD == "false"
    and .SCHEDULER_INTERVAL == "3"
    and (.SCHEDULER_NODES | fromjson) == ["node01", "node02", "storage"]
' > /dev/null
# Storage can be moved onto an existing worker independently of scheduler placement.
jq '.storage.name="node01" | .storage.endpoint="kfs-node01:2379"' "$tmp/cluster.json" > "$tmp/moved.json"
bash "$ROOT/tools/generate-node-configs" "$tmp/moved.json" "$tmp/moved" > /dev/null
node_config "$tmp/moved/node01.env" | jq -e '.RUN_ETCD == "true" and .RUN_WORKER == "true" and .RUN_SCHEDULER == "false"' > /dev/null
# Old topologies still generate configs, with scheduler disabled.
jq 'del(.scheduler)' "$tmp/cluster.json" > "$tmp/legacy.json"
bash "$ROOT/tools/generate-node-configs" "$tmp/legacy.json" "$tmp/legacy" > /dev/null
node_config "$tmp/legacy/node01.env" | jq -e '.RUN_SCHEDULER == "false"' > /dev/null
# Reject malformed role/worker settings and duplicate or empty candidate lists.
for value in '[]' '["a","a"]' 'null' '[1]' '["bad_name"]'; do
    printf 'NODE_NAME=test\nETCD_ENDPOINT=localhost:2379\nRUN_SCHEDULER=true\nSCHEDULER_NODES=%s\n' "$value" > "$tmp/bad.env"
    if node_config "$tmp/bad.env" > /dev/null 2>&1; then exit 1; fi
done
jq '.scheduler.interval="0"' "$tmp/cluster.json" > "$tmp/bad.json"
if bash "$ROOT/tools/generate-node-configs" "$tmp/bad.json" "$tmp/bad" > /dev/null 2>&1; then exit 1; fi
# Both scheduler entry paths load the same candidates. No daemon is started here.
source "$ROOT/scheduler"
unset ETCD_ENDPOINT
SCHEDULER_INTERVAL=''
scheduler_config "$tmp/cluster.json"
[[ "${NODES[*]}" == 'node01 node02 storage' && "$SCHEDULER_INTERVAL" == 3 ]]
ETCD_ENDPOINT=example:2379
SCHEDULER_NODES='["a","b"]'
SCHEDULER_INTERVAL=2
scheduler_config
[[ "${NODES[*]}" == 'a b' && "$ETCD_ENDPOINT" == example:2379 ]]
# Assigned/deleting Pods and failed assignments must not advance round robin.
etcd_get_optional() {
    case "$1" in
        pods/bound/spec) echo '{"node_name":"a","uid":"bound"}' ;;
        pods/deleting/spec) echo '{"node_name":"","uid":"deleting"}' ;;
        pods/deleting/deleting) echo yes ;;
        */spec) echo '{"node_name":"","uid":"new"}' ;;
    esac
}
etcd_assign_pod() { [[ "$1" != fail ]] || return 1; printf '%s:%s\n' "$1" "$3" >> "$tmp/assignments"; }
schedule_pod bound
schedule_pod deleting
if schedule_pod fail > /dev/null; then exit 1; fi
[[ "$NEXT_NODE" == 0 ]]
schedule_pod one > /dev/null
schedule_pod two > /dev/null
schedule_pod three > /dev/null
[[ $(cat "$tmp/assignments") == $'one:a\ntwo:b\nthree:a' ]]
printf 'PASS: role combinations, scheduler-only Node, storage placement, legacy topology, validation, scheduler config and round robin.\n'
