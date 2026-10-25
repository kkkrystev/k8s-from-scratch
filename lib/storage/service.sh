# Validate and execute storage requests in the single-writer etcdd process.
# store_error/store_commit/store_load live in store.sh.
#
# Each action helper prints to stdout and returns a code the dispatcher reads:
#   0  -> stdout is the next state.json to commit
#   20 -> stdout is a final reply (error or read result); do not commit
#
# The check order below is the wire contract and must not be reordered:
# parse the request, validate its exact fields, load state, validate the key,
# resolve the Pod's current spec, then run the action, committing at most once.

STORE_REPLIED=20

# Exact fields and types are the wire contract; never evaluate client text.
store_validate_request() {
    jq -e '
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
    ' <<< "$1" > /dev/null
}

store_get() {
    local state="$1" key="$2"

    if ! jq -e --arg key "$key" '.keys | has($key)' <<< "$state" > /dev/null; then
        store_error not_found
        return "$STORE_REPLIED"
    fi

    jq -c --arg key "$key" '{ok: true, value: .keys[$key]}' <<< "$state" || return 1
    return "$STORE_REPLIED"
}

store_list() {
    local state="$1" prefix="$2"

    if [[ -n "$prefix" && ! "$prefix" =~ ^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$ ]]; then
        store_error invalid_key
        return "$STORE_REPLIED"
    fi

    jq -c --arg p "$prefix" '
        {
            ok: true,
            keys: [
                .keys | keys[]
                | select($p == "" or . == $p or startswith($p + "/"))
            ]
        }
    ' <<< "$state" || return 1
    return "$STORE_REPLIED"
}

