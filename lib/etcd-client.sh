# Fake etcd client.
# Expects ETCD_DIR to be set by the caller.
#
# In real etcd, keys like "pods/myapp/spec" are flat strings — the slashes are
# just a naming convention, not a directory structure. Here we approximate that
# by mapping each key to a file on disk, which means the slashes become real
# directories. The semantics are the same; the storage is not.

# Store a value at the given key.
etcd_put() {
    local key="$1" value="$2"
    local path="${ETCD_DIR}/${key}"
    mkdir -p "$(dirname "$path")"
    local tmp
    tmp=$(mktemp "${path}.XXXXXX")
    printf '%s' "$value" > "$tmp"
    mv "$tmp" "$path"
}

# Read the value stored at the given key. Fails if the key does not exist.
etcd_get() {
    local key="$1"
    local path="${ETCD_DIR}/${key}"
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    cat "$path"
}

# Delete a key. No-op if it does not exist.
etcd_delete() {
    local key="$1"
    local path="${ETCD_DIR}/${key}"
    rm -f "$path"
}

# List all keys that start with a given prefix, one per line.
# e.g. etcd_list "pods" returns "pods/myapp/spec", "pods/myapp/status", etc.
etcd_list() {
    local prefix="${1:-}"
    local base="${ETCD_DIR}/${prefix}"
    [[ -d "$base" ]] || return 0
    find "$base" -type f | while read -r path; do
        echo "${path#${ETCD_DIR}/}"
    done
}
