# Single-writer store. Only etcdd owns ETCD_DIR; every mutation replaces state.json.
store_error() {
    jq -cn --arg error "$1" '{ok: false, error: $error}'
}

store_commit() {
    local tmp

    tmp=$(mktemp "$ETCD_DIR/state.XXXXXX") || return 1

    if ! printf '%s\n' "$1" > "$tmp" || ! mv -f -- "$tmp" "$ETCD_DIR/state.json"; then
        rm -f -- "$tmp"
        return 1
    fi
}

store_load() {
    jq -cse '
        select(length == 1)
        | .[0]
        | select(
            type == "object"
            and (.keys | type == "object" and all(.[]; type == "string"))
        )
    ' "$ETCD_DIR/state.json"
}

store_dispatch() {
    local request action key value prefix name spec uid current next state node

    request=$(jq -cse '
        select(length == 1)
        | .[0]
        | select(type == "object")
    ' <<< "$1") || {
        store_error invalid_request
        return
    }

    action=$(jq -r '.action // empty' <<< "$request")

    # Exact fields and types are the wire contract; never evaluate client text.
    if ! jq -e '
        def fields($f):
            keys == ($f | sort);

        def str($k):
            .[$k] | type == "string" and (contains("\u0000") | not);

        if .action == "health" then
            fields(["action"])
        elif .action == "get" or .action == "delete" then
            fields(["action", "key"]) and str("key")
        elif .action == "put" then
            fields(["action", "key", "value"]) and str("key") and str("value")
        elif .action == "list" then
            fields(["action", "prefix"]) and str("prefix")
        elif .action == "create_pod" then
            fields(["action", "spec"]) and (.spec | type == "object")
        elif .action == "assign_pod" then
            fields(["action", "name", "uid", "node_name"])
            and str("name") and str("uid") and str("node_name")
        elif .action == "mark_pod" then
            fields(["action", "name"]) and str("name")
        elif .action == "finish_pod" then
            fields(["action", "name", "uid"]) and str("name") and str("uid")
        elif .action == "status_pod" then
            fields(["action", "name", "uid", "value"])
            and str("name") and str("uid") and str("value")
        else
            false
        end
    ' <<< "$request" > /dev/null; then
        store_error invalid_request
        return
    fi

    state=$(store_load) || {
        store_error invalid_state
        return
    }

    key=$(jq -r '.key // empty' <<< "$request")
    prefix=$(jq -r '.prefix // empty' <<< "$request")
    name=$(jq -r '.name // .spec.name // empty' <<< "$request")

    if [[ -n "$key" || "$action" == get || "$action" == put || "$action" == delete ]]; then
        if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$ ]]; then
            store_error invalid_key
            return
        fi
    fi

    if [[ "$action" == *_pod ]]; then
        validate_name "$name" 2> /dev/null || {
            store_error invalid_name
            return
        }

        key="pods/$name/spec"
        current=$(jq -r --arg key "$key" '.keys[$key] // empty' <<< "$state")
    fi

    case "$action" in
        health)
            printf '{"ok":true}\n'
            return
            ;;

        get)
            if ! jq -e --arg key "$key" '.keys | has($key)' <<< "$state" > /dev/null; then
                store_error not_found
                return
            fi

            jq -c --arg key "$key" '{ok: true, value: .keys[$key]}' <<< "$state"
            return
            ;;

        list)
            if [[ -n "$prefix" && ! "$prefix" =~ ^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$ ]]; then
                store_error invalid_key
                return
            fi

            jq -c --arg p "$prefix" '
                {
                    ok: true,
                    keys: [
                        .keys | keys[]
                        | select($p == "" or . == $p or startswith($p + "/"))
                    ]
                }
            ' <<< "$state"
            return
            ;;

        put | delete)
            # Pod lifecycle must go through guarded operations below.
            if [[ "$key" == pods || "$key" == pods/* ]]; then
                store_error protected_key
                return
            fi

            if [[ "$action" == put ]]; then
                value=$(jq -r '.value' <<< "$request")
                next=$(jq -c --arg k "$key" --arg v "$value" '.keys[$k] = $v' <<< "$state") || return 1
            else
                next=$(jq -c --arg k "$key" 'del(.keys[$k])' <<< "$state") || return 1
            fi
            ;;

        create_pod)
            if [[ -n "$current" ]]; then
                store_error already_exists
                return
            fi

            # An omitted node_name is normalized to an empty string.
            # Explicit null, invalid types and unknown fields are rejected.
            spec=$(jq -ce '
                .spec
                | select(
                    (keys == ["containers", "name"]
                     or keys == ["containers", "name", "node_name"])
                    and (if has("node_name") then (.node_name | type == "string") else true end)
                    and (.containers | type == "array" and length == 1)
                    and (.containers[0] | keys == ["command", "name"])
                    and (.containers[0].name == .name)
                    and (
                        .containers[0].command
                        | type == "array" and length > 0
                        and all(.[];
                            type == "string" and (contains("\u0000") | not)
                        )
                    )
                )
                | . + {node_name: (.node_name // "")}
            ' <<< "$request") || {
                store_error invalid_spec
                return
            }

            node=$(jq -r '.node_name' <<< "$spec")

            if [[ -n "$node" ]]; then
                validate_name "$node" 2> /dev/null || {
                    store_error invalid_node
                    return
                }
            fi

            uid=$(cat /proc/sys/kernel/random/uuid) || return 1
            spec=$(jq -c --arg uid "$uid" '. + {uid: $uid}' <<< "$spec") || return 1
            next=$(jq -c --arg k "$key" --arg v "$spec" '.keys[$k] = $v' <<< "$state") || return 1
            ;;

        assign_pod | mark_pod | status_pod | finish_pod)
            if [[ -z "$current" ]]; then
                store_error not_found
                return
            fi

            uid=$(jq -er '.uid' <<< "$current") || {
                store_error invalid_state
                return
            }

            if [[ "$action" != mark_pod && "$uid" != "$(jq -r '.uid' <<< "$request")" ]]; then
                store_error conflict
                return
            fi

            case "$action" in
                assign_pod)
                    node=$(jq -r '.node_name' <<< "$request")

                    validate_name "$node" 2> /dev/null || {
                        store_error invalid_node
                        return
                    }

                    # Assignment is a one-time decision for this Pod UID.
                    if [[ $(jq -r '.node_name' <<< "$current") != "" ]]; then
                        store_error conflict
                        return
                    fi

                    if jq -e --arg d "pods/$name/deleting" '
                        .keys | has($d)
                    ' <<< "$state" > /dev/null; then
                        store_error conflict
                        return
                    fi

                    spec=$(jq -c --arg node "$node" '
                        .node_name = $node
                    ' <<< "$current") || return 1

                    next=$(jq -c --arg k "$key" --arg v "$spec" '
                        .keys[$k] = $v
                    ' <<< "$state") || return 1
                    ;;

                mark_pod)
                    next=$(jq -c --arg k "pods/$name/deleting" '.keys[$k] = "1"' <<< "$state") || return 1

                    # No kubelet owns an unassigned Pod, so no runtime cleanup is needed.
                    # Mark and acknowledge deletion in the same store commit.
                    if [[ $(jq -r '.node_name // ""' <<< "$current") == "" ]]; then
                        value=$(jq -cn --argjson now "$(date +%s)" '
                            {
                                state: "terminated",
                                started_at: null,
                                exited_at: $now,
                                exit_code: null,
                                log: null,
                                pod_ip: null
                            }
                        ') || return 1

                        next=$(jq -c --arg k "pods/$name/status" --arg v "$value" '
                            .keys[$k] = $v
                        ' <<< "$next") || return 1
                    fi
                    ;;

                status_pod)
                    value=$(jq -r '.value' <<< "$request")

                    jq -e '
                        type == "object"
                        and (.state | IN("starting", "running", "unknown", "terminated", "exited"))
                    ' <<< "$value" > /dev/null || {
                        store_error invalid_status
                        return
                    }

                    # Once terminated, delayed observers may not resurrect status.
                    if jq -e --arg k "pods/$name/status" '
                        (.keys[$k] // "{}" | fromjson).state == "terminated"
                    ' <<< "$state" > /dev/null; then
                        store_error conflict
                        return
                    fi

                    next=$(jq -c --arg k "pods/$name/status" --arg v "$value" '.keys[$k] = $v' <<< "$state") || return 1
                    ;;

                finish_pod)
                    if ! jq -e --arg d "pods/$name/deleting" --arg s "pods/$name/status" '
                        .keys[$d] == "1"
                        and ((.keys[$s] // "{}" | fromjson).state == "terminated")
                    ' <<< "$state" > /dev/null; then
                        store_error not_terminated
                        return
                    fi

                    next=$(jq -c --arg p "pods/$name/" '
                        .keys |= with_entries(select(.key | startswith($p) | not))
                    ' <<< "$state") || return 1
                    ;;
            esac
            ;;
    esac

    store_commit "$next" || {
        store_error storage_error
        return
    }

    jq -cn --arg uid "${uid:-}" '{ok: true, uid: $uid}'
}
