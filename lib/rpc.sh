# Bash client: rpc_call <absolute-socket-path> '<JSON object>'
# Prints a validated response. Returns 0 on ok:true, 1 otherwise.
rpc_call() {
    if [[ $# -ne 2 ]]; then
        echo 'Usage: rpc_call <socket> <JSON-request>' >&2
        return 1
    fi
    local socket="$1" request response
    local timeout="${RPC_TIMEOUT:-5}"

    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || {
        echo 'RPC_TIMEOUT must be a positive integer.' >&2
        return 1
    }
    [[ "$socket" == /* && "$socket" != *[[:space:],:]* && ${#socket} -lt 100 ]] || {
        echo 'Invalid socket path.' >&2
        return 1
    }
    request=$(jq -cse 'if length == 1 and (.[0] | type == "object")
                      then .[0] else error("expected one object") end' <<< "$2") || return 1
    ((${#request} <= 8192)) || { echo 'Request too large.' >&2; return 1; }

    # Retry connection establishment across the short gap between accepts.
    # Never replay a request after it has been sent; the caller decides retries.
    if ! response=$(printf '%s\n' "$request" |
        timeout --kill-after=1 "$timeout" \
        socat -t "$timeout" STDIO "UNIX-CONNECT:$socket,retry=20,interval=0.05"); then
        echo 'RPC transport failed or timed out.' >&2
        return 1
    fi
    if ! response=$(jq -cse '
        if length == 1 and (.[0] | type == "object") then
            .[0] | if (.ok | type == "boolean") and
                      (if .ok then true else (.error | type == "string") end)
                   then . else error("invalid response") end
        else error("invalid response") end
    ' <<< "$response" 2>/dev/null); then
        echo 'Invalid RPC response.' >&2
        return 1
    fi
    printf '%s\n' "$response"
    jq -e '.ok' <<< "$response" >/dev/null
}
