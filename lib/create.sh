# Expects ETCD_DIR to be set and etcd-client.sh / json.sh / validate.sh sourced.

create_container() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 create <name> <command> [args...]" >&2
        return 1
    fi

    local name="$1"
    shift

    validate_name "$name"

    if etcd_get "containers/${name}/spec" >/dev/null 2>&1; then
        echo "Pod '$name' already exists." >&2
        return 1
    fi

    etcd_put "containers/${name}/spec" "$(json_build_spec "$name" "$@")"
    echo "Pod '$name' created."
}
