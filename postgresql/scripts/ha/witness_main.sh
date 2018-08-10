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
EOF
}

do_start() {
    while :; do
        case $1 in
            -h|--help)
                usage_start
                exit 0
                ;;
            -i|--init)
                local init=1
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
        docker exec $primary "$SCRIPT_ROOT"/ha/main.sh setup -r primary -p $standby_host
        docker exec $primary "$SCRIPT_ROOT"/ha/main.sh start -w

        # setup standby needs a running primary (for basebackup)
        docker exec $standby "$SCRIPT_ROOT"/ha/main.sh setup -r standby -p $primary_host
        # here we doesn't wait because the semantic of "wait" in pg_ctl(v9.6) means that the server could accept connection,
        # which is not the case for the warm standby.
        docker exec $standby "$SCRIPT_ROOT"/ha/main.sh start
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
        *)
            die "Unknwon action: $action!"
            ;;
    esac
    exit 0
}

main "$@"
