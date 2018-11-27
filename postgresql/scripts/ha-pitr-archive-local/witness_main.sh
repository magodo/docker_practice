#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Thu 09 Aug 2018 08:26:13 PM CST
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
Usage: start [option] [primary_container] [standby_container]

Options:
    -h, --help
    -i, --init              setup primary and standby before start
    -s, --sync              use sync replication instead of async
EOF
}

do_start() {
    local sync_opt="--async"
    while :; do
        case $1 in
            -h|--help)
                usage_start
                exit 0
                ;;
            -i|--init)
                local init=1
                ;;
            -s|--sync)
                sync_opt="--sync"
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

    local primary=$1
    local standby=$2
    [[ -z $primary ]] && die "missing param: primary"
    [[ -z $standby ]] && die "missing param: standby"

    if [[ $init = 1 ]]; then
        primary_host=$(docker exec $primary hostname)
        standby_host=$(docker exec $standby hostname)
        docker exec ha_p0_1 bash -c "$(cat << EOF
mkdir -p "$BASEBACKUP_DIR"
chown -R postgres:postgres "$BACKUP_ROOT"
EOF
)"
        docker exec $primary "$SCRIPT_ROOT"/ha/main.sh setup -r primary -p $standby_host ${sync_opt}
        docker exec $primary "$SCRIPT_ROOT"/ha/main.sh start -w

        # setup standby needs a running primary (for basebackup)
        docker exec $standby "$SCRIPT_ROOT"/ha/main.sh setup -r standby -p $primary_host
        # here we doesn't wait because the semantic of "wait" in pg_ctl(v9.6) means that the server could accept connection,
        # which is not the case for the warm standby.
        docker exec $standby "$SCRIPT_ROOT"/ha/main.sh start

        # do a initial basebackup, so that we can do pitr from beginning
        do_basebackup "$primary"
    else
        docker exec $primary "$SCRIPT_ROOT"/ha/main.sh start
        docker exec $standby "$SCRIPT_ROOT"/ha/main.sh start
    fi
}

#########################################################################
# action: failover
#########################################################################
usage_failover() {
    cat << EOF
Usage: failover [option] [primary_container] [standby_container]

Description: configure network so that VIP is bound to standby, then promote standby as primary.

Options:
    -h, --help
    -p, --project           docker-compose project
EOF
}

do_failover() {
    local project
    while :; do
        case $1 in
            -h|--help)
                usage_failover
                exit 0
                ;;
            -p|--project)
                project=$2
                shift
                ;;
            --project=?*)
                project=${1#*=}
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

    local primary=$1
    local standby=$2
    [[ -z $project ]] && die "missing param: project"
    [[ -z $primary ]] && die "missing param: primary"
    [[ -z $standby ]] && die "missing param: standby"

    docker network disconnect ${project}_external_net "$primary"
    docker network connect --ip "$VIP" ${project}_external_net "$standby"

    docker exec "$standby" "$SCRIPT_ROOT"/ha/main.sh promote
}

#########################################################################
# action: failback
#########################################################################
usage_failback() {
    cat << EOF
Usage: failback [option] [failbackup_container]

Options:
    -h, --help
EOF
}

do_failback() {
    local project
    while :; do
        case $1 in
            -h|--help)
                usage_failback
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

    local failback_container=$1
    
    [[ -z $failback_container ]] && die "missing param: failback_container"

    docker exec "$failback_container" "$SCRIPT_ROOT"/ha/main.sh rewind
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

    local primary=$1
    local mode=$2
    
    [[ -z $primary ]] && die "missing param: primary_container"
    [[ -z $mode ]] && die "missing param: repl_mode"
    docker exec "$primary" "$SCRIPT_ROOT"/ha/main.sh sync_switch $mode
}

#########################################################################
# basebackup
#########################################################################
usage_basebackup() {
    cat << EOF
Usage: basebackup [option] [primary_container]

Description: make a basebackup on primary cluster

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

    local primary=$1

    docker exec "$primary" "$SCRIPT_ROOT"/ha/main.sh basebackup
}

