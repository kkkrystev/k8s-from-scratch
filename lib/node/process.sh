# PID identity and ownership records, local to the Node and protected by
# node's flock. No service selection or health logic lives here.
#
# Linux /proc stat field 22 is starttime; comm can contain spaces/parentheses.
node_identity() {
    local pid="$1" stat rest
    local fields=()

    [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" -gt 1 ]] || return 1

    IFS= read -r stat < "/proc/$pid/stat" 2>/dev/null || return 1
    rest=${stat##*) }
    read -ra fields <<< "$rest"

    [[ ${#fields[@]} -ge 20 && ${fields[0]} != Z && ${fields[0]} != X ]] || return 1

    printf '%s:%s:%s\n' "$BOOT_ID" "$pid" "${fields[19]}"
}

node_alive() {
    local service="$1" record pid actual

    [[ -f "$STATE/$service.pid" ]] || return 1

    IFS= read -r record < "$STATE/$service.pid" || return 1
    pid=${record#*:}
    pid=${pid%%:*}

    actual=$(node_identity "$pid" 2>/dev/null) || return 1
    [[ "$actual" == "$record" ]]
}

node_record_pid() {
    local service="$1" pid="$2" identity

    identity=$(node_identity "$pid") || return 1

    printf '%s\n' "$identity" > "$STATE/$service.pid.tmp" || return 1
    mv -- "$STATE/$service.pid.tmp" "$STATE/$service.pid"
}

node_pid() {
    local record

    IFS= read -r record < "$STATE/$1.pid"
    record=${record#*:}
    printf '%s\n' "${record%%:*}"
}
