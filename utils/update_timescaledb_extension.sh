#!/bin/bash

# A new TimescaleDB image only adds the newer extension library: the database
# keeps running the version it was created or last updated with until it is
# told to move. The update has to be the first statement of its session (-X,
# so no psqlrc runs ahead of it), and sessions opened before it keep the old
# library loaded, which is why hasura and the api are restarted when it moves.
update_timescaledb_extension() {
    local before available after

    echo "    Waiting for TimescaleDB to start (the first start pulls its image)"
    if ! output_redirect kubectl --kubeconfig="$KUBECONFIG" -n 5stack \
        rollout status statefulset/timescaledb --timeout=300s; then
        warn "timescaledb never became ready; its extension was not updated"
        return 1
    fi

    if ! before="$(timescaledb_psql "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")" \
        || ! available="$(timescaledb_psql "SELECT default_version FROM pg_available_extensions WHERE name = 'timescaledb'")"; then
        warn "timescaledb did not answer; its extension was not updated"
        return 1
    fi
    if [ -z "$before" ] || [ -z "$available" ]; then
        return 0
    fi

    if [ "$before" = "$available" ]; then
        ok "timescaledb extension $before"
        return 0
    fi

    if ! timescaledb_psql "ALTER EXTENSION timescaledb UPDATE" >/dev/null; then
        warn "the timescaledb extension could not be updated; it is still on $before"
        return 1
    fi

    after="$(timescaledb_psql "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
    kubectl --kubeconfig="$KUBECONFIG" -n 5stack rollout restart deployment/hasura deployment/api >/dev/null 2>&1
    ok "timescaledb extension updated from $before to $after"
}

timescaledb_exec() {
    local seconds="$1"
    shift
    time_limited "$seconds" kubectl --kubeconfig="$KUBECONFIG" -n 5stack --request-timeout="${seconds}s" \
        exec timescaledb-0 -c timescaledb -- "$@"
}

timescaledb_psql() {
    timescaledb_exec "${TIMESCALEDB_EXEC_TIMEOUT:-120}" \
        sh -c 'psql -X -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "$1"
}
