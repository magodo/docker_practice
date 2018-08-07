#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Fri 03 Aug 2018 10:29:58 AM CST
# Description: 
# Precondition:
# - PGDATA env.var should be set
#########################################################################

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYNAME=$(basename "${BASH_SOURCE[0]}")
source $MYDIR/colorfy_log.sh

die() {
    error "$1" >&2
    exit 1
}

run_as_postgres() {
    pushd /tmp > /dev/null
    cmd=("$1")
    shift
    for i in "$@"; do
        cmd+=(" \"$i\"")
    done
    su postgres -c "eval ${cmd[*]}"
    ret=$?
    popd > /dev/null
    return $ret
}

_psql() {
    run_as_postgres psql "$@"
}

_pg_ctl() {
    run_as_postgres pg_ctl "$@"
}

# setup continuous archiving before DB is started
setup_continuous_archive() {
    sed -i "s;^#wal_level = minimal;wal_level = replica;" "${PGDATA}"/postgresql.conf
    sed -i "s;^#archive_mode = off;archive_mode = on;" "${PGDATA}"/postgresql.conf
    #sed -i "s;^#archive_timeout = 0;archive_timeout = 10;" "${PGDATA}"/postgresql.conf # force a logfile segment every 10 second
    local archive_cmd="test ! -f $BACKUP_ARCHIVE_DIR/%f \&\& cp %p $BACKUP_ARCHIVE_DIR/%f"
    sed -i "s;^#archive_command = '';archive_command = '$archive_cmd';" "${PGDATA}"/postgresql.conf
}

ensure_backup_dir() {
    [[ -d "$BACKUP_BASEBACKUP_DIR" ]] || { mkdir "$BACKUP_BASEBACKUP_DIR" && chown postgres:postgres "$BACKUP_BASEBACKUP_DIR"; }
    [[ -d "$BACKUP_ARCHIVE_DIR" ]] || { mkdir "$BACKUP_ARCHIVE_DIR" && chown postgres:postgres "$BACKUP_ARCHIVE_DIR"; }
}

manipulate_db() {
    out=$(_psql -t -c "select tablename from pg_tables where tablename='foo'")
    [[ -z $out ]] && _psql -c "create table foo(i timestamp);"
    local i=0
    while (( $i < 10 )); do
        (( i++ ))
        _psql -c "insert into foo values(LOCALTIMESTAMP);"
        sleep 1
    done
}

do_start() {
    ensure_backup_dir
    setup_continuous_archive
    _pg_ctl start
}

do_stop() {
    _pg_ctl stop
}

do_basebackup() {
    id=$(uuid)
    while [[ -d "$BACKUP_BASEBACKUP_DIR/$id" ]]; do
        id=$(uuid)

    done

    OLD_IFS="$IFS"
    IFS=""
    local counter=0

    ## test purpose
    #(
    #    echo "create table y${id:0:5}(s varchar)" | _psql
    #)

    local log_file="/tmp/$id"
    {
        # 1. start backup 
        # 1.5 wait start backup finish
        # 2. backup data dir
        # 3. stop backup
        # 4. write output of stop backup function into backup lable file (and table spacemap file)
        # 5. create a restore point named after backup_id

        echo "select pg_start_backup('$id', false, false);"
        echo "select 'start_backup_ok';"

        ## test purpose
        #(
        #    echo "create table x${id:0:5}(s varchar)" | _psql &> /dev/null
        #)

        # backup data directory (via rsync)
        while ! { [[ -f "$log_file" ]] && grep -q "start_backup_ok" "$log_file"; }; do
            sleep 1
        done
        rsync --delete -azc "$PGDATA/" "$BACKUP_BASEBACKUP_DIR/$id" &> /dev/null

        echo "select * from pg_stop_backup(false);"
    } | _psql -A 2>/dev/null | stdbuf -o0 tee -a "$log_file" | sed -n '1,/lsn|labelfile|spcmapfile/!p' | while read -r -d "|" line; do
        case $counter in
            1)
                echo "$line" > "$BACKUP_BASEBACKUP_DIR/$id/backup_label"
                chown postgres:postgres "$BACKUP_BASEBACKUP_DIR/$id/backup_label"
                ;;
            2)
                echo "$line" > "$BACKUP_BASEBACKUP_DIR/$id/table_spacemap"
                chown postgres:postgres "$BACKUP_BASEBACKUP_DIR/$id/table_spacemap"
                ;;
        esac
        ((counter++))
    done
    echo "select pg_create_restore_point('${id}')" | _psql >/dev/null
    IFS="$OLD_IFS"
    echo "$id"
}

