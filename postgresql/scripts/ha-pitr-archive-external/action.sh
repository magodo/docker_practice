#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Tue 07 Aug 2018 07:46:50 PM CST
# Description:
#########################################################################

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"&& pwd)"
MYNAME="$(basename "${BASH_SOURCE[0]}")"
# shellcheck disable=SC1090
. "$MYDIR"/../common.sh
# shellcheck disable=SC1090
. "$MYDIR"/../config.sh

#########################################################################
# action: start
#########################################################################

usage_start() {
    cat << EOF
Usgae: start [options]

Options:
    -h, --help
    -w, --wait          wait until server is started
EOF
}

do_start() {
    local options=()
    while :; do
        case $1 in
            -h|--help)
                usage_start
                exit 0
                ;;
            -w|--wait)
                options+=("-w")
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done
    
    # docker exec will hang if there is no EOF sent to docker-exec
    # from the forked postgres process, which means the docker-exec
    # is keeping reading from the pipe
    _pg_ctl "${options[@]}" start > /dev/null
}

#########################################################################
# action: stop
#########################################################################

usage_stop() {
    cat << EOF
Usgae: stop [options]

Options:
    -h, --help
EOF
}

do_stop() {
    while :; do
        case $1 in
            -h|--help)
                usage_stop
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done
    
    _pg_ctl stop
}

#########################################################################
# action: setup
#########################################################################

usage_setup() {
    cat << EOF
Usgae: setup [options] [mandatory options]

Options:
    -h, --help
    [--sync|--async]                    Replication mode (by default: --async)

Mandatory Options:
    -r, --role [primary|standby]        Setup for which role(either primary or standby)
    -p, --peer HOST                     Peer hostname
EOF
}

ensure_replication_slot() {
    cat << EOF | _psql
DO
\$do\$
BEGIN
IF NOT EXISTS(
    SELECT
    FROM pg_catalog.pg_replication_slots
    WHERE slot_name = '$REPL_SLOT') THEN

    PERFORM pg_create_physical_replication_slot('$REPL_SLOT');
END IF;
END
\$do\$;
EOF
}

# Usage: do_setup_primary [options] peer
do_setup_primary() {
    local is_sync
    while :; do
        case $1 in
            --sync)
                is_sync=1
                ;;
            --async)
                is_sync=""
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    local peer=$1
    echo "$peer" > "$PEER_HOST_RECORD"
    chown postgres:postgres "$PEER_HOST_RECORD"

    # Here we resolve hostname into ip address is because if pg_hba.conf support hostname only
    # when the hostname could be forward resolved to client ip and the client ip could be backward
    # resolved into hostname.
    # However, using docker-compose setup with `hostname` set for each service, it seems only possible
    # to forward resolve, but backward resolve the ip get a "low-level" name...
    local peer_ipv4="$(getent ahostsv4 $peer | grep "STREAM $peer" | cut -d' ' -f 1)"
    local my_ipv4="$(getent ahostsv4 "$(hostname)" | grep "STREAM" | grep -v $VIP | cut -d' ' -f 1)"

    ##################################
    # server setting
    ##################################

    sed -i "s;#wal_level = minimal;wal_level = replica;" "${PGDATA}"/postgresql.conf
    sed -i "s;#max_wal_senders = 0;max_wal_senders = 5;" "${PGDATA}"/postgresql.conf
    sed -i "s;#listen_addresses = 'localhost';listen_addresses = '*';" "${PGDATA}"/postgresql.conf
    sed -i 's;#max_replication_slots = 0;max_replication_slots = 5;' "${PGDATA}"/postgresql.conf
    sed -i 's;#wal_log_hints = off;wal_log_hints = on;' "${PGDATA}"/postgresql.conf
    sed -i 's;#wal_keep_segments = 0;wal_keep_segments = 64;' "${PGDATA}"/postgresql.conf
    sed -i 's;#archive_mode = off;archive_mode = on;' "${PGDATA}"/postgresql.conf
    sed -i "s;#archive_command = '';archive_command = 'cp %p $ARCHIVE_DIR';" "${PGDATA}"/postgresql.conf

    # sync replication
    [[ -n $is_sync ]] && sed -i "s;^#synchronous_standby_names.*;synchronous_standby_names = 'app_$peer';" "${PGDATA}"/postgresql.conf

    ##################################
    # run-time setting
    ##################################

    # need a running server to setup
    _pg_ctl start -w -l "$PGDATA"/start.log

    # create a replication account
    cat << EOF | _psql