#########################################################################
# recover
#########################################################################
usage_recover() {
    cat << EOF
Usage: recover [option] [-t datetime | -p recover_point] [primary_container] [standby_container]

Description: recover to a specified datetime or recovery point (created beforehead)

Options:

    -h, --help
    -t datetime                     recover to datetime specified
    -p recover_point                recover to recovery point specified (which is created before head)
EOF
}

do_recover() {
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
                # change datetime to pg timestamp format, also we make use of the calling system's timezone info
                # to deduce timezone, otherwise it might (likely) be an un-initialized timezone in docker env.
                recovery_datetime="$(date -d"$1" "+%F %T %:z")"
                point_options=("-t" "$recovery_datetime")
                ;;
            -p)
                shift
                point_options=("-p" "$1")
                recovery_point=$1
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    local primary=$1
    local standby=$2

    if [[ -z "$recovery_datetime" ]] && [[ -z "$recovery_point" ]]; then
        die "missing paramter: -t / -p"
    fi

    # do pitr for both underlying db
    info "find nearest basebackup..."
    this_basebackup_dir="$(docker exec ha_p0_1 "$SCRIPT_ROOT"/ha/main.sh nearest_basebackup "${point_options[@]}")" || die  "can't find any basebackup earliear than specified recover time/point: ${point_options[*]}"
    info "nearest basebackup is: $this_basebackup_dir"

    info "recover both primary and standby"

    # Do a graceful stop for HA, i.e., stop primary first, then stop standby. 
    # In "most" case, it ensure the LSN of both are the same, and the WAL switch event
    # of primary is sent to standby also, resulting into standby also switch the WAL,
    # in other words, the archive of both are the same, then.
    # The exception, see comment below...
    docker exec "$primary" "$SCRIPT_ROOT/ha/main.sh" stop
    docker exec "$standby" "$SCRIPT_ROOT/ha/main.sh" stop

    # In case last recovery is just finished, then user made another recovery(in 3 seconds), the stops above is not guaranteed to do a wal switch on standby.
    # I don't know the reason. But we definitely need to work around it here. The solution would be to sync the missing wal on standby from 
    # primary, since each db is using its own wal and the primary's wal is always the latest one.
    # Also suppose currently the standby is a bit lag against primary, it will need all the wal to do recovery.
    # NOTE: this method is ugly because if the wal size is big, then it takes time!

    #tempdir="$(docker exec "ha_p0_1" mktemp -d -p "$BACKUP_ROOT")"
    #PGDATA=$(docker exec "$primary" bash -c 'eval "echo $PGDATA"')
    #docker exec "$primary" rsync -avz --delete "$PGDATA/archive/" "$tempdir"
    #docker exec "$standby" rsync -avz --delete "$tempdir/" "$PGDATA/archive"
    #docker exec "ha_p0_1" rm -rf "$tempdir"
    
    # we have to restart primary because we have to restart standby, then they are in the same LSN
    ( docker exec -e LOG_PREFIX="primary: " "$primary" "$SCRIPT_ROOT"/ha/main.sh recover "${point_options[@]}" "$this_basebackup_dir" && \
      docker exec "$primary" "$SCRIPT_ROOT"/ha/main.sh stop && \
      docker exec "$primary" "$SCRIPT_ROOT"/ha/main.sh start -w \
    ) &
    pid_1=$!

    ( docker exec -e LOG_PREFIX="standby: " "$standby" "$SCRIPT_ROOT"/ha/main.sh recover "${point_options[@]}" "$this_basebackup_dir" && \
      primary_host=$(docker exec "$primary" hostname) && \
      docker exec "$standby" "$SCRIPT_ROOT"/ha/main.sh stop && \
      docker exec "$standby" "$SCRIPT_ROOT"/ha/main.sh setup -r standby -p "$primary_host" --no-basebackup && \
      docker exec "$standby" "$SCRIPT_ROOT"/ha/main.sh start -w \
    ) &
    pid_2=$!

    wait $pid_1 || die "failed to recover for primary"
    wait $pid_2 || die "failed to recover for standby"
}

#########################################################################
# create_recovery_point
#########################################################################

usage_create_recovery_point() {
    cat << EOF
Usage: create_recovery_point [option] [point_name]

Description: create a recovery point (to be used by pitr)

Options:

    -h, --help
EOF
}

