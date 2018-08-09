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
# action: failover
#########################################################################
usage_failover() {
    cat << EOF
Usage: failover [option] [primary_container] [standby_container]

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

    local pre_primary=$1
    local pre_standby=$2
    [[ -z $project ]] && die "missing param: project"
    [[ -z $pre_primary ]] && die "missing param: primary"
    [[ -z $pre_standby ]] && die "missing param: standby"

    docker network disconnect ${project}_external_net "$pre_primary"
    docker network connect --ip "$VIP" ${project}_external_net "$pre_standby"

    docker exec "$pre_standby" "$SCRIPT_ROOT"/async/main.sh promote
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
