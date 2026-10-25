# socat accepts one connection at a time. Its handler only relays requests;
# the permanent daemon executes Pod operations and owns the launched children.
runtime_handle_connection() {
    local request directory response deadline

    if ! IFS= read -r -t 3 -n 8193 request; then
        printf '{"ok":false,"error":"incomplete_request"}\n'
        return 0
    fi
    if ((${#request} > 8192)); then
        printf '{"ok":false,"error":"request_too_large"}\n'
        return 0
    fi

    directory=$(mktemp -d "$RUNTIME_WORK_DIR/request.XXXXXXXX") || return 1
    RUNTIME_CONNECTION_DIR="$directory"
    trap 'rm -rf -- "$RUNTIME_CONNECTION_DIR"' EXIT
    printf '%s\n' "$request" > "$directory/request" || return 1

    # A bounded FIFO open prevents a handler hanging after a daemon crash.
    if ! timeout --kill-after=1 3 bash -c \
        'printf "%s\n" "$1" > "$2/inbox"' _ "$directory" "$RUNTIME_WORK_DIR"; then
        printf '{"ok":false,"error":"daemon_unavailable"}\n'
        return 0
    fi

    deadline=$((SECONDS + RUNTIME_TIMEOUT))
    while ((SECONDS < deadline)); do
        if [[ -f "$directory/response" ]]; then
            cat -- "$directory/response"
            return
        fi
        sleep 0.05
    done

    printf '{"ok":false,"error":"operation_timed_out"}\n'
}

runtime_listener_cleanup() {
    trap - EXIT INT TERM
    if [[ -n "${connection_pid:-}" ]]; then
        kill -TERM "$connection_pid" 2>/dev/null || true
        wait "$connection_pid" 2>/dev/null || true
    fi
    [[ ! -S "$RUNTIME_SOCKET" ]] || rm -f -- "$RUNTIME_SOCKET"
}

runtime_listen() {
    local connection_pid=''
    local result

    trap runtime_listener_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cd -- "$SCRIPT_DIR" || return 1

    while true; do
        setpriv --pdeathsig TERM socat \
            "UNIX-LISTEN:$RUNTIME_SOCKET,mode=0600,unlink-close=0" \
            'EXEC:bash ./runtimed --handle,nofork' &
        connection_pid=$!
        if wait "$connection_pid"; then result=0; else result=$?; fi
        connection_pid=''
        [[ ! -S "$RUNTIME_SOCKET" ]] || rm -f -- "$RUNTIME_SOCKET"
        ((result == 0)) || return "$result"
    done
}

runtime_process_directory() {
    local directory="$1"
    local request

    # Only accept the private directories created by this listener's handlers.
    [[ "${directory%/*}" == "$RUNTIME_WORK_DIR" ]] || return 0
    [[ "${directory##*/}" =~ ^request\.[a-zA-Z0-9]{8}$ ]] || return 0
    [[ -d "$directory" && ! -L "$directory" ]] || return 0
    [[ -f "$directory/request" && ! -L "$directory/request" ]] || return 0

    request=$(cat -- "$directory/request") || return 0
    if ((${#request} > 8192)); then
        runtime_error_reply request_too_large > "$directory/response.tmp"
    else
        runtime_dispatch "$request" > "$directory/response.tmp"
    fi
    # If the client has timed out, the operation may still have completed.
    # Never replay the request here.
    if [[ -d "$directory" ]]; then
        mv -- "$directory/response.tmp" "$directory/response" || true
    fi
}
