#!/bin/bash
# Disposable service fixtures: real processes/signals/locks, no Docker or networking.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IFS= read -r self_stat < /proc/self/stat
[[ ${self_stat%% *} == "$$" ]] || { echo 'SKIP: /proc must match the shell PID namespace (run inside Ubuntu Node).'; exit 77; }
tmp=$(mktemp -d)
cleanup() {
    if [[ -f "$tmp/project/node" ]]; then bash "$tmp/project/node" stop >/dev/null 2>&1 || true; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/project/lib" "$tmp/config" "$tmp/data"
cp "$ROOT/node" "$tmp/project/node"
cp "$ROOT/lib/node-config.sh" "$ROOT/lib/node-process.sh" "$tmp/project/lib/"
# Isolate the manager's fixed production path for this disposable fixture only.
sed -i "s|^STATE=/run/kfs-node-manager$|STATE=$tmp/state|" "$tmp/project/node"
cat > "$tmp/project/etcdd" <<'STUB'
#!/bin/bash
trap 'exit 0' TERM
while true; do sleep 0.1; done
STUB
cat > "$tmp/project/lib/etcd-client.sh" <<'STUB'
etcd_health() { [[ ! -f "$ETCD_DIR/fail-health" ]]; }
STUB
cat > "$tmp/config/storage.env" <<ENV
NODE_ROLE=storage
NODE_NAME=storage
ETCD_ENDPOINT=127.0.0.1:2379
ETCD_DIR=$tmp/data
LOG_DIR=$tmp/logs
ENV
run() { bash "$tmp/project/node" "$@"; }
# Background lifetime: start returns, separate status sees the same live PID.
run start "$tmp/config/storage.env" >/dev/null
record=$(cat "$tmp/state/etcdd.pid")
run status | grep -q healthy
run start "$tmp/config/storage.env" >/dev/null
[[ $(cat "$tmp/state/etcdd.pid") == "$record" ]]
# Live config changes rejected; stop uses saved config even when input is broken.
printf 'INVALID=oops\n' >> "$tmp/config/storage.env"
if run start "$tmp/config/storage.env" >/dev/null 2>&1; then exit 1; fi
run stop "$tmp/config/storage.env" >/dev/null
sed -i '/^INVALID=/d' "$tmp/config/storage.env"
# Failed startup rolls back the process it launched.
touch "$tmp/data/fail-health"
# Shorten the test deadline only (production keeps 20 seconds).
sed -i 's/SECONDS+20/SECONDS+1/g' "$tmp/project/lib/node-process.sh"
if run start "$tmp/config/storage.env" >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$tmp/state/etcdd.pid" ]]
rm "$tmp/data/fail-health"
# Stale ownership record must not signal an unrelated process.
sleep 60 & innocent=$!
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
printf '%s:%s:0\n' "$BOOT_ID" "$innocent" > "$tmp/state/etcdd.pid"
run stop >/dev/null
kill -0 "$innocent"
kill -TERM "$innocent"; wait "$innocent" 2>/dev/null || true
# A manually started service is not adopted or terminated.
bash "$tmp/project/etcdd" & manual=$!
sleep 0.2
if run start "$tmp/config/storage.env" >/dev/null 2>&1; then kill "$manual"; exit 1; fi
kill -0 "$manual"
kill -TERM "$manual"; wait "$manual" 2>/dev/null || true
# Generator topology and overwrite checks.
bash "$ROOT/tools/generate-node-configs" "$ROOT/config/cluster.json" "$tmp/generated" >/dev/null
source "$ROOT/lib/node-config.sh"
node_config "$tmp/generated/node01.env" | jq -e '.NET_ROUTES|fromjson|.["10.245.2.0/24"]=="172.29.240.12"' >/dev/null
node_config "$tmp/generated/node02.env" | jq -e '.NET_ROUTES|fromjson|.["10.245.1.0/24"]=="172.29.240.11"' >/dev/null
jq '.workers[1].subnet=.workers[0].subnet' "$ROOT/config/cluster.json" > "$tmp/bad.json"
if bash "$ROOT/tools/generate-node-configs" "$tmp/bad.json" "$tmp/bad" >/dev/null 2>&1; then exit 1; fi
printf '# user edit\n' >> "$tmp/generated/node01.env"
if bash "$ROOT/tools/generate-node-configs" "$ROOT/config/cluster.json" "$tmp/generated" >/dev/null 2>&1; then exit 1; fi
printf 'PASS: background lifecycle, repeated start, config snapshot, rollback, stale PID, unmanaged service, generated routes.\n'
