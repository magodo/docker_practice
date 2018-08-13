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

do_setup_backup() {
    local backup_method
    while :; do
        case $1 in
            --backup-method|-b)
                [[ -z $2 ]] && die "-b/--backup-method need non-empty argumetn"
                backup_method=$2
                shift
                ;;
            --backup-method=?*)
                backup_method=${1#*=}
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

    [[ -z $backup_method ]] && die "please specify backup method via -b/--backup-method"
    local peer=$1
    local peer_ipv4="$(getent ahostsv4 $peer | grep "STREAM $peer" | cut -d' ' -f 1)"

    #####################
    # pgpass file for barman and barman_repl
    #####################

    local pgpass_file="$(su barman -c 'echo $HOME')"/.pgpass
    cat << EOF > $pgpass_file
*:*:*:$BARMAN_USER:$BARMAN_PASSWD
*:*:*:$BARMAN_REPL_USER:$BARMAN_REPL_PASSWD
EOF
    chown barman:barman $pgpass_file
    chmod 600 $pgpass_file

    #####################
    # global configuration file
    #####################

    #####################
    # per server configuration file
    #####################
    local server_conf_file="/etc/barman.d/$peer.conf"
    cat << EOF > $server_conf_file
[$peer]

description = "Primary PG server"
conninfo = host=$peer user=$BARMAN_USER dbname=postgres
streaming_conninfo = host=$peer user=$BARMAN_REPL_USER dbname=postgres
streaming_archiver = on
slot_name = slot_${peer}
EOF
    case $backup_method in
        rsync)
            cat << EOF >> $server_conf_file
backup_method = rsync
ssh_command = ssh postgres@$peer
EOF
            ;;
        postgres)
            cat << EOF >> $server_conf_file
backup_method = postgres
EOF
            ;;
        *)
            die "unkown backup method: $backup_method"
            ;;
    esac

    #####################
    # create replication slot
    #####################

    su barman -c "barman receive-wal --create-slot $peer" || die "failed to create replication slot"
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

    local backup=$1
    local peer=$2
    echo "$peer" > "$PEER_HOST_RECORD"
    chown postgres:postgres "$PEER_HOST_RECORD"

    # Here we resolve hostname into ip address is because if pg_hba.conf support hostname only
    # when the hostname could be forward resolved to client ip and the client ip could be backward
    # resolved into hostname.
    # However, using docker-compose setup with `hostname` set for each service, it seems only possible
    # to forward resolve, but backward resolve the ip get a "low-level" name...
    local peer_ipv4="$(getent ahostsv4 $peer | grep "STREAM $peer" | cut -d' ' -f 1)"
    local backup_ipv4="$(getent ahostsv4 $backup | grep "STREAM $backup" | cut -d' ' -f 1)"
    local my_ipv4="$(getent ahostsv4 "$(hostname)" | grep "STREAM" | grep -v $VIP | cut -d' ' -f 1)"

    ##################################
    # server setting
    ##################################

    local barman_incoming_dir="/var/lib/barman/$(hostname)/incoming"
    local custom_conf_file="$PGDATA/postgresql.custom.conf"
    cat << EOF > $custom_conf_file
wal_level = 'replica'

max_wal_senders = 5
max_replication_slots = 5

listen_addresses = '*'

# enable archive mode so that barman could do basebackup
archive_mode = on
archive_command = 'rsync -a %p $BARMAN_USER@$backup:$barman_incoming_dir/%f'
EOF
    chown postgres:postgres $custom_conf_file
    line_in_file "include $(basename $custom_conf_file)" $PGDATA/postgresql.conf

    # sync replication
    [[ -n $is_sync ]] && echo "synchronous_standby_names = 'app_$peer'" >> $custom_conf_file

    ##################################
    # run-time setting
    ##################################

    # need a running server to setup
    _pg_ctl start -w

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

    # create user for barman management tasks
    cat << EOF | _psql
DO
\$do\$
BEGIN
IF NOT EXISTS(
    SELECT
    FROM pg_catalog.pg_roles
    WHERE rolname = '$BARMAN_USER') THEN

    CREATE ROLE $BARMAN_USER WITH LOGIN SUPERUSER PASSWORD '$BARMAN_PASSWD';
END IF;
END
\$do\$;
EOF

    # create user for barman wal replication
    cat << EOF | _psql