do_create_recovery_point() {
    while :; do
        case $1 in
            -h|--help)
                usage_create_recovery_point
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

    local name=$1
    psql -d "postgresql://$SUPER_USER:$SUPER_PASSWD@$VIP" -c "select pg_create_restore_point('$name')" || die "failed to create restore point"

    timeline="$(psql -d "user=$SUPER_USER password=$SUPER_PASSWD host=$VIP dbname=postgres replication=database" -c "IDENTIFY_SYSTEM;" -A -t -F' ' | awk '{print $2}')"
    info "current timeline: $timeline"

    # insert a mapping from name -> timestamp
    # this is because when recovering by restore point, we still need the timestamp to find the nearest baseabckup
    docker exec ha_p0_1 bash -c "echo $name,$timeline,$(date +%s) >> $RUNTIME_INFO_RECOVERY_POINT_MAP_FILE"
}

#########################################################################
# tx_read_only 
#########################################################################
usage_tx_read_only() {
    cat << EOF
Usage: tx_read_only [option] primary_container

Options:
    -h|--help			show this message
    -s|-S               turn on/off transaction read-only mode
EOF
}

do_tx_read_only() {
    while :; do
        case $1 in
            -h|--help)
                usage_tx_read_only
                exit 1
                ;;
            -s)
                mode=on
                ;;
            -S)
                mode=off
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

    local primary_container=$1
    [[ -z $mode ]] && die "please specify -s/-S option!"
    docker exec "$primary_container" "$SCRIPT_ROOT"/ha/main.sh tx_read_only "$mode"
}

#########################################################################
# role_switch
#########################################################################
usage_role_switch() {
    cat << EOF
Usage: role_switch [option] primary_container standby_container

Options:
    -h|--help			show this message
EOF
}

do_role_switch() {
    while :; do
        case $1 in
            -h|--help)
                usage_role_switch
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

    local primary_container=$1
    local standby_container=$2

    # set primary as read-only
    do_tx_read_only -s "$primary_container"

    # wait standby sync with primary
    primary_last_lsn=$(docker exec "$primary_container" su postgres -c 'psql -A -c "SELECT pg_current_xlog_location();"' | sed -n 2p)

    retry=3
    while [[ $retry -gt 0 ]]; do
        lag=$(docker exec "$standby_container" su postgres -c "psql -A -c \"SELECT pg_xlog_location_diff('$primary_last_lsn', (SELECT pg_last_xlog_replay_location())) AS lag\"" | sed -n 2p)
        [[ $lag -eq 0 ]] && break
        ((retry--))
        sleep 1
    done

    if [[ ! $lag -eq 0 ]]; then
        # reset primary back to read-write
        do_tx_read_only -S "$primary_container"
        die "can't switch role, because standby is not sync with primary"
    fi

    # promote and rewind
    do_failover -p ha "$primary_container" "$standby_container"
    do_failback "$primary_container"
}

#########################################################################
# main
#########################################################################

usage() {
    cat << EOF
Usage: ./${MYNAME} [option] [action]

Options:
    -h, --help

Actions:
    start                           start primary and standby
    failover                        remove primary from current network and promote current standby as new primary
    failback                        revoke previous primary as standby following new primary
    sync_switch                     switch replication mode between sync and async
    basebackup                      do basebackup
    recover                         point-in-time recovery
    create_recovery_point           create a recovery point (used to do pitr later)
    tx_read_only                    set/reset transaction read-only mode in cluster-wide
    role_switch                     siwtch primary and standby roles
EOF
}


main() {
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

    local action="$1"
    shift
    
    case $action in
        "start")
            do_start "$@"
            ;;
        "failover")
            do_failover "$@"
            ;;
        "failback")
            do_failback "$@"
            ;;
        "sync_switch")
            do_sync_switch "$@"
            ;;
        "basebackup")
            do_basebackup "$@"
            ;;
        "recover")
            do_recover "$@"
            ;;
        "create_recovery_point")
            do_create_recovery_point "$@"
            ;;
        "tx_read_only")
            do_tx_read_only "$@"
            ;;
        "role_switch")
            do_role_switch "$@"
            ;;
        *)
            die "Unknwon action: $action!"
            ;;
    esac
    exit 0
}

main "$@"
