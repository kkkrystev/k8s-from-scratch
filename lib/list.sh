# list subcommand.
# Expects CONTAINER_STATE_DIR to be set and meta.sh sourced.

cmd_list() {
    if [[ ! -d "$CONTAINER_STATE_DIR" ]]; then
        echo "No containers."
        return 0
    fi

    local found=0
    local header_printed=0
    local name cdir state started_at human_ts ts

    for cdir in "$CONTAINER_STATE_DIR"/*/; do
        [[ -d "$cdir" ]] || continue
        found=1

        if [[ $header_printed -eq 0 ]]; then
            printf "%-12s  %-36s  %s\n" "STATE" "NAME" "STARTED"
            header_printed=1
        fi

        name=$(basename "$cdir")
        state=$(resolve_state "$cdir")
        ts=$(read_meta "$cdir" started_at)
        human_ts=""
        if [[ -n "$ts" ]]; then
            human_ts=$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || date -r "$ts"   '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || echo "$ts")
        fi

        printf "%-12s  %-36s  %s\n" "$state" "$name" "$human_ts"
    done

    if [[ $found -eq 0 ]]; then
        echo "No containers."
    fi
}
