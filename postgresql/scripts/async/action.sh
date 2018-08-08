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
Usgae: setup [options] [-r|--role=[primary|standby]] [--peer|-p peer_host]

Options:
    -h, --help
EOF
}

do_setup_primary() {
    # create a dedicated user for replication
    psql -c "CREATE USER $STANDBY_REPL_USER WITH LOGIN REPLICATION PASSWORD '$STANDBY_REPL_PASSWD'"
    psql -c "pg_create_physical_replication_slot("$STANDBY_REPL_SLOT")"

    ##
    # access permission setup
    # allow standby to replicate via replication user
    line_in_file "host    replication             $user             $standby_ip/32            trusted"
    sed -i "/#host    replication     postgres        ::1\\/128/ a " ${PGDATA}/pg_hba.conf 

    ##
    # global setting

    # WAL archiving setup
    #sed -i "s;#archive_mode = off;archive_mode = on;" ${PGDATA}/postgresql.conf
    #sed -i "s;#archive_command = '';archive_command = 'TBD';" ${PGDATA}/postgresql.conf

    sed -i "s;#wal_level = minimal;wal_level = replica;" "${PGDATA}"/postgresql.conf
    sed -i "s;#listen_addresses = 'localhost';listen_addresses = '*';" "${PGDATA}"/postgresql.conf
    sed -i "s;#max_wal_senders = 0;max_wal_senders = 5;" "${PGDATA}"/postgresql.conf
    sed -i 's;#max_replication_slots = 0;max_replication_slots = 5;' "${PGDATA}"/postgresql.conf

    ##
    # start server
    pg_ctl start -w

}

do_setup_standby() {
}

do_setup() {
    while :; do
        case $1 in
            -h|--help)
                usage_setup
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

    local role=$1
    
    case "$role" in
        primary)
            do_setup_primary
            ;;
        standby)
            do_setup_standby
            ;;
    esac
}

