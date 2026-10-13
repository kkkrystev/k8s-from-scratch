#!/bin/bash
set -euo pipefail

ETCD_DIR="/var/lib/k8s-from-scratch/etcd"
CONTAINER_STATE_DIR="/var/lib/k8s-from-scratch/containers"
RECONCILE_INTERVAL=5

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_SCRIPT="${SCRIPT_DIR}/container.sh"

source "${SCRIPT_DIR}/lib/etcd-client.sh"
source "${SCRIPT_DIR}/lib/json.sh"
source "${SCRIPT_DIR}/lib/meta.sh"
source "${SCRIPT_DIR}/lib/validate.sh"

reconcile_once() {
    local keys
    keys=$(etcd_list "pods") || true
    [[ -z "$keys" ]] && return 0

    # Collect unique pod names.
    local names=()
    local key name
    while IFS= read -r key; do
        # Only act on spec keys — each pod should have one.
        [[ "$key" == */spec ]] || continue
        name=$(echo "$key" | sed 's|^containers/||;s|/spec$||')
        names+=("$name")
    done <<< "$keys"

    local spec_json status_json state cdir
    for name in "${names[@]:-}"; do
        [[ -z "$name" ]] && continue

        spec_json=$(etcd_get "containers/${name}/spec" 2>/dev/null) || continue

        status_json=$(etcd_get "containers/${name}/status" 2>/dev/null) || status_json=""

        if [[ -n "$status_json" ]]; then
            state=$(json_get_field "$status_json" "state")
        else
            state="unknown"
        fi

        # For running pods, verify the process is actually alive.
        if [[ "$state" == "running" ]]; then
            cdir="${CONTAINER_STATE_DIR}/${name}"
            if [[ -d "$cdir" ]]; then
                state=$(resolve_state "$cdir")
            else
                state="unknown"
            fi
        fi

        # Desired state: running (spec exists). If not running, create it.
        if [[ "$state" == "unknown" || "$state" == "exited" || "$state" == "starting" ]]; then
            echo "[kubelet] Pod '$name' is '$state' — starting container."
            local cmd_json cmd_args=()
            cmd_json=$(json_get_command "$spec_json")
            while IFS= read -r arg; do
                [[ -n "$arg" ]] && cmd_args+=("$arg")
            done <<< "$cmd_json"

            if [[ ${#cmd_args[@]} -eq 0 ]]; then
                echo "[kubelet] Pod '$name' has no command in spec — skipping." >&2
                continue
            fi

            "$CONTAINER_SCRIPT" create -d "$name" "${cmd_args[@]}" || \
                echo "[kubelet] Failed to start '$name'." >&2
        fi
    done
}

echo "[kubelet] Starting. Reconcile interval: ${RECONCILE_INTERVAL}s"
echo "[kubelet] Press Ctrl+C to stop."

while true; do
    reconcile_once
    sleep "$RECONCILE_INTERVAL"
done
