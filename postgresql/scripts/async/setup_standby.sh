#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Wed 04 Jul 2018 07:11:35 PM CST
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
    ./$(MYNAME) [option] master_host master_port
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

master_host=$1
master_port=$2

if [[ ! -z $master_host ]] && [[ ! -z $master_port ]]; then
    :
else
    die "not enough argument"
fi

# create pg password file for replication user
echo "$master_host:$master_port:replication:$user:$passwd" > ~/.pgpass
chmod 0600 ~/.pgpass

# backup from master
[[ -d $PGDATA ]] && rm -rf "${PGDATA:?}"/*
pg_basebackup -h "$master_host" -p "$master_port" --username "$user" --no-password -F p -P -X stream -R -l mybacup -D "$PGDATA" || exit 1

# config standby
#sed -i "s;#hot_standby = off;hot_standby = on;" ${PGDATA}/postgresql.conf || exit 1

# start server
pg_ctl start
