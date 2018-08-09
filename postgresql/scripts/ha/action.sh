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
# start
#########################################################################

usage_start() {
    cat << EOF
Usgae: start [options]

Options:
    -h, --help
EOF
}

do_start() {
    while :; do
        case $1 in
            -h|--help)
                usage_start
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
    
    _pg_ctl start
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
Usgae: setup [options] [-r|--role=[primary|standby]] [-p|--peer=peer_host]

Options:
    -h, --help
    -r, --role ROLE         Setup for which role(either primary or standby)
    -p, --peer HOST         Peer hostname
EOF
}

# Usage: do_setup_primary [options] peer
# Options:
#   --no-user           do not create replication user (mainly used for setup on standby)
#   --no-slot           do not create replication slot (mainly used for setup on standby)
do_setup_primary() {
    while :; do
        case $1 in
            --no-user)
                local no_user=1
                ;;
            --no-slot)
                local no_slot=1
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
    # Here we resolve hostname into ip address is because if pg_hba.conf support hostname only
    # when the hostname could be forward resolved to client ip and the client ip could be backward
    # resolved into hostname.
    # However, using docker-compose setup with `hostname` set for each service, it seems only possible
    # to forward resolve, but backward resolve the ip get a "low-level" name...
    local peer_ipv4="$(getent ahostsv4 $peer | grep "STREAM $peer" | cut -d' ' -f 1)"

    ##################################
    # server setting
    ##################################

    sed -i "s;#wal_level = minimal;wal_level = replica;" "${PGDATA}"/postgresql.conf
    sed -i "s;#max_wal_senders = 0;max_wal_senders = 5;" "${PGDATA}"/postgresql.conf
    sed -i "s;#listen_addresses = 'localhost';listen_addresses = '*';" "${PGDATA}"/postgresql.conf
    sed -i 's;#max_replication_slots = 0;max_replication_slots = 5;' "${PGDATA}"/postgresql.conf

    ##################################
    # run-time setting
    ##################################

    if [[ $no_user != 1 ]] || [[ $no_slot != 1 ]]; then
        # need a running server to setup
        _pg_ctl start -w

        if [[ $no_user != 1 ]]; then
            # create a dedicated user for replication
            cat << EOF | _psql
DO
\$do\$
BEGIN
    IF NOT EXISTS(
        SELECT
        FROM pg_catalog.pg_roles
        WHERE rolname = '$STANDBY_REPL_USER') THEN

        CREATE ROLE $STANDBY_REPL_USER WITH LOGIN REPLICATION PASSWORD '$STANDBY_REPL_PASSWD';
    END IF;
END
\$do\$;
EOF
        fi

        if [[ $no_slot != 1 ]]; then
            # create a replication slot for standby
            cat << EOF | _psql
DO
\$do\$
BEGIN
    IF NOT EXISTS(
        SELECT
        FROM pg_catalog.pg_replication_slots
        WHERE slot_name = '$STANDBY_REPL_SLOT') THEN

        PERFORM pg_create_physical_replication_slot('$STANDBY_REPL_SLOT');
    END IF;
END
\$do\$;
EOF
            echo "" | _psql
        fi

        # stop server once finished
        _pg_ctl stop -w
    fi

    ##################################
    # access right setting
    ##################################
    line_in_file "host    replication      ${STANDBY_REPL_USER}      ${peer_ipv4}/32      md5" "${PGDATA}"/pg_hba.conf
    # this allow user "postgres" to access all db without password,
    # this is just to provide an easy way for client to access db via vip, test purpose only
    line_in_file "host    all      postgres      0.0.0.0/0      trust" "${PGDATA}"/pg_hba.conf

}

do_setup_standby() {
    peer=$1

    ##################################
    # prepare basebackup
    ##################################
    rm -rf "${PGDATA}"
    run_as_postgres pg_basebackup  -D "$PGDATA" -F p -R -S "$STANDBY_REPL_SLOT" -X stream -c fast -d "postgresql://$STANDBY_REPL_USER:$STANDBY_REPL_PASSWD@$peer?application_name=app_$(hostname)"

    ##################################
    # setup recovery.conf
    ##################################
    # The recovery.conf generated by pg_basebackup has already contained following config:
    # - standby_mode
    # - primary_conninfo
    # - primary_slot_name
    # generally, we need no more settings.
    
    # since this standby might later become primary, hence we should do primary setup also
    do_setup_primary --no-user --no-slot "$1"
}

do_setup() {
    _pg_ctl status &>/dev/null && die "please stop pg first before any setup"

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
            do_setup_primary "$peer"
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
    # FIXME: need a way to guarantee the invoking db is standby 
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

    _pg_ctl promote 
}
