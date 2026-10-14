#!/bin/bash

# Runs inside the timescaledb-major-upgrade Job that upgrade_timescaledb_major
# creates, never on the operator's machine. `prepare` runs first, in an init
# container on the old major's image; `upgrade` follows in the main container on
# the new major's image. /pv is the volume root (no subPath), and /old is an
# emptyDir that hands the old major's binaries from the first to the second.
set -euo pipefail

PV=/pv
DATA="$PV/timescaledb"
STAGE="$PV/timescaledb-pg$NEW_MAJOR-upgrade"
OLD=/old
RUN=/tmp/pg-upgrade
ROLLBACK=""
SWAPPED=""

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

as_postgres() {
    gosu postgres "$@"
}

controldata() {
    LC_ALL=C pg_controldata "$DATA" | sed -n "s/^$1: *//p"
}

# Both majors are started on a private socket with trust auth, whatever the
# cluster's own pg_hba.conf says: pg_upgrade connects many times and has no
# password to give.
private_socket() {
    mkdir -p "$RUN"
    echo "local all all trust" >"$RUN/pg_hba.conf"
    chown -R postgres:postgres "$RUN"
    chmod 700 "$RUN"
}

old_psql() {
    as_postgres psql -X -v ON_ERROR_STOP=1 -At -h "$RUN" -U "$POSTGRES_USER" "$@"
}

stop_old_server() {
    as_postgres pg_ctl -D "$DATA" -m fast -w -t 3600 stop >/dev/null 2>&1 || true
}

prepare() {
    local rollback used_kb free_kb size_kb need_kb dbs db before after template1 var

    OLD_MAJOR="$(cat "$DATA/PG_VERSION")"
    rollback="$PV/timescaledb-pg$OLD_MAJOR"
    echo "data is PostgreSQL $OLD_MAJOR, upgrading to $NEW_MAJOR with TimescaleDB $TIMESCALEDB_VERSION"

    if [ "$OLD_MAJOR" -ge "$NEW_MAJOR" ]; then
        fail "the data is already PostgreSQL $OLD_MAJOR"
    fi
    if [ -e "$rollback" ]; then
        fail "$rollback already exists; refusing to overwrite it"
    fi

    rm -rf "$STAGE"
    used_kb="$(du -sk "$DATA" | cut -f1)"
    free_kb="$(df -Pk "$PV" | awk 'NR == 2 { print $4 }')"
    size_kb="$(df -Pk "$PV" | awk 'NR == 2 { print $2 }')"
    if [[ ! "$used_kb$free_kb$size_kb" =~ ^[0-9]+$ ]]; then
        fail "could not read the volume's size (used '$used_kb', free '$free_kb', size '$size_kb' KiB)"
    fi
    need_kb=$((used_kb + used_kb / 10 + TIMESCALEDB_UPGRADE_HEADROOM_KB + size_kb / 20))
    if [ "$free_kb" -lt "$need_kb" ]; then
        fail "the copy needs $((need_kb / 1024)) MiB free on the volume and only $((free_kb / 1024)) MiB is: $(((need_kb - free_kb) / 1024)) MiB short"
    fi

    private_socket
    trap stop_old_server EXIT
    if ! as_postgres pg_ctl -D "$DATA" -w -t 3600 -l "$RUN/server.log" \
        -o "-c listen_addresses='' -c unix_socket_directories=$RUN -c hba_file=$RUN/pg_hba.conf -c shared_preload_libraries=timescaledb" \
        start >/dev/null; then
        cat "$RUN/server.log" >&2
        fail "PostgreSQL $OLD_MAJOR did not start on the data"
    fi

    # pg_upgrade only carries an extension over at the version it is installed
    # at, so both sides have to be on the TimescaleDB release the new image
    # runs. The update has to be the first statement of its session, hence a
    # fresh psql for it.
    dbs="$(old_psql -d template1 -c "SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname")"
    while IFS= read -r db; do
        before="$(old_psql -d "$db" -c "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
        if [ -z "$before" ]; then
            continue
        fi
        if [ "$before" != "$TIMESCALEDB_VERSION" ]; then
            old_psql -d "$db" -c "ALTER EXTENSION timescaledb UPDATE" >/dev/null
        fi
        after="$(old_psql -d "$db" -c "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
        if [ "$after" != "$TIMESCALEDB_VERSION" ]; then
            fail "timescaledb in $db is $after after its update, not $TIMESCALEDB_VERSION"
        fi
        echo "timescaledb in $db: $before -> $after"
    done <<<"$dbs"

    INSTALL_USER="$(old_psql -d template1 -c "SELECT rolname FROM pg_authid WHERE oid = 10")"
    template1="$(old_psql -d template1 -F '|' -c \
        "SELECT pg_encoding_to_char(encoding), datcollate, datctype, datlocprovider, coalesce(datlocale, '') FROM pg_database WHERE datname = 'template1'")"
    IFS='|' read -r ENCODING COLLATE CTYPE PROVIDER LOCALE <<<"$template1"

    as_postgres pg_ctl -D "$DATA" -m fast -w -t 3600 stop >/dev/null
    trap - EXIT
    if [ "$(controldata "Database cluster state")" != "shut down" ]; then
        fail "PostgreSQL $OLD_MAJOR did not shut down cleanly"
    fi
    CHECKSUMS="$(controldata "Data page checksum version")"

    for var in OLD_MAJOR INSTALL_USER ENCODING COLLATE CTYPE PROVIDER LOCALE CHECKSUMS; do
        printf '%s=%q\n' "$var" "${!var}"
    done >"$OLD/cluster.env"
    echo "template1: $ENCODING, collate $COLLATE, ctype $CTYPE, provider $PROVIDER; data checksums version $CHECKSUMS"

    # PostgreSQL is relocatable: these binaries find their libraries and share
    # files relative to $OLD/bin, and both images are the same Alpine release,
    # so the system libraries they link against are the same. TimescaleDB's
    # extension scripts are most of the image and the old server, which only
    # answers pg_upgrade's catalog reads, never runs one.
    tar -C /usr/local --exclude=./include --exclude='./share/postgresql/extension/timescaledb--*' -cf - . | tar -C "$OLD" -xf -
    echo "PostgreSQL $OLD_MAJOR binaries handed over"
}