# put and delete share guarding; they never touch Pod lifecycle keys.
store_put_delete() {
    local request="$1" state="$2" key="$3" action="$4" value

    if [[ "$key" == pods || "$key" == pods/* ]]; then
        store_error protected_key
        return "$STORE_REPLIED"
    fi

    if [[ "$action" == put ]]; then
        value=$(jq -r '.value' <<< "$request")
        jq -c --arg k "$key" --arg v "$value" '.keys[$k] = $v' <<< "$state"
    else
        jq -c --arg k "$key" 'del(.keys[$k])' <<< "$state"
    fi
}

store_create_pod() {
    local request="$1" state="$2" key="$3" current="$4" spec node uid

    if [[ -n "$current" ]]; then
        store_error already_exists
        return "$STORE_REPLIED"
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
        return "$STORE_REPLIED"
    }

    node=$(jq -r '.node_name' <<< "$spec")

    if [[ -n "$node" ]]; then
        validate_name "$node" 2> /dev/null || {
            store_error invalid_node
            return "$STORE_REPLIED"
        }
    fi

    uid=$(cat /proc/sys/kernel/random/uuid) || return 1

    spec=$(jq -c --arg uid "$uid" '. + {uid: $uid}' <<< "$spec") || return 1
    jq -c --arg k "$key" --arg v "$spec" '.keys[$k] = $v' <<< "$state"
}

store_assign_pod() {
    local state="$1" key="$2" name="$3" current="$4" node spec

    node=$(jq -r '.node_name' <<< "$REQUEST")

    validate_name "$node" 2> /dev/null || {
        store_error invalid_node
        return "$STORE_REPLIED"
    }

    # Assignment is a one-time decision for this Pod UID.
    if [[ $(jq -r '.node_name' <<< "$current") != "" ]]; then
        store_error conflict
        return "$STORE_REPLIED"
    fi

    if jq -e --arg d "pods/$name/deleting" '.keys | has($d)' <<< "$state" > /dev/null; then
        store_error conflict
        return "$STORE_REPLIED"
    fi

    spec=$(jq -c --arg node "$node" '.node_name = $node' <<< "$current") || return 1
    jq -c --arg k "$key" --arg v "$spec" '.keys[$k] = $v' <<< "$state"
}

store_mark_pod() {
    local state="$1" name="$2" current="$3" next value

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

        next=$(jq -c --arg k "pods/$name/status" --arg v "$value" '.keys[$k] = $v' <<< "$next") || return 1
    fi

    printf '%s\n' "$next"
}

store_status_pod() {
    local state="$1" name="$2" value

    value=$(jq -r '.value' <<< "$REQUEST")

    jq -e '
        type == "object"
        and (.state | IN("starting", "running", "unknown", "terminated", "exited"))
    ' <<< "$value" > /dev/null || {
        store_error invalid_status
        return "$STORE_REPLIED"
    }

    # Once terminated, delayed observers may not resurrect status.
    if jq -e --arg k "pods/$name/status" '
        (.keys[$k] // "{}" | fromjson).state == "terminated"
    ' <<< "$state" > /dev/null; then
        store_error conflict
        return "$STORE_REPLIED"
    fi

    jq -c --arg k "pods/$name/status" --arg v "$value" '.keys[$k] = $v' <<< "$state"
}

store_finish_pod() {
    local state="$1" name="$2"

    if ! jq -e --arg d "pods/$name/deleting" --arg s "pods/$name/status" '
        .keys[$d] == "1"
        and ((.keys[$s] // "{}" | fromjson).state == "terminated")
    ' <<< "$state" > /dev/null; then
        store_error not_terminated
        return "$STORE_REPLIED"
    fi

    jq -c --arg p "pods/$name/" '
        .keys |= with_entries(select(.key | startswith($p) | not))
    ' <<< "$state"
}

# Shared preamble for the four Pod actions: the current spec must exist and,
# except for mark_pod, its UID must match the request.
store_pod_guard() {
    local action="$1" current="$2" uid

    if [[ -z "$current" ]]; then
        store_error not_found
        return "$STORE_REPLIED"
    fi

    uid=$(jq -er '.uid' <<< "$current") || {
        store_error invalid_state
        return "$STORE_REPLIED"
    }

    if [[ "$action" != mark_pod && "$uid" != "$(jq -r '.uid' <<< "$REQUEST")" ]]; then
        store_error conflict
        return "$STORE_REPLIED"
    fi
}

store_dispatch() {
    local request action key value prefix name current next state node
    local rc=0

    request=$(jq -cse '
        select(length == 1)
        | .[0]
        | select(type == "object")
    ' <<< "$1") || {
        store_error invalid_request
        return
    }

    action=$(jq -r '.action // empty' <<< "$request")

    if ! store_validate_request "$request"; then
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

    # Bash dynamic scope exposes the request only while dispatching this call.
    local REQUEST="$request"

    case "$action" in
        health)
            printf '{"ok":true}\n'
            return
            ;;

        get)
            store_get "$state" "$key" || rc=$?
            if ((rc != STORE_REPLIED)); then
                store_error storage_error
            fi
            return 0
            ;;

        list)
            store_list "$state" "$prefix" || rc=$?
            if ((rc != STORE_REPLIED)); then
                store_error storage_error
            fi
            return 0
            ;;

        put | delete)
            next=$(store_put_delete "$request" "$state" "$key" "$action") || rc=$?
            ;;

        create_pod)
            next=$(store_create_pod "$request" "$state" "$key" "$current") || rc=$?
            ;;

        assign_pod | mark_pod | status_pod | finish_pod)
            store_pod_guard "$action" "$current" || rc=$?

            if ((rc == STORE_REPLIED)); then
                return
            fi

            if ((rc != 0)); then
                store_error storage_error
                return
            fi

            case "$action" in
                assign_pod)
                    next=$(store_assign_pod "$state" "$key" "$name" "$current") || rc=$?
                    ;;
                mark_pod)
                    next=$(store_mark_pod "$state" "$name" "$current") || rc=$?
                    ;;
                status_pod)
                    next=$(store_status_pod "$state" "$name") || rc=$?
                    ;;
                finish_pod)
                    next=$(store_finish_pod "$state" "$name") || rc=$?
                    ;;
            esac
            ;;
    esac

    # A helper that already produced a final reply short-circuits the commit.
    if ((rc == STORE_REPLIED)); then
        printf '%s\n' "$next"
        return
    fi

    if ((rc != 0)); then
        store_error storage_error
        return
    fi

    store_commit "$next" || {
        store_error storage_error
        return
    }

    # Helpers run in command substitutions; derive the UID from their result.
    if [[ "$action" == create_pod ]]; then
        value=$(jq -er --arg key "$key" '.keys[$key] | fromjson | .uid' <<< "$next") || return 1
    elif [[ "$action" == *_pod ]]; then
        value=$(jq -er .uid <<< "$current") || return 1
    else
        value=''
    fi

    jq -cn --arg uid "$value" '{ok: true, uid: $uid}'
}
