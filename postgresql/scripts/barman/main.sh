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
Usage: start [option] [barman_container] [primary_container] [standby_container]

Options:
    -h, --help
    -i, --init              setup barman, primary and standby before start
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

    local barman=$1
    local primary=$2
    local standby=$3
    [[ -z $barman ]] && die "missing param: barman"
    [[ -z $primary ]] && die "missing param: primary"
    [[ -z $standby ]] && die "missing param: standby"

    if [[ $init = 1 ]]; then
        barman_host=$(docker exec $barman hostname)
        primary_host=$(docker exec $primary hostname)
        standby_host=$(docker exec $standby hostname)
        docker exec $primary "$SCRIPT_ROOT"/barman/proxy.sh setup primary -p $standby_host ${sync_opt} -B $barman_host
        docker exec $standby "$SCRIPT_ROOT"/barman/proxy.sh setup standby -p $primary_host ${sync_opt}
        docker exec $barman "$SCRIPT_ROOT"/barman/proxy.sh setup backup -p $primary_host -b rsync
    else
        docker exec $primary "$SCRIPT_ROOT"/barman/proxy.sh start
        docker exec $standby "$SCRIPT_ROOT"/barman/proxy.sh start
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

    docker exec "$standby" "$SCRIPT_ROOT"/barman/proxy.sh promote
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

    docker exec "$failback_container" "$SCRIPT_ROOT"/barman/proxy.sh rewind
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
    docker exec "$primary" "$SCRIPT_ROOT"/barman/proxy.sh sync_switch $mode
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
    start               start primary and standby
    failover            remove primary from current network and promote current standby as new primary
    failback            revoke previous primary as standby following new primary
    sync_switch         switch replication mode between sync and async
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
        *)
            die "Unknwon action: $action!"
            ;;
    esac
    exit 0
}

main "$@"
