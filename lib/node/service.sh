# Service selection, environment, health, preflight, start and stop.
# node_identity/node_alive/node_record_pid/node_pid live in process.sh.

node_services() {
    SERVICES=()

    if [[ $(jq -r '.env.RUN_ETCD' <<< "$SNAPSHOT") == true ]]; then
        SERVICES+=(etcdd)
    fi

    if [[ $(jq -r '.env.RUN_WORKER' <<< "$SNAPSHOT") == true ]]; then
        SERVICES+=(ipamd networkd runtimed kubelet)
    fi

    if [[ $(jq -r '.env.RUN_SCHEDULER' <<< "$SNAPSHOT") == true ]]; then
        SERVICES+=(scheduler)
    fi
}

node_environment() {
    local entry

    ENV_ARGS=(env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C)

    while IFS= read -r -d '' entry; do
        ENV_ARGS+=("$entry")
    done < <(
        jq -j '.env | to_entries[] | .key, "=", .value, "\u0000"' <<< "$SNAPSHOT")
}

node_health() {
    local service="$1" project expr

    project=$(jq -r '.project' <<< "$SNAPSHOT")
    node_environment

    case "$service" in
        ipamd)
            expr='source "$1/lib/ipam/client.sh"; ipam_health'
            ;;
        networkd)
            expr='source "$1/lib/network/client.sh"; network_health'
            ;;
        runtimed)
            expr='source "$1/lib/runtime/client.sh"; runtime_health'
            ;;
        etcdd)
            # Test this local daemon, not some other server at ETCD_ENDPOINT.
            ENV_ARGS+=("ETCD_ENDPOINT=127.0.0.1:$(jq -r '.env.ETCD_PORT' <<< "$SNAPSHOT")")

            if [[ $(jq -r '.env.ETCD_BIND' <<< "$SNAPSHOT") != 0.0.0.0 ]]; then
                ENV_ARGS+=("ETCD_ENDPOINT=$(jq -r '.env.ETCD_BIND + ":" + .env.ETCD_PORT' <<< "$SNAPSHOT")")
            fi

            expr='source "$1/lib/storage/client.sh"; etcd_health'
            ;;
        kubelet | scheduler)
            node_alive "$service"
            return
            ;;
    esac

    "${ENV_ARGS[@]}" bash -c "$expr" _ "$project" >/dev/null 2>&1
}

node_wait_ready() {
    local service="$1" deadline=$((SECONDS + 20))
    local lock="/run/k8s-from-scratch/$service.lock"

    # These reconcilers have no health RPC; check ownership and their lifetime lock.
    while ((SECONDS < deadline)); do
        node_alive "$service" || return 1

        if [[ "$service" == kubelet || "$service" == scheduler ]]; then
            if [[ -f "$lock" ]] &&
                ! flock -n "$lock" true; then
                sleep 0.3
                node_alive "$service" && return 0
            fi
        elif node_health "$service" && node_alive "$service"; then
            return 0
        fi

        sleep 0.2
    done

    return 1
}

node_service_locks_free() {
    local service="$1"
    local locks path

    case "$service" in
        runtimed)
            locks=$(jq -er '["/run/k8s-from-scratch/runtimed.lock", ((.env.RUNTIME_SOCKET // "/run/k8s-from-scratch/runtime.sock") + ".lock")] | .[]' <<< "$SNAPSHOT") || return 1
            ;;
        scheduler)
            locks=/run/k8s-from-scratch/scheduler.lock
            ;;
        kubelet)
            locks=/run/k8s-from-scratch/kubelet.lock
            ;;
        ipamd)
            locks=$(jq -er '[
                (.env.IPAM_STATE + ".lock"),
                (.env.IPAM_SOCKET + ".lock")
            ] | .[]' <<< "$SNAPSHOT") || return 1
            ;;
        networkd)
            locks=$(jq -er '[
                "/run/k8s-from-scratch-network.lock",
                (.env.NETWORK_SOCKET + ".lock")
            ] | .[]' <<< "$SNAPSHOT") || return 1
            ;;
        etcdd)
            locks=$(jq -er '.env.ETCD_DIR + "/server.lock"' <<< "$SNAPSHOT") || return 1
            ;;
        *)
            return 1
            ;;
    esac

    while IFS= read -r path; do
        node_lock_free "$path" || return 1
    done <<< "$locks"
}