DO
\$do\$
BEGIN
IF NOT EXISTS(
    SELECT
    FROM pg_catalog.pg_roles
    WHERE rolname = '$REPL_USER') THEN

    CREATE ROLE $REPL_USER WITH LOGIN REPLICATION PASSWORD '$REPL_PASSWD';
END IF;
END
\$do\$;
EOF

    ensure_replication_slot

    # ensure a super user for pg_rewind
    cat << EOF | _psql
DO
\$do\$
BEGIN
    IF NOT EXISTS(
        SELECT
        FROM pg_catalog.pg_roles
        WHERE rolname = '$SUPER_USER') THEN

        CREATE ROLE $SUPER_USER WITH LOGIN SUPERUSER PASSWORD '$SUPER_PASSWD';
    ELSE
        ALTER ROLE $SUPER_USER WITH PASSWORD '$SUPER_PASSWD';
    END IF;
END
\$do\$;
EOF

    # stop server once finished
    _pg_ctl stop -w

    ##################################
    # access right setting
    ##################################
    line_in_file "host    replication      ${REPL_USER}      ${peer_ipv4}/32    md5" "${PGDATA}"/pg_hba.conf
    line_in_file "host    replication      ${REPL_USER}      ${my_ipv4}/32      md5" "${PGDATA}"/pg_hba.conf
    line_in_file "host    all              ${SUPER_USER}     0.0.0.0/0          md5" "${PGDATA}"/pg_hba.conf
    # this allow user "postgres" to access all db without password,
    # this is just to provide an easy way for client to access db via vip, test purpose only
    line_in_file "host    all              postgres          0.0.0.0/0          trust" "${PGDATA}"/pg_hba.conf
    line_in_file "local   replication      all                                  trust" "${PGDATA}"/pg_hba.conf
}

do_setup_standby() {
    peer=$1

    ##################################
    # prepare basebackup
    ##################################
    rm -rf "${PGDATA}"
    _pg_basebackup  -D "$PGDATA" -F p -R -S "$REPL_SLOT" -X stream -c fast -d "postgresql://$REPL_USER:$REPL_PASSWD@$peer?application_name=app_$(hostname)"
    # after basebackup, the cofig is synced from primary, which contains necessary configs for primary...

    ##################################
    # setup recovery.conf
    ##################################
    # The recovery.conf generated by pg_basebackup has already contained following config:
    # - standby_mode
    # - primary_conninfo
    # - primary_slot_name
    # generally, we need no more settings.

    echo "$peer" > "$PEER_HOST_RECORD"
}

do_setup() {
    _pg_ctl status &>/dev/null && die "please stop pg first before any setup"

    local role peer
    local sync_opt="--async"
    while :; do
        case $1 in
            -h|--help)
                usage_setup
                exit 0
                ;;
            -r|--role)
                [[ -z $2 ]] && die "-r/--role requires a non-empty option parameter"
                role=$2
                shift
                ;;
            --role=?*)
                role=${1#*=}
                ;;
            -p|--peer)
                [[ -z $2 ]] && die "-p/--peer requires a non-empty option parameter"
                peer=$2
                shift
                ;;
            --peer=?*)
                peer=${1#=*}
                ;;
            --sync)
                sync_opt='--sync'
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    [[ -z $role ]] && die "missing param: role"
    [[ -z $peer ]] && die "missing param: peer"

    case "$role" in
        primary)
            do_setup_primary "$sync_opt" "$peer"
            ;;
        standby)
            do_setup_standby "$peer"
            ;;
    esac
}

#########################################################################
# action: promote
#########################################################################

usage_promote() {
    cat << EOF
Usgae: promote [options]

Options:
    -h, --help
EOF
}

