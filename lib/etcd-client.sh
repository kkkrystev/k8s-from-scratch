# Filesystem-backed teaching approximation of etcd. Not real etcd transactions.
etcd_put() {
    local path="$ETCD_DIR/$1" value="$2" tmp
    mkdir -p -- "$(dirname -- "$path")" || return 1
    tmp=$(mktemp "${path}.XXXXXX") || return 1
    if ! printf '%s' "$value" > "$tmp" || ! mv -- "$tmp" "$path"; then
        rm -f -- "$tmp"
        return 1
    fi
}

etcd_get() {
    [[ -f "$ETCD_DIR/$1" ]] || return 1
    cat -- "$ETCD_DIR/$1"
}

etcd_delete() { rm -f -- "$ETCD_DIR/$1"; }

etcd_list() {
    local base="$ETCD_DIR/${1:-}" path
    [[ -d "$base" ]] || return 0
    find "$base" -type f | while IFS= read -r path; do
        printf '%s\n' "${path#"$ETCD_DIR/"}"
    done
}

etcd_pod_names() {
    local keys key name
    keys=$(etcd_list pods) || return 1
    while IFS= read -r key; do
        [[ "$key" == pods/*/spec ]] || continue
        name=${key#pods/}
        name=${name%/spec}
        [[ "$name" != */* ]] || continue
        printf '%s\n' "$name"
    done <<< "$keys"
}