DO
\$do\$
BEGIN
IF NOT EXISTS(
    SELECT
    FROM pg_catalog.pg_roles
    WHERE rolname = '$BARMAN_REPL_USER') THEN

    CREATE ROLE $BARMAN_REPL_USER WITH LOGIN SUPERUSER PASSWORD '$BARMAN_REPL_PASSWD';
END IF;
END
\$do\$;
EOF

    # stop server once finished
    _pg_ctl stop -w

    ##################################
    # access right setting
    ##################################
    line_in_file "host    replication      ${REPL_USER}                 ${peer_ipv4}/32         md5" "${PGDATA}"/pg_hba.conf
    line_in_file "host    replication      ${BARMAN_REPL_USER}          ${backup_ipv4}/32       md5" "${PGDATA}"/pg_hba.conf
    line_in_file "host    all              ${BARMAN_USER}               ${backup_ipv4}/32       md5" "${PGDATA}"/pg_hba.conf
    line_in_file "host    all              ${SUPER_USER}                0.0.0.0/0               md5" "${PGDATA}"/pg_hba.conf

    _pg_ctl start -w &> /dev/null
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

    _pg_ctl start &> /dev/null
}

usage_setup() {
    cat << EOF
Usgae: setup ROLE [options]
    
    setup primary           [-p|--peer STANDBY_HOST] [--sync|--async] [-B|--backup-host BACKUP_HOST]
    setup standby           [-p|--peer PRIMARY_HOST]
    setup backup            [-p|--peer PRIMARY_HOST] [-b|--backup-method [rsync|postgres]]

Roles:
    primary
    standby
    backup

Options:
    -h, --help
    [--sync|--async]                        Replication mode (by default: --async)
    -p, --peer HOST                         Peer host
    -B, --backup-host HOST                  Backup host, should be empty if role is "backup"
    -b, --backup-method [rsync|postgres]    Backup method used by barman:
                                            - rsync     : based on rsync and ssh, support incr backup
                                            - postgres  : based on pg_basebackup
                                            (it is set to "postgres" by default)
EOF
}

do_setup() {
    _pg_ctl status &>/dev/null && die "please stop pg first before any setup"

    role=$1
    shift
    case $role in
        primary)
            local peer backup sync_opt
            while :; do
                case $1 in
                    -h|--help)
                        usage_setup
                        exit 0
                        ;;
                    -p|--peer)
                        [[ -z $2 ]] && die "-p/--peer requires a non-empty option parameter"
                        peer=$2
                        shift
                        ;;
                    --peer=?*)
                        peer=${1#=*}
                        ;;
                    -B|--backup-host)
                        [[ -z $2 ]] && die "-B/--backup-host requires a non-empty option parameter"
                        backup=$2
                        shift
                        ;;
                    --backup-host=?*)
                        backup=${1#=*}
                        ;;
                    --sync)
                        sync_opt='--sync'
                        ;;
                    --async)
                        sync_opt="--async"
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
            [[ -z $peer ]] && die "missing param: peer"
            [[ -z $backup ]] && die "missing param: backup"
            do_setup_primary "$sync_opt" "$backup" "$peer"
            ;;

        standby)
            local peer
            while :; do
                case $1 in
                    -h|--help)
                        usage_setup
                        exit 0
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
            [[ -z $peer ]] && die "missing param: peer"
            do_setup_standby "$peer"
            ;;

        backup)
            local peer backup_method
            backup_method="postgres"
            while :; do
                case $1 in
                    -h|--help)
                        usage_setup
                        exit 0
                        ;;
                    -p|--peer)
                        [[ -z $2 ]] && die "-p/--peer requires a non-empty option parameter"
                        peer=$2
                        shift
                        ;;
                    --peer=?*)
                        peer=${1#=*}
                        ;;
                    -b|--backup-method)
                        [[ -z $2 ]] && die "-b/--backup-method requures a non-empty option parameter"
                        backup_method=$2
                        shift
                        ;;
                    --backup-method=*?)
                        backup_method=${1#*=}
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
            [[ -z $peer ]] && die "missing param: peer"
            case $backup_method in
                rsync)
                    ;;
                postgres)
                    ;;
                *)
                    die "unknwon backup_method: $backup_method"
                    ;;
            esac
            do_setup_backup -b $backup_method "$peer"
            ;;

        -h|--help)
            usage_setup
            exit 0
            ;;
        *)
            die "unknwon role: $role"
            ;;
    esac
}