do_promote() {
    # FIXME: add some guard

    _pg_ctl status &>/dev/null || die "only running standby is able to be promoted"

    while :; do
        case $1 in
            -h|--help)
                usage_promote
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    _pg_ctl promote || die "promote failed"

    # wait until promoted cluster is running (-w is available since pg-10)
    if ! timeout 10 bash -c '{
        while :; do
            pg_isready && exit 0
            sleep 1
        done
    }'; then
        die "promoted cluster failed to accept connection"
    fi

    ensure_replication_slot
}

#########################################################################
# action: rewind
#########################################################################

usage_rewind() {
    cat << EOF
Usgae: rewind [options]

Options:
    -h, --help
EOF
}

do_rewind() {
    # FIXME: add some guard

    _pg_ctl status &>/dev/null && _pg_ctl -w stop

    while :; do
        case $1 in
            -h|--help)
                usage_rewind
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    ##########################
    # rewind
    ##########################

    # get peer identity
    peer=$(cat "$PEER_HOST_RECORD")

    # rewind data directory, which results into a nearly synced data directory as source cluster
    # with the gap (WAL) defined as a backup label, which will be filled up once started.
    _pg_rewind -D "$PGDATA" --source-server="postgresql://$SUPER_USER:$SUPER_PASSWD@$peer/postgres" || exit 1

    # pg_rewind will sync target data dir with source server's data dir, hence the peer host record file will be overriden
    # we should modify it to modify it
    echo "$peer" > "$PEER_HOST_RECORD"

    ##########################
    # prepare recovery.conf
    ##########################
    mv "$PGDATA"/recovery.done "$PGDATA"/recovery.conf
    sed -i "s/host=$(hostname)/host=$peer/g" "$PGDATA"/recovery.conf
    sed -i "s/application_name=app_${peer}/application_name=app_$(hostname)/g" "$PGDATA"/recovery.conf

    _pg_ctl start > /dev/null
}

#########################################################################
# action: sync_switch
#########################################################################
usage_sync_switch() {
    cat << EOF
Usage: sync_switch [option] [primary_container] [sync|async]

Description: switch replication mode between sync and async on primary.

Options:
    -h, --help
EOF
}

do_sync_switch() {
    while :; do
        case $1 in
            -h|--help)
                usage_sync_switch
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done
    local mode="$1"

    # get peer identity
    peer=$(cat "$PEER_HOST_RECORD")
    local repl_app="app_$peer"

    case $mode in
        sync)
            echo "Replaced lines in postgresql.conf:"
            sed -n "s/^#synchronous_standby_names.*/synchronous_standby_names = 'app_$peer'/gp" "$PGDATA"/postgresql.conf
            sed -i "s/^#synchronous_standby_names.*/synchronous_standby_names = 'app_$peer'/g" "$PGDATA"/postgresql.conf
            ;;
        async)
            echo "Replaced lines in postgresql.conf:"
            sed -n 's/\(^synchronous_standby_names.*\)/#\1/gp' "$PGDATA"/postgresql.conf
            sed -i 's/\(^synchronous_standby_names.*\)/#\1/g' "$PGDATA"/postgresql.conf
            ;;
    esac
    # reload config for running primary
    _pg_ctl status &>/dev/null && { _pg_ctl reload &> /dev/null || die "pg_ctl reload failed"; }
}

#########################################################################
# action: basebackup
#########################################################################

usage_basebackup() {
    cat << EOF
Usage: basebackup [option]

Description: make a basebackup

Options:
    -h, --help
EOF
}

do_basebackup() {
    while :; do
        case $1 in
            -h|--help)
                usage_basebackup
                exit 1
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    now_ts=$(date +%s)
    local this_basebackup_dir="$BASEBACKUP_DIR/$now_ts"
    mkdir -p "$this_basebackup_dir"
    chown postgres:postgres "$this_basebackup_dir"

    _pg_basebackup -D "$this_basebackup_dir" -X stream -h /tmp || die "failed to do basebackup"
    #_pg_basebackup -D "$this_basebackup_dir" -h /tmp || die "failed to do basebackup"
}

