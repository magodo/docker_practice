#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Fri 06 Jul 2018 11:38:29 AM CST
# Description:
#########################################################################

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"&& pwd)"
MYNAME="$(basename "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1090
. "$MYDIR"/utils.sh
# shellcheck disable=SC1090
. "$MYDIR"/conf.sh

usage() {
    cat << EOF
    ./${MYNAME} [option] standby_ip
EOF
}

# must run using postgres user
[[ "$(whoami)" != postgres ]] && die "effective user is not postgres"

while :; do
    case $1 in
        -h|--help)
            usage
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

standby_ip=$1
[[ -z $standby_ip ]] && die "please specify ip of standby server"

##
# access permission setup

# allow standby to replicate via replication user
sed -i "/#host    replication     postgres        ::1\\/128/ a host    replication             $user             $standby_ip/32            md5" ${PGDATA}/pg_hba.conf 

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

# create a dedicated user for replication
psql -c "CREATE USER $user WITH LOGIN REPLICATION PASSWORD '$passwd'"
psql -c "pg_create_physical_replication_slot("$slot_name")"
