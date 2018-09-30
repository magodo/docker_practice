#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Tue 07 Aug 2018 07:38:49 PM CST
# Description:
#########################################################################

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"&& pwd)"
MYNAME="$(basename "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1090
. "$MYDIR"/action.sh

usage() {
    cat << EOF
Usage: ./${MYNAME} [option] [action]

Options:
    -h, --help

Actions:
    setup           Setup DB cluster, as either primary or standby           
    start           Start DB cluster
    stop            Stop DB cluster
    promote         Promote a standby into primary
    rewind          Rewind a previous primary into standby following the new primary 
    sync_switch     Switch replication mode between sync and async on primary
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
        "promote")
            do_promote "$@"
            ;;
        "rewind")
            do_rewind "$@"
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
        "nearest_basebackup")
            do_nearest_basebackup "$@"
            ;;
        *)
            die "Unknwon action: $action!"
            ;;
    esac
    exit 0
}

main "$@"