#########################################################################
# action: recover
#########################################################################

usage_recover() {
    cat << EOF
Usage: recover [option] [-t datetime | -p recover_point] nearest_basebackup

Description: recover to a specified datetime or recovery point (created beforehead)

Options:

    -h, --help
    -t datetime                         recover to datetime specified
    -p recover_point                    recover to recovery point specified (which is created before head)
EOF
}

do_recover() {
    local role
    while :; do
        case $1 in
            -h|--help)
                usage_recover 
                exit 1
                ;;
            --)
                shift
                break
                ;;
            -t)
                shift
                recovery_datetime=$1
                ;;
            -p)
                shift
                recovery_point=$1
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    if [[ -z "$recovery_datetime" ]] && [[ -z "$recovery_point" ]]; then
        die "missing paramter: -t / -p"
    fi


    local this_basebackup_dir="$1"

    # stop server if running
    _pg_ctl status && _pg_ctl stop

    # sync PGDATA with basebackup (with some exclusions)
    # NOTE: pg_xlog is synced with basebackup
    rsync --delete -azc --exclude "pg_replslot/*" \
                        --exclude "postmaster.pid" \
                        --exclude "postmaster.opts" \
                        --exclude "peer" \
                        "$this_basebackup_dir/" "$PGDATA"
    # rsync will preserve permission of sending side, even for the top level directory of receiving side
    # while we should guarantee $PGDATA is not gourp or world-wide accessable
    chmod 700 "$PGDATA"

    # create an recovery.conf file to do pitr
    recovery_file="$PGDATA/recovery.conf"
    [[ -f "$recovery_file" ]] || su postgres -c "touch $recovery_file"
    cat << EOF > "$recovery_file"
restore_command = 'cp $ARCHIVE_DIR/%f %p'
recovery_target_timeline = latest
EOF
    if [[ -n "$recovery_point" ]]; then
        echo "recovery_target_name = '$recovery_point'" >> "$recovery_file"
    else
        echo "recovery_target_time = '$recovery_datetime'" >> "$recovery_file"
    fi

    _pg_ctl start -w -l "$PGDATA"/start.log
}

#########################################################################
# action: nearest_basebackup
#########################################################################

usage_nearest_basebackup() {
    cat << EOF
Usage: nearest_basebackup [option] [-t datetime | -p recover_point]

Description: find nearest basebackup against specified datetime or recovery point (created beforehead)

Options:

    -h, --help
    -t datetime                         recover to datetime specified
    -p recover_point                    recover to recovery point specified (which is created before head)
EOF
}

do_nearest_basebackup() {
    while :; do
        case $1 in
            -h|--help)
                usage_recover 
                exit 1
                ;;
            --)
                shift
                break
                ;;
            -t)
                shift
                recovery_datetime=$1
                ;;
            -p)
                shift
                recovery_point=$1
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    if [[ -z "$recovery_datetime" ]] && [[ -z "$recovery_point" ]]; then
        die "missing paramter: -t / -p"
    fi
    if [[ -n "$recovery_point" ]]; then
        if ! ts=$(grep "$recovery_point" "$RUNTIME_INFO_RECOVERY_POINT_MAP_FILE" | cut -d, -f 2); then
            die "failed to get timestamp of recovery point: $recovery_point"
        fi
    else
        ts=$(date -d "$recovery_datetime" +%s)
    fi

    nearest_basebackup_timestamp=0
    while IFS= read -r -d '' candidate; do
        candidate=$(basename "$candidate")
        [[ $candidate -gt "$ts" ]] && break
        if [[ "$(echo "$ts - $candidate" | bc -l)" -lt "$(echo "$ts - $nearest_basebackup_timestamp" | bc -l)" ]]; then
            nearest_basebackup_timestamp="$candidate"
        fi
    done < <(find "$BASEBACKUP_DIR"/* -maxdepth 0 -type d -print0 | sort -z)
    [[ "$nearest_basebackup_timestamp" = 0 ]] && die

    echo "$BASEBACKUP_DIR/$nearest_basebackup_timestamp"
}
