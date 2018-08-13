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

    # record peer hostname
    local peer=$1
    echo "$peer" > "$PEER_HOST_RECORD"
    chown postgres:postgres "$PEER_HOST_RECORD"

    # Here we resolve hostname into ip address is because if pg_hba.conf support hostname only
    # when the hostname could be forward resolved to client ip and the client ip could be backward
    # resolved into hostname.
    # However, using docker-compose setup with `hostname` set for each service, it seems only possible
    # to forward resolve, but backward resolve the ip get a "low-level" name...
    local peer_ipv4="$(getent ahostsv4 $peer | grep "STREAM $peer" | cut -d' ' -f 1)"

    # we need to add access rule for all the dns forward lookup ipv4 of our hostname, since it seems like
    # repmgr will choose arbitrary ipv4 based on hostname.
    local my_ipv4s
    IFS=$'\n' read -d '' -r -a my_ipv4s < <(getent ahostsv4 "$(hostname)" | grep "STREAM" | cut -d' ' -f 1)
    declare -p my_ipv4s

    ##################################
    # server setting
    ##################################

	extra_config_file=$PGDATA/postgresql.repmgr.conf
    cat << "EOF" > "$extra_config_file"
# Enable replication connections; set this figure to at least one more
# than the number of standbys which will connect to this server
# (note that repmgr will execute `pg_basebackup` in WAL streaming mode,
# which requires two free WAL senders)

max_wal_senders = 10

# Ensure WAL files contain enough information to enable read-only queries
# on the standby.
#
#  PostgreSQL 9.5 and earlier: one of 'hot_standby' or 'logical'
#  PostgreSQL 9.6 and later: one of 'replica' or 'logical'
#    ('hot_standby' will still be accepted as an alias for 'replica')
#
# See: https://www.postgresql.org/docs/current/static/runtime-config-wal.html#GUC-WAL-LEVEL

wal_level = 'hot_standby'

# Enable read-only queries on a standby
# (Note: this will be ignored on a primary but we recommend including
# it anyway)

hot_standby = on

# Enable WAL file archiving
archive_mode = on

# Set archive command to a script or application that will safely store
# you WALs in a secure place. /bin/true is an example of a command that
# ignores archiving. Use something more sensible.
archive_command = '/bin/true'

# If you have configured "pg_basebackup_options"
# in "repmgr.conf" to include the setting "--xlog-method=fetch" (from
# PostgreSQL 10 "--wal-method=fetch"), *and* you have not set
# "restore_command" in "repmgr.conf"to fetch WAL files from another
# source such as Barman, you'll need to set "wal_keep_segments" to a
# high enough value to ensure that all WAL files generated while
# the standby is being cloned are retained until the standby starts up.
#
# wal_keep_segments = 5000

listen_addresses = '*'
EOF
    chown postgres:postgres $extra_config_file
    line_in_file "include $(basename $extra_config_file)" $PGDATA/postgresql.conf

    ##################################
    # run-time setting
    ##################################

    # need a running server to setup
    _pg_ctl start -w

    # create repmgr user and database
    echo "CREATE ROLE repmgr WITH SUPERUSER LOGIN;" | _psql
    echo "CREATE DATABASE repmgr OWNER repmgr;" | _psql
    echo "ALTER USER repmgr SET search_path TO repmgr, \"\$user\", public;" | _psql

    # ensure a super user
    cat << EOF | _psql
DO
\$do\$
BEGIN
    IF NOT EXISTS(
        SELECT
        FROM pg_catalog.pg_roles
        WHERE rolname = '$SUPER_USER') THEN

        CREATE ROLE $SUPER_USER WITH LOGIN REPLICATION PASSWORD '$SUPER_PASSWD';
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

    line_in_file "local   replication      repmgr      trust" "${PGDATA}"/pg_hba.conf
    line_in_file "host    replication      repmgr      127.0.0.1/32    trust" "${PGDATA}"/pg_hba.conf
    line_in_file "host    replication      repmgr      $peer_ipv4/32    trust" "${PGDATA}"/pg_hba.conf

    line_in_file "local   repmgr      repmgr      trust" "${PGDATA}"/pg_hba.conf
    line_in_file "host    repmgr      repmgr      127.0.0.1/32    trust" "${PGDATA}"/pg_hba.conf
    line_in_file "host    repmgr      repmgr      $peer_ipv4/32    trust" "${PGDATA}"/pg_hba.conf
    
    for my_ipv4 in "${my_ipv4s[@]}"; do
        line_in_file "host    replication      repmgr      $my_ipv4/32    trust" "${PGDATA}"/pg_hba.conf
        line_in_file "host    repmgr      repmgr      $my_ipv4/32    trust" "${PGDATA}"/pg_hba.conf
    done

    line_in_file "host    all              ${SUPER_USER}     0.0.0.0/0          trust" "${PGDATA}"/pg_hba.conf

    ##################################
    # start server
    ##################################
    _pg_ctl start -w &> /dev/null || die "start failed"

    ##################################
    # repmgr config file
    ##################################

    repmgr_config_file="/etc/repmgr.conf"
    cat << EOF > $repmgr_config_file
node_id=1
node_name=$(hostname)
conninfo='host=$(hostname) user=repmgr dbname=repmgr connect_timeout=2'
data_directory='$PGDATA'
EOF
    chown postgres:postgres $repmgr_config_file

    ##################################
    # register to repmgr
    ##################################
    _repmgr -f $repmgr_config_file primary register

}

do_setup_standby() {
    peer=$1

    ##################################
    # repmgr config file
    ##################################

    repmgr_config_file="/etc/repmgr.conf"
    cat << EOF > $repmgr_config_file
node_id=2
node_name=$(hostname)
conninfo='host=$(hostname) user=repmgr dbname=repmgr connect_timeout=2'
data_directory='$PGDATA'
EOF
    chown postgres:postgres $repmgr_config_file

    ##################################
    # clone the standby server
    ##################################
    rm -rf $PGDATA
    _repmgr -h $peer -U repmgr -d repmgr -f $repmgr_config_file standby clone

    ##################################
    # additional config
    ##################################
    echo "$peer" > "$PEER_HOST_RECORD"
    chown postgres:postgres $PEER_HOST_RECORD

    ##################################
    # start server
    ##################################
    _pg_ctl start -w &> /dev/null || die "start failed"

    ##################################
    # register to repmgr
    ##################################
    _repmgr -f $repmgr_config_file standby register
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

    # wait until promoted cluster is running
    if ! timeout 10 bash -c '{
        while :; do
            su postgres -c "psql -c \"select;\"" &> /dev/null && exit 0
            sleep 1
        done
    }'; then
        die "promoted cluster starting timeout"
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
    echo $peer > "$PEER_HOST_RECORD"

    ##########################
    # prepare recovery.conf
    ##########################
    # since we are going to act as a standby after start,
    # we need to define a recovery.conf
    cat << EOF > "$PGDATA"/recovery.conf
standby_mode = 'on'
recovery_target_timeline = 'latest'
primary_conninfo = 'postgresql://$REPL_USER:$REPL_PASSWD@$peer/postgres?application_name=app_$(hostname)'
primary_slot_name = '$REPL_SLOT'
EOF
    chown postgres:postgres "$PGDATA"/recovery.conf

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
