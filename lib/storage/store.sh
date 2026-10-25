# Single-writer store. Only etcdd owns ETCD_DIR; every mutation replaces state.json.
# This file is pure state I/O; request validation and actions live in service.sh.

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