discard_stage() {
    local status=$?
    if [ "$status" -eq 0 ] || [ -n "$SWAPPED" ]; then
        return
    fi
    if [ -f "$STAGE/postmaster.pid" ]; then
        as_postgres pg_ctl -D "$STAGE" -m immediate -w stop >/dev/null 2>&1 || true
    fi
    if [ -d "$STAGE/pg_upgrade_output.d" ]; then
        find "$STAGE/pg_upgrade_output.d" -name '*.txt' -exec tail -n +1 -v {} + >&2 || true
        find "$STAGE/pg_upgrade_output.d" -name '*.log' -exec tail -n 20 -v {} + >&2 || true
    fi
    if [ ! -e "$DATA" ] && [ -n "$ROLLBACK" ] && [ -d "$ROLLBACK" ]; then
        mv -T "$ROLLBACK" "$DATA"
    fi
    rm -rf "$STAGE"
    if [ "$(cat "$DATA/PG_VERSION" 2>/dev/null)" = "$OLD_MAJOR" ]; then
        echo "the PostgreSQL $OLD_MAJOR data in $DATA was left in place" >&2
    fi
}

upgrade() {
    local pkglibdir conf
    local -a initdb_args upgrade_args

    # shellcheck source=/dev/null
    source "$OLD/cluster.env"

    if [ "$(cat "$DATA/PG_VERSION")" != "$OLD_MAJOR" ]; then
        fail "$DATA changed since it was prepared"
    fi
    if ! as_postgres "$OLD/bin/postgres" -V | grep -q "PostgreSQL) $OLD_MAJOR\."; then
        fail "the PostgreSQL $OLD_MAJOR binaries do not run in this image"
    fi
    pkglibdir="$(pg_config --pkglibdir)"
    if [ ! -f "$pkglibdir/timescaledb-$TIMESCALEDB_VERSION.so" ]; then
        fail "this image has no TimescaleDB $TIMESCALEDB_VERSION for PostgreSQL $NEW_MAJOR"
    fi

    trap discard_stage EXIT
    mkdir "$STAGE"
    chown postgres:postgres "$STAGE"
    chmod 700 "$STAGE"
    private_socket

    # PostgreSQL 18's initdb turns data checksums on by default, and pg_upgrade
    # refuses clusters that disagree on them.
    initdb_args=(-D "$STAGE" -U "$INSTALL_USER" --encoding="$ENCODING" --lc-collate="$COLLATE" --lc-ctype="$CTYPE")
    case "$PROVIDER" in
        c) initdb_args+=(--locale-provider=libc) ;;
        i) initdb_args+=(--locale-provider=icu --icu-locale="$LOCALE") ;;
        b) initdb_args+=(--locale-provider=builtin --builtin-locale="$LOCALE") ;;
        *) fail "unknown locale provider $PROVIDER" ;;
    esac
    if [ "$CHECKSUMS" = 0 ]; then
        initdb_args+=(--no-data-checksums)
    else
        initdb_args+=(--data-checksums)
    fi
    if ! as_postgres initdb "${initdb_args[@]}" >"$RUN/initdb.log" 2>&1; then
        cat "$RUN/initdb.log" >&2
        fail "initdb failed"
    fi
    echo "PostgreSQL $NEW_MAJOR cluster initialised in $STAGE"

    cp -p "$DATA/postgresql.conf" "$DATA/pg_hba.conf" "$STAGE/"
    for conf in postgresql.auto.conf pg_ident.conf; do
        if [ -f "$DATA/$conf" ]; then
            cp -p "$DATA/$conf" "$STAGE/"
        fi
    done
    if ! as_postgres postgres -D "$STAGE" -C config_file >/dev/null 2>"$RUN/config.log"; then
        cat "$RUN/config.log" >&2
        fail "the PostgreSQL $OLD_MAJOR configuration is not valid on PostgreSQL $NEW_MAJOR"
    fi
    echo "configuration carried over"

    # pg_dump locks every table in one transaction and every chunk is a table,
    # so the default lock table runs out once there are many thousands of them.
    cd "$RUN"
    upgrade_args=(
        --old-datadir="$DATA" --new-datadir="$STAGE"
        --old-bindir="$OLD/bin" --new-bindir="$(pg_config --bindir)"
        --username="$INSTALL_USER" --socketdir="$RUN"
        --old-options="-c hba_file=$RUN/pg_hba.conf -c shared_preload_libraries=timescaledb -c jit=off -c max_locks_per_transaction=1024"
        --new-options="-c hba_file=$RUN/pg_hba.conf -c shared_preload_libraries=timescaledb -c max_locks_per_transaction=1024"
    )
    as_postgres pg_upgrade "${upgrade_args[@]}" --check
    as_postgres pg_upgrade "${upgrade_args[@]}" --copy

    # pg_upgrade leaves every extension at the version it was on and writes the
    # updates the new major ships into this file; applied now, while nothing
    # else is connected.
    if [ -f "$RUN/update_extensions.sql" ]; then
        as_postgres pg_ctl -D "$STAGE" -w -t 3600 -l "$RUN/server.log" \
            -o "-c listen_addresses='' -c unix_socket_directories=$RUN -c hba_file=$RUN/pg_hba.conf -c shared_preload_libraries=timescaledb" \
            start >/dev/null
        as_postgres psql -X -v ON_ERROR_STOP=1 -q -h "$RUN" -U "$INSTALL_USER" -d template1 -f "$RUN/update_extensions.sql"
        as_postgres pg_ctl -D "$STAGE" -m fast -w -t 3600 stop >/dev/null
        sed -n 's/^ALTER EXTENSION/applied: &/p' "$RUN/update_extensions.sql"
    fi

    sync
    if [ -e "$PV/timescaledb-pg$OLD_MAJOR" ]; then
        fail "$PV/timescaledb-pg$OLD_MAJOR appeared during the upgrade"
    fi
    # Between these two renames there is no database at $DATA: a Job deadline
    # or a deleted pod must not stop the script halfway.
    trap '' TERM INT
    ROLLBACK="$PV/timescaledb-pg$OLD_MAJOR"
    mv -T "$DATA" "$ROLLBACK"
    mv -T "$STAGE" "$DATA"
    SWAPPED=1
    sync
    echo "PostgreSQL $NEW_MAJOR is now in $DATA; PostgreSQL $OLD_MAJOR is kept in $ROLLBACK"
}

case "${1:-}" in
    prepare) prepare ;;
    upgrade) upgrade ;;
    *) fail "usage: $0 prepare|upgrade" ;;
esac
