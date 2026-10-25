# .env is data: KEY=value, no shell expansion, quoting, eval or source.
node_config() {
    local file="$1"
    local line key value
    local config='{}'

    if [[ ! -f "$file" ]]; then
        echo "Config not found: $file" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" != *=* || "$line" == *$'\r'* ]]; then
            echo 'Expected KEY=value, LF line endings.' >&2
            return 1
        fi

        key=${line%%=*}
        value=${line#*=}

        case "$key" in
            RUN_ETCD | RUN_WORKER | RUN_SCHEDULER | SCHEDULER_NODES | SCHEDULER_INTERVAL | NODE_NAME | NODE_IP | \
            POD_SUBNET | NET_BRIDGE | NET_ROUTES | \
            ETCD_ENDPOINT | ETCD_BIND | ETCD_PORT | ETCD_DIR | \
            IPAM_SOCKET | NETWORK_SOCKET | RUNTIME_SOCKET | RUNTIME_TIMEOUT | IPAM_STATE | \
            NAMESPACE_DIR | POD_STATE_DIR | ROOTFS | LOG_DIR | \
            RECONCILE_INTERVAL)
                ;;
            *)
                echo "Unknown setting: $key" >&2
                return 1
                ;;
        esac

        if jq -e --arg k "$key" 'has($k)' <<< "$config" > /dev/null; then
            echo "Duplicate setting: $key" >&2
            return 1
        fi

        config=$(jq -c \
            --arg k "$key" \
            --arg v "$value" \
            '.[$k] = $v' <<< "$config") || return 1
    done < "$file"

    config=$(jq -c '
        {
            RUN_ETCD: "false",
            RUN_WORKER: "false",
            RUN_SCHEDULER: "false",
            SCHEDULER_NODES: "[]",
            SCHEDULER_INTERVAL: "2",
            NET_BRIDGE: "kfs0",
            NET_ROUTES: "{}",
            IPAM_SOCKET: "/run/k8s-from-scratch/ipam.sock",
            RUNTIME_SOCKET: "/run/k8s-from-scratch/runtime.sock",
            RUNTIME_TIMEOUT: "60",
            NETWORK_SOCKET: "/run/k8s-from-scratch/network.sock",
            IPAM_STATE: "/var/lib/k8s-from-scratch/ipam/state.json",
            NAMESPACE_DIR: "/run/k8s-from-scratch",
            POD_STATE_DIR: "/var/lib/k8s-from-scratch/pods",
            ROOTFS: "/var/lib/k8s-from-scratch/rootfs",
            LOG_DIR: "/var/log/kfs",
            RECONCILE_INTERVAL: "5",
            ETCD_BIND: "127.0.0.1",
            ETCD_PORT: "2379",
            ETCD_DIR: "/var/lib/k8s-from-scratch/etcd-server"
        } + .
        |
        if .RUN_WORKER == "true" then
            . + {
                IPAM_SUBNET: .POD_SUBNET,
                NET_SUBNET: .POD_SUBNET,
                NETNS_DIR: .NAMESPACE_DIR
            }
        else
            .
        end
        |
        . + {
            KUBELET_LOG: (.LOG_DIR + "/kubelet.log")
        }
    ' <<< "$config") || return 1

    jq -e '
        def name:
            type == "string"
            and length <= 63
            and test("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$");

        def ip:
            type == "string"
            and (
                split(".") as $p
                | ($p | length) == 4
                and all($p[];
                    test("^(0|[1-9][0-9]{0,2})$")
                    and tonumber <= 255
                )
            );

        def subnet:
            type == "string"
            and endswith(".0/24")
            and (split("/")[0] | ip);

        def path:
            type == "string"
            and startswith("/")
            and . != "/"
            and test("^/[a-zA-Z0-9_./-]+$")
            and (split("/") | all(.[]; . != ".." and . != "."));

        (.RUN_ETCD | IN("true", "false"))
        and (.RUN_WORKER | IN("true", "false"))
        and (.RUN_SCHEDULER | IN("true", "false"))
        and (.SCHEDULER_INTERVAL | test("^[1-9][0-9]*$"))
        and (.RUN_ETCD == "true" or .RUN_WORKER == "true" or .RUN_SCHEDULER == "true")
        and (
            .RUN_SCHEDULER as $enabled
            | .SCHEDULER_NODES | fromjson
            | type == "array"
            and all(.[]; name)
            and (length == (unique | length))
            and (if $enabled == "true" then length > 0 else true end)
        )
        and (.NODE_NAME | name)

        and (
            .ETCD_ENDPOINT
            | type == "string"
            and test("^[a-zA-Z0-9][a-zA-Z0-9.-]*:[1-9][0-9]{0,4}$")
            and (split(":")[-1] | tonumber <= 65535)
        )

        and (
            [
                .LOG_DIR,
                .ETCD_DIR,
                .IPAM_STATE,
                .NAMESPACE_DIR,
                .POD_STATE_DIR,
                .ROOTFS,
                .IPAM_SOCKET,
                .NETWORK_SOCKET,
                .RUNTIME_SOCKET
            ]
            | all(.[]; path)
        )

        and (.ETCD_BIND | ip)
        and (
            .ETCD_PORT
            | test("^[1-9][0-9]{0,4}$")
            and tonumber <= 65535
        )
        and (.RECONCILE_INTERVAL | test("^[1-9][0-9]*$"))

        and (.IPAM_SOCKET | length < 100)
        and (.NETWORK_SOCKET | length < 100)
        and (.IPAM_SOCKET != .NETWORK_SOCKET)
        and (.RUNTIME_SOCKET | length < 100)
        and (.RUNTIME_TIMEOUT | test("^[1-9][0-9]*$"))
        and (.RUNTIME_SOCKET != .IPAM_SOCKET and .RUNTIME_SOCKET != .NETWORK_SOCKET)

        and (
            if .RUN_WORKER == "true" then
                (.NODE_IP | ip)
                and (.POD_SUBNET | subnet)
                and (.NET_BRIDGE | test("^[a-zA-Z][a-zA-Z0-9_-]{0,14}$"))
                and (
                    .POD_SUBNET as $s
                    | .NET_ROUTES
                    | fromjson
                    | type == "object"
                    and all(to_entries[];
                        (.key | subnet)
                        and .key != $s
                        and (.value | ip)
                    )
                )
            else
                true
            end
        )
    ' <<< "$config" > /dev/null || {
        echo "Invalid Node configuration: $file" >&2
        return 1
    }

    jq -cS '.NET_ROUTES |= (fromjson | tojson) | .SCHEDULER_NODES |= (fromjson | tojson)' <<< "$config"
}
