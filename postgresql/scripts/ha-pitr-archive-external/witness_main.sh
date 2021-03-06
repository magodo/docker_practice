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
mkdir -p "$ARCHIVE_DIR"
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
                point_options=("-t" "$1")
                recovery_datetime=$1
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

    info "recover for primary db"
    docker exec "$primary" "$SCRIPT_ROOT"/ha/main.sh recover "${point_options[@]}" "$this_basebackup_dir" || die "failed to recover for primary"

    info "remake standby"
    primary_host=$(docker exec "$primary" hostname)
    # setup standby needs a running primary (for basebackup)
    docker exec $standby "$SCRIPT_ROOT"/ha/main.sh stop
    docker exec $standby "$SCRIPT_ROOT"/ha/main.sh setup -r standby -p "$primary_host"
    docker exec $standby "$SCRIPT_ROOT"/ha/main.sh start
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
    
    # insert a mapping from name -> timestamp
    # this is because when recovering by restore point, we still need the timestamp to find the nearest baseabckup
    docker exec ha_p0_1 bash -c "echo $name,$(date +%s) >> $RUNTIME_INFO_RECOVERY_POINT_MAP_FILE"
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
    create_recovery_point          create a recovery point (used to do pitr later)
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
        *)
            die "Unknwon action: $action!"
            ;;
    esac
    exit 0
}

main "$@"