do_recover() {
    id=$1     

    # ensure the specified basebackup dir exists
    basebackup_dir="$BACKUP_BASEBACKUP_DIR/$id" 
    [[ ! -d "$basebackup_dir" ]] && die "No basebackup found in: $basebackup_dir"

    # stop server if running
    _pg_ctl status && _pg_ctl stop

    # fill PGDATA with basebackup (with some exclusions)
    rsync --delete -azc --exclude "pg_replslot/*" \
                        --exclude "pg_xlog/*" \
                        --exclude "postmaster.pid" \
                        --exclude "postmaster.opts" \
                        "$basebackup_dir/" "$PGDATA"

    # create an recovery.conf file in
    cat << EOF > $PGDATA/recovery.conf
restore_command = 'cp $BACKUP_ARCHIVE_DIR/%f %p'
recovery_target_name = '${id}'
EOF
    chown postgres:postgres $PGDATA/recovery.conf

    diff -r $PGDATA $basebackup_dir > /tmp/diff.log
    # start server
    _pg_ctl start
}

action_start() {
    while [[ -n ${1+x} ]]; do
        case $1 in
            -h|--help)
                usage "start"
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
    done

    do_start
}

action_stop() {
    while [[ -n ${1+x} ]]; do
        case $1 in
            -h|--help)
                usage "stop"
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
    done

    do_stop
}

action_basebackup() {
    while [[ -n ${1+x} ]]; do
        case $1 in
            -h|--help)
                usage basebackup
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
    done

    do_basebackup
}

action_recover() {
    while [[ -n ${1+x} ]]; do
        case $1 in
            -h|--help)
                usage recover
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
    done
    local backup_id=$1
    [[ -z ${backup_id} ]] && die "Please secify backup_id!"
    do_recover $backup_id
}

usage() {
    case $1 in

        start)
            cat << EOF
./${MYNAME} backup_dir start [options]

Description

    Setup continuous archiving and start pg.
EOF
            ;;

        stop)
            cat << EOF
./${MYNAME} backup_dir stop [options]

Description

    Stop pg.
EOF
            ;; 

        basebackup)
            cat << EOF
./${MYNAME} backup_dir basebackup [options]
EOF
            ;;

        recover)
            cat << EOF
./${MYNAME} backup_dir recover id [options]

id: basebackup id
EOF
            ;;

        *)
            cat << EOF
./${MYNAME} [options] backup_dir action

action should be one of below:
- start     :   setup continuous archiving and start pg
- stop      :   just stop pg
- basebackup:   do a basebackup
- recover   :   do a fresh recovery (could be run on a new db instance or the same very instance)
EOF
            ;;
    esac
}

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

BACKUP_DIR="$1"
[[ -z $BACKUP_DIR ]] && die "Please specify backup directory for both base backup and WAL archive!"
BACKUP_BASEBACKUP_DIR="${BACKUP_DIR}/basebackup"
BACKUP_ARCHIVE_DIR="${BACKUP_DIR}/archive"

ACTION="$2"
shift 2

case "$ACTION" in
    start)
        action_start "$@"
        ;;
    stop)
        action_stop "$@"
        ;;
    basebackup)
        action_basebackup "$@"
        ;;
    recover)
        action_recover "$@"
        ;;
    *)
        die "Unknown action: $ACTION!"
        ;;
esac
