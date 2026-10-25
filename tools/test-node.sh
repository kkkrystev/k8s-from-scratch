#!/bin/bash
# Disposable service fixtures: real processes/signals/locks, no Pod networking.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

IFS= read -r self_stat < /proc/self/stat

if [[ ${self_stat%% *} != "$$" ]]; then
    echo 'SKIP: /proc must match the shell PID namespace (run inside Ubuntu Node).'
    exit 77
fi

tmp=$(mktemp -d)
innocent=''
manual=''

cleanup() {
    if [[ -f "$tmp/project/node" ]]; then
        bash "$tmp/project/node" stop > /dev/null 2>&1 || true
    fi

    if [[ -n "$innocent" ]]; then
        kill -TERM "$innocent" 2> /dev/null || true
        wait "$innocent" 2> /dev/null || true
    fi

    if [[ -n "$manual" ]]; then
        kill -TERM "$manual" 2> /dev/null || true
        wait "$manual" 2> /dev/null || true
    fi

    rm -rf -- "$tmp"
}

trap cleanup EXIT

mkdir -p "$tmp/project/lib" "$tmp/config" "$tmp/data"
cp "$ROOT/node" "$tmp/project/node"
cp "$ROOT/lib/node-config.sh" "$ROOT/lib/node-process.sh" "$tmp/project/lib/"

# Isolate the manager state so production services are not managed by this test.
sed -i "s|^STATE=/run/kfs-node-manager$|STATE=$tmp/state|" "$tmp/project/node"

cat > "$tmp/project/etcdd" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM

while true; do
    sleep 0.1
done
STUB

cat > "$tmp/project/lib/etcd-client.sh" <<'STUB'
etcd_health() {
    [[ ! -f "$ETCD_DIR/fail-health" ]]
}
STUB

cat > "$tmp/config/storage.env" <<ENV
RUN_ETCD=true
RUN_WORKER=false
NODE_NAME=storage
ETCD_ENDPOINT=127.0.0.1:2379
ETCD_DIR=$tmp/data
LOG_DIR=$tmp/logs
ENV

run() {
    bash "$tmp/project/node" "$@"
}

# Start returns; a separate status command sees the live process.
run start "$tmp/config/storage.env" > /dev/null
record=$(cat "$tmp/state/etcdd.pid")
run status | grep -q healthy

# Repeated start reuses the same process.
run start "$tmp/config/storage.env" > /dev/null
[[ $(cat "$tmp/state/etcdd.pid") == "$record" ]]

# Changed valid configuration is rejected while the service runs.
printf 'ETCD_PORT=2380\n' >> "$tmp/config/storage.env"

if run start "$tmp/config/storage.env" > /dev/null 2>&1; then
    echo 'FAIL: running configuration was replaced.' >&2
    exit 1
fi

# Stop uses the snapshot even when the source file is invalid.
printf 'INVALID=oops\n' >> "$tmp/config/storage.env"
run stop "$tmp/config/storage.env" > /dev/null
sed -i '/^ETCD_PORT=/d; /^INVALID=/d' "$tmp/config/storage.env"

# Failed startup rolls back the process launched by that invocation.
touch "$tmp/data/fail-health"

# Shorten deadlines only in the disposable copy.
sed -i 's/SECONDS *+ *20/SECONDS + 1/g' "$tmp/project/lib/node-process.sh"

if run start "$tmp/config/storage.env" > /dev/null 2>&1; then
    echo 'FAIL: unhealthy service was accepted.' >&2
    exit 1
fi

[[ ! -e "$tmp/state/etcdd.pid" ]]
rm "$tmp/data/fail-health"

# A stale ownership record must not cause an unrelated process to be killed.
sleep 60 &
innocent=$!
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
printf '%s:%s:0\n' "$BOOT_ID" "$innocent" > "$tmp/state/etcdd.pid"

run stop > /dev/null
kill -0 "$innocent"
kill -TERM "$innocent"
wait "$innocent" 2> /dev/null || true
innocent=''

# A manually started service is neither adopted nor stopped.
bash "$tmp/project/etcdd" &
manual=$!
sleep 0.2

if run start "$tmp/config/storage.env" > /dev/null 2>&1; then
    echo 'FAIL: manually started service was accepted.' >&2
    exit 1
fi

kill -0 "$manual"
kill -TERM "$manual"
wait "$manual" 2> /dev/null || true
manual=''

# Test service selection without starting actual worker services.
(
    source "$ROOT/lib/node-process.sh"

    SNAPSHOT='{"env":{"RUN_ETCD":"true","RUN_WORKER":"false"}}'
    node_services
    [[ "${SERVICES[*]}" == 'etcdd' ]]

    SNAPSHOT='{"env":{"RUN_ETCD":"false","RUN_WORKER":"true"}}'
    node_services
    [[ "${SERVICES[*]}" == 'ipamd networkd runtimed kubelet' ]]

    SNAPSHOT='{"env":{"RUN_ETCD":"true","RUN_WORKER":"true"}}'
    node_services
    [[ "${SERVICES[*]}" == 'etcdd ipamd networkd runtimed kubelet' ]]
)

# Use a fixed fixture so tests do not depend on the user's cluster topology.
cat > "$tmp/cluster.json" <<ENV
{
    "storage": {
        "name": "node01",
        "endpoint": "127.0.0.1:2379",
        "bind": "0.0.0.0",
        "port": "2379",
        "dir": "$tmp/data"
    },
    "defaults": {},
    "workers": [
        {"name": "node01", "ip": "172.29.240.11", "subnet": "10.245.1.0/24"},
        {"name": "node02", "ip": "172.29.240.12", "subnet": "10.245.2.0/24"}
    ]
}
ENV

bash "$ROOT/tools/generate-node-configs" "$tmp/cluster.json" "$tmp/generated" > /dev/null
source "$ROOT/lib/node-config.sh"

node_config "$tmp/generated/node01.env" | jq -e '
    .RUN_ETCD == "true"
    and .RUN_WORKER == "true"
    and (.NET_ROUTES | fromjson | .["10.245.2.0/24"] == "172.29.240.12")
' > /dev/null

node_config "$tmp/generated/node02.env" | jq -e '
    .RUN_ETCD == "false"
    and .RUN_WORKER == "true"
    and (.NET_ROUTES | fromjson | .["10.245.1.0/24"] == "172.29.240.11")
' > /dev/null

[[ $(find "$tmp/generated" -name '*.env' -type f | wc -l) -eq 2 ]]

# Duplicate subnets are rejected.
jq '.workers[1].subnet = .workers[0].subnet' "$tmp/cluster.json" > "$tmp/bad.json"

if bash "$ROOT/tools/generate-node-configs" "$tmp/bad.json" "$tmp/bad" > /dev/null 2>&1; then
    echo 'FAIL: duplicate subnet was accepted.' >&2
    exit 1
fi

# Differing existing files are retained.
printf '# user edit\n' >> "$tmp/generated/node01.env"

if bash "$ROOT/tools/generate-node-configs" "$tmp/cluster.json" "$tmp/generated" > /dev/null 2>&1; then
    echo 'FAIL: modified configuration was overwritten.' >&2
    exit 1
fi

printf 'PASS: lifecycle, repeated start, snapshot, rollback, stale PID, unmanaged service, service selection, combined configuration and routes.\n'