node_stop_service() {
    local service="$1"
    local pid='' deadline stop_timeout=20

    if [[ "$service" == runtimed ]]; then
        stop_timeout=$(( $(jq -r '.env.RUNTIME_TIMEOUT // "60"' <<< "$SNAPSHOT") + 20 ))
    fi

    if node_alive "$service"; then
        pid=$(node_pid "$service") || return 1

        # Recheck ownership immediately before signalling.
        if node_alive "$service"; then
            if ! kill -TERM "$pid"; then
                if node_alive "$service"; then
                    return 1
                fi
            fi
        fi
    fi

    deadline=$((SECONDS + stop_timeout))

    while node_alive "$service" || ! node_service_locks_free "$service"; do
        if ((SECONDS >= deadline)); then
            echo "$service: stop timed out; process or service locks still active. Record retained." >&2
            return 1
        fi

        sleep 0.2
    done

    if [[ -n "$pid" ]]; then
        wait "$pid" 2>/dev/null || true
    fi

    rm -f -- "$STATE/$service.pid"
    printf '%s: stopped\n' "$service"
}

node_unmanaged() {
    local proc pid script service record managed index
    local args=()

    for proc in /proc/[0-9]*/cmdline; do
        pid=${proc#/proc/}
        pid=${pid%/cmdline}
        [[ "$pid" != "$$" && -r "$proc" ]] || continue

        args=()
        mapfile -d '' -t args < "$proc" 2>/dev/null || continue
        [[ ${#args[@]} -ge 2 && ${args[0]##*/} == bash ]] || continue

        index=1
        while [[ ${args[index]:-} == -* && ${args[index]} != -- ]]; do
            [[ ${args[index]} != *c* ]] || break
            index=$((index + 1))
        done
        [[ ${args[index]:-} != -- ]] || index=$((index + 1))

        script=${args[index]:-}
        script=${script##*/}

        # Ignore handlers; daemon lifetime/locks handle them.
        [[ ${args[index + 1]:-} != --handle ]] || continue

        if [[ "$script" == runtimed && ${args[index + 1]:-} == --listen ]]; then
            continue
        fi

        case "$script" in
            ipamd | networkd | runtimed | kubelet | etcdd | scheduler)
                service="$script"
                ;;
            *)
                continue
                ;;
        esac

        managed=0
        if node_alive "$service"; then
            [[ $(node_pid "$service") != "$pid" ]] || managed=1
        fi

        if ((managed == 0)); then
            echo "Unmanaged $service (PID $pid). Stop it normally before node start." >&2
            return 1
        fi
    done
}

node_lock_free() {
    local path="$1"

    [[ ! -e "$path" ]] || flock -n "$path" true
}

node_preflight() {
    local project path service

    project=$(jq -r '.project' <<< "$SNAPSHOT")
    node_unmanaged || return 1

    for service in "${SERVICES[@]}"; do
        if [[ ! -f "$project/daemons/$service" ]]; then
            echo "Missing entrypoint: $project/daemons/$service" >&2
            return 1
        fi

        node_alive "$service" && continue

        case "$service" in
            ipamd)
                path=$(jq -r '.env.IPAM_STATE + ".lock"' <<< "$SNAPSHOT")
                node_lock_free "$path" || return 1
                path=$(jq -r '.env.IPAM_SOCKET + ".lock"' <<< "$SNAPSHOT")
                ;;
            networkd)
                node_lock_free /run/k8s-from-scratch-network.lock || return 1
                path=$(jq -r '.env.NETWORK_SOCKET + ".lock"' <<< "$SNAPSHOT")
                ;;
            runtimed)
                node_lock_free /run/k8s-from-scratch/runtimed.lock || return 1
                path=$(jq -r '.env.RUNTIME_SOCKET + ".lock"' <<< "$SNAPSHOT")
                ;;
            scheduler)
                path=/run/k8s-from-scratch/scheduler.lock
                ;;
            kubelet)
                path=/run/k8s-from-scratch/kubelet.lock
                ;;
            etcdd)
                path=$(jq -r '.env.ETCD_DIR + "/server.lock"' <<< "$SNAPSHOT")
                ;;
        esac

        if ! node_lock_free "$path"; then
            echo "Service lock is busy: $path" >&2
            return 1
        fi
    done

    if [[ $(jq -r '.env.RUN_WORKER' <<< "$SNAPSHOT") == true ]]; then
        node_environment
        "${ENV_ARGS[@]}" bash -c 'source "$1/lib/validate.sh"; validate_rootfs' _ "$project" || return 1

        # Detect a node01 config accidentally used in node02 before changing anything.
        ip -j -4 addr show | jq -e --arg ip "$(jq -r '.env.NODE_IP' <<< "$SNAPSHOT")" \
            'any(.[].addr_info[]?; .local==$ip)' >/dev/null || {
            echo 'Configured NODE_IP does not belong to this Node.' >&2
            return 1
        }
    fi

    if [[ $(jq -r '.env.RUN_ETCD' <<< "$SNAPSHOT") != true ]] &&
        [[ $(jq -r '.env.RUN_WORKER == "true" or .env.RUN_SCHEDULER == "true"' <<< "$SNAPSHOT") == true ]]; then
        node_environment
        "${ENV_ARGS[@]}" bash -c '
            source "$1/lib/storage/client.sh"
            etcd_health
        ' _ "$project" > /dev/null || return 1
    fi
}

