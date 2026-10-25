#!/bin/bash
# Requires an already running worker's ipamd, networkd and runtimed.
# Uses one uniquely named Pod, then removes its resources.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $# == 1 && "$1" != --configured ]]; then
    source "$ROOT/lib/node/config.sh"
    config=$(node_config "$1") || exit 1
    environment=(env)
    while IFS= read -r -d '' entry; do
        environment+=("$entry")
    done < <(jq -j 'to_entries[] | .key, "=", .value, "\u0000"' <<< "$config")
    exec "${environment[@]}" bash "$0" --configured
fi
[[ $# == 1 && "$1" == --configured ]] || {
    echo "Usage: $0 <worker-config.env>" >&2
    exit 1
}

IFS= read -r self_stat < /proc/self/stat
if [[ ${self_stat%% *} != "$$" ]]; then
    echo 'SKIP: /proc must match this PID namespace; run in the Ubuntu Node.'
    exit 77
fi
[[ $EUID == 0 ]] || { echo 'Run as root inside the privileged worker Node.' >&2; exit 1; }
source "$ROOT/lib/runtime/client.sh"
source "$ROOT/lib/network/client.sh"
source "$ROOT/lib/runtime/namespace.sh"
runtime_health >/dev/null
network_health >/dev/null

name="runtime-test-$$-$RANDOM"
cleanup() {
    runtime_stop "$name" >/dev/null 2>&1 || true
    network_release "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

config=$(network_reserve "$name")
ip=$(jq -er .ip <<< "$config")
prefix=$(jq -er .prefix <<< "$config")
gateway=$(jq -er .gateway <<< "$config")
runtime_start "$name" "$ip" "$prefix" "$gateway" -- /bin/sleep 120 | jq -e '.state == "running"' >/dev/null
[[ $(runtime_status "$name") == running ]]
[[ $(runtime_ip "$name") == "$ip" ]]
before=$(namespace_mount_identity "$NAMESPACE_DIR/$name/uts")
[[ -n "$before" ]]
runtime_start "$name" "$ip" "$prefix" "$gateway" -- /bin/sleep 120 >/dev/null
[[ $(namespace_mount_identity "$NAMESPACE_DIR/$name/uts") == "$before" ]]

if runtime_start "$name" "$ip" 16 "$gateway" -- /bin/sleep 120 >/dev/null 2>&1; then
    echo 'FAIL: invalid prefix accepted.' >&2
    exit 1
fi
[[ $(runtime_status "$name") == running ]]
runtime_stop "$name"
runtime_stop "$name"
[[ $(runtime_status "$name") == exited ]]
[[ ! -d "$POD_STATE_DIR/$name" ]]
[[ ! -d "$NAMESPACE_DIR/$name" ]]
# Explicit runtime stop leaves the IP reservation for kubelet/network_release.
config=$(network_reserve "$name")
[[ $(jq -r .ip <<< "$config") == "$ip" ]]
network_release "$name" >/dev/null
trap - EXIT
printf 'PASS: isolated Pod, observed IP, repeat start, invalid request, repeat stop, namespace/rootfs cleanup and reservation ownership.\n'
