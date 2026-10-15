# Expects POD_STATE_DIR to be set by the caller.

pod_dir() {
    echo "${POD_STATE_DIR}/$1"
}

write_meta() {
    local dir="$1" key="$2" value="$3"
    printf '%s' "$value" > "${dir}/${key}"
}

read_meta() {
    local dir="$1" key="$2"
    cat "${dir}/${key}" 2>/dev/null || true
}
