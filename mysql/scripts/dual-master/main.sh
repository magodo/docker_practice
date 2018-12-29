#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Thu 27 Dec 2018 04:55:15 PM CST
# Description:
#########################################################################

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"&& pwd)"
MYNAME="$(basename "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1090
. "$MYDIR"/common.sh
# shellcheck disable=SC1090
. "$MYDIR"/../config.sh


#########################################################################
# setup
#########################################################################
usage_setup() {
    cat << EOF
Usage: ./${MYNAME} [options]

Options:
    -h|--help			show this message
EOF
}

do_setup() {
    while :; do
        case $1 in
            -h|--help)
                usage_setup
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

    info "config server"
    docker exec "ha_p1_1" "$SCRIPT_ROOT/dual-master/agent.sh" config 1 || die "failed to config p1 as master"
    docker exec "ha_p2_1" "$SCRIPT_ROOT/dual-master/agent.sh" config 2 || die "failed to config p2 as slave"
    info "setup dual master"
    docker exec "ha_p1_1" "$SCRIPT_ROOT/dual-master/agent.sh" setup p2 || die "failed to setup master"
    docker exec "ha_p2_1" "$SCRIPT_ROOT/dual-master/agent.sh" setup p1 || die "failed to setup slave"
}

#########################################################################
# start
#########################################################################
usage_start() {
    cat << EOF
Usage: ./${MYNAME} [options]

Options:
    -h|--help			show this message
EOF
}

do_start() {
    while :; do
        case $1 in
            -h|--help)
                usage_start
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

    info "start server"
    docker exec "ha_p1_1" "$SCRIPT_ROOT/dual-master/agent.sh" start || die "failed to start p1"
    docker exec "ha_p2_1" "$SCRIPT_ROOT/dual-master/agent.sh" start || die "failed to start p2"
}

#########################################################################
# stop
#########################################################################
usage_stop() {
    cat << EOF
Usage: ./${MYNAME} [options]

Options:
    -h|--help			show this message
EOF
}

do_stop() {
    while :; do
        case $1 in
            -h|--help)
                usage_stop
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

    info "stop server"
    docker exec "ha_p1_1" "$SCRIPT_ROOT/dual-master/agent.sh" stop || die "failed to stop p1"
    docker exec "ha_p2_1" "$SCRIPT_ROOT/dual-master/agent.sh" stop || die "failed to stop p2"
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
    setup
    start
    stop
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
        "setup")
            do_setup "$@"
            ;;
        "start")
            do_start "$@"
            ;;
        "stop")
            do_stop "$@"
            ;;
        *)
            die "Unknwon action: $action!"
            ;;
    esac
    exit 0
}

main "$@"
