#!/bin/bash
set -euo pipefail

ETCD_DIR="/var/lib/k8s-from-scratch/etcd"
POD_STATE_DIR="/var/lib/k8s-from-scratch/pods"
KUBELET_LOG="/var/log/kubelet.log"
RECONCILE_INTERVAL=5

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SCRIPT="${SCRIPT_DIR}/runtime.sh"

source "${SCRIPT_DIR}/lib/etcd-client.sh"
source "${SCRIPT_DIR}/lib/json.sh"
source "${SCRIPT_DIR}/lib/validate.sh"

mkdir -p "$(dirname "$KUBELET_LOG")"
log() { echo "[kubelet] $*" | tee -a "$KUBELET_LOG"; }

_launch() {
    local pod_name="$1"
    local spec_json="$2"

    local cmd_args=()
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && cmd_args+=("$arg")
    done <<< "$(json_get_container_command "$spec_json")"

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        log "Pod '$pod_name' has no command in spec, skipping."
        return 1
    fi

    local pod_log="${POD_STATE_DIR}/${pod_name}/log"

    etcd_put "pods/${pod_name}/status" \
        "$(json_build_status "starting" "$(date +%s)" null null "$pod_log")"

    local result_json
    result_json=$("$RUNTIME_SCRIPT" start "$pod_name" -- "${cmd_args[@]}")

    local state started_at
    state=$(json_get_field "$result_json" "state")
    started_at=$(json_get_field "$result_json" "started_at")

    if [[ "$state" == "running" ]]; then
        etcd_put "pods/${pod_name}/status" "$result_json"
        log "Pod '$pod_name' started."
    else
        local exit_code
        exit_code=$(json_get_field "$result_json" "exit_code")
        etcd_put "pods/${pod_name}/status" "$result_json"
        log "Pod '$pod_name' exited immediately (code ${exit_code})."
    fi
}

_delete_pod() {
    local pod_name="$1"
    "$RUNTIME_SCRIPT" stop "$pod_name"
    local exited_at
    exited_at=$(date +%s)
    etcd_put "pods/${pod_name}/status" \
        "$(json_build_status "terminated" null "$exited_at" null null)"
    log "Pod '$pod_name' terminated."
}

reconcile_once() {
    local keys
    keys=$(etcd_list "pods") || true
    [[ -z "$keys" ]] && return 0

    local names=()
    local key pod_name
    while IFS= read -r key; do
        [[ "$key" == */spec ]] || continue
        pod_name=$(echo "$key" | sed 's|^pods/||;s|/spec$||')
        names+=("$pod_name")
    done <<< "$keys"

    local spec_json actual_state
    for pod_name in "${names[@]:-}"; do
        [[ -z "$pod_name" ]] && continue

        # deletion branch: always checked first
        if etcd_get "pods/${pod_name}/deleting" >/dev/null 2>&1; then
            _delete_pod "$pod_name"
            continue
        fi

        spec_json=$(etcd_get "pods/${pod_name}/spec" 2>/dev/null) || continue

        actual_state=$("$RUNTIME_SCRIPT" status "$pod_name")

        if [[ "$actual_state" == "running" ]]; then
            local status_json etcd_state
            status_json=$(etcd_get "pods/${pod_name}/status" 2>/dev/null) || true
            etcd_state=$(json_get_field "$status_json" "state")
            if [[ "$etcd_state" != "running" ]]; then
                # Runtime says running but etcd disagrees -- correct it.
                local started_at pod_log
                started_at=$(json_get_field "$status_json" "started_at")
                pod_log="${POD_STATE_DIR}/${pod_name}/log"
                etcd_put "pods/${pod_name}/status" \
                    "$(json_build_status "running" "$started_at" null null "$pod_log")"
            fi
            continue
        fi

        # exited or never started: (re)launch
        log "Pod '$pod_name' is '$actual_state', launching."
        _launch "$pod_name" "$spec_json"
    done
}

log "Starting. Reconcile interval: ${RECONCILE_INTERVAL}s"
log "Press Ctrl+C to stop."

while true; do
    reconcile_once
    sleep "$RECONCILE_INTERVAL"
done