##########################################################################
## action: promote
##########################################################################
#
#usage_promote() {
#    cat << EOF
#Usgae: promote [options]
#
#Options:
#    -h, --help
#EOF
#}
#
#do_promote() {
#    # FIXME: add some guard
#
#    _pg_ctl status &>/dev/null || die "only running standby is able to be promoted"
#
#    while :; do
#        case $1 in
#            -h|--help)
#                usage_promote
#                exit 0
#                ;;
#            --)
#                shift
#                break
#                ;;
#            *)
#                break
#                ;;
#        esac
#        shift
#    done
#
#    _pg_ctl promote || die "promote failed"
#
#    # wait until promoted cluster is running
#    if ! timeout 10 bash -c '{
#        while :; do
#            su postgres -c "psql -c \"select;\"" &> /dev/null && exit 0
#            sleep 1
#        done
#    }'; then
#        die "promoted cluster starting timeout"
#    fi
#
#    ensure_replication_slot
#}
#
##########################################################################
## action: rewind
##########################################################################
#
#usage_rewind() {
#    cat << EOF
#Usgae: rewind [options]
#
#Options:
#    -h, --help
#EOF
#}
#
#do_rewind() {
#    # FIXME: add some guard
#
#    _pg_ctl status &>/dev/null && _pg_ctl -w stop
#
#    while :; do
#        case $1 in
#            -h|--help)
#                usage_rewind
#                exit 0
#                ;;
#            --)
#                shift
#                break
#                ;;
#            *)
#                break
#                ;;
#        esac
#        shift
#    done
#
#    ##########################
#    # rewind
#    ##########################
#
#    # get peer identity
#    peer=$(cat "$PEER_HOST_RECORD")
#
#    # rewind data directory, which results into a nearly synced data directory as source cluster
#    # with the gap (WAL) defined as a backup label, which will be filled up once started.
#    _pg_rewind -D "$PGDATA" --source-server="postgresql://$SUPER_USER:$SUPER_PASSWD@$peer/postgres" || exit 1
#
#    # pg_rewind will sync target data dir with source server's data dir, hence the peer host record file will be overriden
#    # we should modify it to modify it
#    echo $peer > "$PEER_HOST_RECORD"
#
#    ##########################
#    # prepare recovery.conf
#    ##########################
#    # since we are going to act as a standby after start,
#    # we need to define a recovery.conf
#    cat << EOF > "$PGDATA"/recovery.conf
#standby_mode = 'on'
#recovery_target_timeline = 'latest'
#primary_conninfo = 'postgresql://$REPL_USER:$REPL_PASSWD@$peer/postgres?application_name=app_$(hostname)'
#primary_slot_name = '$REPL_SLOT'
#EOF
#    chown postgres:postgres "$PGDATA"/recovery.conf
#
#    _pg_ctl start > /dev/null
#}
#
##########################################################################
## action: sync_switch
##########################################################################
#usage_sync_switch() {
#    cat << EOF
#Usage: sync_switch [option] [primary_container] [sync|async]
#
#Description: switch replication mode between sync and async on primary.
#
#Options:
#    -h, --help
#EOF
#}
#
#do_sync_switch() {
#    while :; do
#        case $1 in
#            -h|--help)
#                usage_sync_switch
#                exit 0
#                ;;
#            --)
#                shift
#                break
#                ;;
#            *)
#                break
#                ;;
#        esac
#        shift
#    done
#    local mode="$1"
#
#    # get peer identity
#    peer=$(cat "$PEER_HOST_RECORD")
#    local repl_app="app_$peer"
#
#    case $mode in
#        sync)
#            echo "Replaced lines in postgresql.conf:"
#            sed -n "s/^#synchronous_standby_names.*/synchronous_standby_names = 'app_$peer'/gp" "$PGDATA"/postgresql.conf
#            sed -i "s/^#synchronous_standby_names.*/synchronous_standby_names = 'app_$peer'/g" "$PGDATA"/postgresql.conf
#            ;;
#        async)
#            echo "Replaced lines in postgresql.conf:"
#            sed -n 's/\(^synchronous_standby_names.*\)/#\1/gp' "$PGDATA"/postgresql.conf
#            sed -i 's/\(^synchronous_standby_names.*\)/#\1/g' "$PGDATA"/postgresql.conf
#            ;;
#    esac
#    # reload config for running primary
#    _pg_ctl status &>/dev/null && { _pg_ctl reload &> /dev/null || die "pg_ctl reload failed"; }
#}
