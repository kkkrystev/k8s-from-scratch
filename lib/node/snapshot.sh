# The saved Node configuration ("snapshot") records which services this Node
# manages, their environment and the project root. It lives at
# $STATE/config.json and is the source of truth for status and stop.

# Load the saved snapshot into SNAPSHOT, or leave it empty when none exists.
node_snapshot_load() {
    SNAPSHOT=''

    if [[ -f "$STATE/config.json" ]]; then
        SNAPSHOT=$(jq -ce 'select(.env|type=="object")' "$STATE/config.json") || return 1
    fi
}

# Build the snapshot that a start with this config and project root would save.
# The project root lets daemons and health checks find their entry points and
# libraries, independent of the caller's directory.
node_snapshot_candidate() {
    local source="$1" project="$2" config="$3"

    jq -cnS \
        --arg source "$source" \
        --arg project "$project" \
        --argjson env "$config" \
        '{source:$source,project:$project,env:$env}'
}

# Compare the running snapshot with a candidate, ignoring key order.
node_snapshot_differs() {
    [[ $(jq -cS . <<< "$1") != "$2" ]]
}

node_snapshot_save() {
    printf '%s\n' "$1" > "$STATE/config.json.tmp" || return 1
    mv -- "$STATE/config.json.tmp" "$STATE/config.json"
}
