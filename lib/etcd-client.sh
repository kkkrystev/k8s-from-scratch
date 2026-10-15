# etcd client primitives.
# Expects ETCD_DIR to be set by the caller.

etcd_put() {
    local key="$1" value="$2"
    local path="${ETCD_DIR}/${key}"
    mkdir -p "$(dirname "$path")"
    local tmp
    tmp=$(mktemp "${path}.XXXXXX")
    printf '%s' "$value" > "$tmp"
    mv "$tmp" "$path"
}

etcd_get() {
    local key="$1"
    local path="${ETCD_DIR}/${key}"
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    cat "$path"
}

etcd_delete() {
    local key="$1"
    local path="${ETCD_DIR}/${key}"
    rm -f "$path"
}

# Print one key per line whose path starts with the given prefix.
# Prefix is treated as a directory name -- "containers" lists everything under etcd/containers/.
etcd_list() {
    local prefix="${1:-}"
    local base="${ETCD_DIR}/${prefix}"
    [[ -d "$base" ]] || return 0
    find "$base" -type f | while read -r path; do
        # Strip the ETCD_DIR root and leading slash to get the key.
        echo "${path#${ETCD_DIR}/}"
    done
}
