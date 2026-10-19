#!/bin/bash
set -euo pipefail

ETCD_DIR="${ETCD_DIR:-/var/lib/k8s-from-scratch/etcd}"
POD_STATE_DIR="${POD_STATE_DIR:-/var/lib/k8s-from-scratch/pods}"
NAMESPACE_DIR="${NAMESPACE_DIR:-/run/k8s-from-scratch}"
KUBELET_LOG="${KUBELET_LOG:-/var/log/kubelet.log}"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-5}"

export POD_STATE_DIR NAMESPACE_DIR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_SCRIPT="$SCRIPT_DIR/runtime.sh"

source "$SCRIPT_DIR/lib/etcd-client.sh"
source "$SCRIPT_DIR/lib/json.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/network.sh"

log() { printf '[kubelet] %s\n' "$*" | tee -a "$KUBELET_LOG"; }

# IPAM: subnet 10.244.0.0/24, .2-.254 allocatable.
IPAM_PREFIX="ipam/10.244.0.0-24"

ipam_allocate() {
    local name="$1" key ip existing
    # Reuse an existing reservation for this pod name.
    local all_keys
    all_keys=$(etcd_list "$IPAM_PREFIX") || all_keys=""
    if [[ -n "$all_keys" ]]; then
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            existing=$(etcd_get "$key") || continue
            if [[ "$existing" == "$name" ]]; then
                ip="${key##*/}"
                printf '%s' "$ip"
                return 0
            fi
        done <<< "$all_keys"
    fi
    # Allocate the lowest free address.
    local last_octet
    for ((last_octet=2; last_octet<=254; last_octet++)); do
        ip="10.244.0.$last_octet"
        if ! etcd_get "$IPAM_PREFIX/$ip" >/dev/null 2>&1; then
            etcd_put "$IPAM_PREFIX/$ip" "$name" || return 1
            printf '%s' "$ip"
            return 0
        fi
    done
    echo "ipam: address space exhausted (all 253 addresses allocated)." >&2
    return 1
}

ipam_free() {
    local name="$1" key existing
    local all_keys
    all_keys=$(etcd_list "$IPAM_PREFIX") || all_keys=""
    [[ -n "$all_keys" ]] || return 0
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        existing=$(etcd_get "$key") || continue
        if [[ "$existing" == "$name" ]]; then
            etcd_delete "$key" || return 1
            return 0
        fi
    done <<< "$all_keys"
}

launch_pod() {
    local name="$1" spec="$2" result command_file pod_ip
    local args=()
    command_file=$(mktemp) || return 1
    if ! json_get_container_command "$spec" > "$command_file"; then
        rm -f "$command_file"
        return 1
    fi
    mapfile -d '' -t args < "$command_file"
    rm -f "$command_file" || return 1

    pod_ip=$(ipam_allocate "$name") || {
        result=$(json_build_status unknown null null null "$POD_STATE_DIR/$name/log") || return 1
        etcd_put "pods/$name/status" "$result" || return 1
        return 1
    }

    result=$(json_build_status starting "$(date +%s)" null null "$POD_STATE_DIR/$name/log") || return 1
    etcd_put "pods/$name/status" "$result" || return 1

    if ! result=$("$RUNTIME_SCRIPT" start "$name" --ip "$pod_ip" -- "${args[@]}" 8>&-); then
        result=$(json_build_status unknown null null null "$POD_STATE_DIR/$name/log") || return 1
        etcd_put "pods/$name/status" "$result" || return 1
        return 1
    fi
    etcd_put "pods/$name/status" "$result" || return 1
    log "Pod '$name': $(json_get_field "$result" state), ip=$(json_get_field "$result" pod_ip)."
}

reconcile_pod() {
    local name="$1" spec actual status state result pod_ip
    validate_name "$name" || return 1
    spec=$(etcd_get "pods/$name/spec") || return 0
    if etcd_get "pods/$name/deleting" >/dev/null; then
        "$RUNTIME_SCRIPT" stop "$name" 8>&- || return 1
        ipam_free "$name" || return 1
        status=$(etcd_get "pods/$name/status") || status=""
        state=$(json_get_field "$status" state) || return 1
        if [[ "$state" != terminated ]]; then
            result=$(json_build_status terminated null "$(date +%s)" null null) || return 1
            etcd_put "pods/$name/status" "$result" || return 1
            log "Pod '$name' terminated."
        fi
        return 0
    fi
    if ! actual=$("$RUNTIME_SCRIPT" status "$name" 8>&-); then
        result=$(json_build_status unknown null null null "$POD_STATE_DIR/$name/log") || return 1
        etcd_put "pods/$name/status" "$result" || return 1
        return 1
    fi
    if [[ "$actual" == running ]]; then
        status=$(etcd_get "pods/$name/status") || status=""
        state=$(json_get_field "$status" state) || return 1
        if [[ "$state" != running ]]; then
            # Read actual IP from live netns rather than stale status.
            pod_ip=$(net_read_pod_ip "$NAMESPACE_DIR/$name/net") || pod_ip=""
            result=$(json_build_status running null null null "$POD_STATE_DIR/$name/log" "${pod_ip:-null}") || return 1
            etcd_put "pods/$name/status" "$result" || return 1
        fi
    elif [[ "$actual" == exited ]]; then
        launch_pod "$name" "$spec" || return 1
    else
        echo "Unexpected runtime state: $actual" >&2
        return 1
    fi
}

reconcile_once() {
    local names name
    names=$(etcd_pod_names) || return 1
    [[ -n "$names" ]] || return 0
    while IFS= read -r name; do
        if ! reconcile_pod "$name"; then
            log "Reconciliation failed for '$name'; will retry."
        fi
    done <<< "$names"
}

mkdir -p "$(dirname "$KUBELET_LOG")" "$ETCD_DIR"
# One reconciliation loop per fake-etcd directory. Do not pass this lock to runtime.
exec 8>"$ETCD_DIR/.kubelet.lock"
flock -n 8 || { echo 'A kubelet already uses this etcd directory.' >&2; exit 1; }
log "Starting. Reconcile interval: ${RECONCILE_INTERVAL}s"
while true; do
    if ! reconcile_once; then log 'Cannot list pods; will retry.'; fi
    sleep "$RECONCILE_INTERVAL"
done
