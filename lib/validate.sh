# Expects ROOTFS to be set by the caller (kfs or runtime.sh).

validate_name() {
    local name="$1"

    if [[ ${#name} -gt 63 ||
          ! "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        echo "Invalid pod name: $name" >&2
        return 1
    fi
}

validate_rootfs() {
    if [[ "$ROOTFS" != /* ]]; then
        echo "ROOTFS must be an absolute path: $ROOTFS" >&2
        return 1
    fi

    if [[ ! -d "$ROOTFS" ]]; then
        echo "Root filesystem directory does not exist: $ROOTFS" >&2
        echo "Run setup-rootfs.sh with the same ROOTFS setting." >&2
        return 1
    fi

    if [[ ! -d "$ROOTFS/proc" ]]; then
        echo "Root filesystem has no /proc directory: $ROOTFS" >&2
        return 1
    fi
}

validate_etcd_endpoint() {
    local endpoint="$1"

    if [[ ! "$endpoint" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*:[1-9][0-9]{0,4}$ ]]; then
        echo 'Invalid ETCD_ENDPOINT (host:port).' >&2
        return 1
    fi

    if (( ${endpoint##*:} > 65535 )); then
        echo 'Invalid ETCD_ENDPOINT (host:port).' >&2
        return 1
    fi
}

validate_positive_integer() {
    local value="$1"

    [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

# Currently unused: the runtime no longer selects a default shell.
#
# Only called when /bin/bash is selected as the default command.
#validate_default_shell() {
#    if [[ ! -x "$ROOTFS/bin/bash" ]]; then
#        echo "Root filesystem has no executable /bin/bash: $ROOTFS" >&2
#        echo "Run setup-rootfs.sh with the same ROOTFS setting." >&2
#        return 1
#    fi
#}