node_launch() {
    local service="$1" project logdir pid identity

    project=$(jq -r '.project' <<< "$SNAPSHOT")
    logdir=$(jq -r '.env.LOG_DIR' <<< "$SNAPSHOT")
    mkdir -p -- "$logdir"
    node_environment

    # Verify the worker endpoint after any local etcdd has become ready.
    if [[ "$service" == kubelet || "$service" == scheduler ]]; then
        "${ENV_ARGS[@]}" bash -c '
            source "$1/lib/storage/client.sh"
            etcd_health
        ' _ "$project" > /dev/null || {
            echo "Storage endpoint unavailable; $service was not started." >&2
            return 1
        }
    fi

    if [[ "$service" == kubelet ]]; then
        "${ENV_ARGS[@]}" bash -c '
            source "$1/lib/runtime/client.sh"
            runtime_health
        ' _ "$project" >/dev/null || return 1
    fi

    local command=(bash "$project/daemons/$service")

    case "$service" in
        ipamd)
            command+=("$(jq -r '.env.IPAM_SOCKET' <<< "$SNAPSHOT")")
            ;;
        networkd)
            command+=("$(jq -r '.env.NETWORK_SOCKET' <<< "$SNAPSHOT")")
            ;;
    esac

    # No manager lock/stdin/terminal descriptors may outlive the command.
    # Gate execution until ownership is recorded, including after manager SIGKILL.
    nohup "${ENV_ARGS[@]}" bash -c '
        gate=$1
        shift

        for ((i = 0; i < 100; i++)); do
            if [[ -f "$gate" ]]; then
                exec "$@"
            fi
            sleep 0.05
        done
        exit 1
    ' _ "$STATE/$service.go" "${command[@]}" \
        200>&- </dev/null >> "$logdir/$service.log" 2>&1 &
    pid=$!

    if ! node_record_pid "$service" "$pid"; then
        echo "Could not record $service; startup gate will expire." >&2
        return 1
    fi

    STARTED+=("$service")
    : > "$STATE/$service.go" || return 1

    if ! node_wait_ready "$service"; then
        echo "$service failed startup; inspect $logdir/$service.log" >&2
        return 1
    fi

    printf '%s: started (PID %s)\n' "$service" "$pid"
}
