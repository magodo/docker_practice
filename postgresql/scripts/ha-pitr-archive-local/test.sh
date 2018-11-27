#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Tue 27 Nov 2018 06:19:28 PM CST
# Description:
#########################################################################

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYNAME="$(basename "${BASH_SOURCE[0]}")"
COMPOSE_DIR=$(readlink -e "$MYDIR")/../../DockerComposes/ha

# shellcheck disable=SC1090
. "$MYDIR"/../common.sh
# shellcheck disable=SC1090
. "$MYDIR"/../config.sh

setup() {
    pushd "$COMPOSE_DIR" > /dev/null
    docker-compose up -d
    popd > /dev/null
}

teardown() {
    pushd "$COMPOSE_DIR" > /dev/null
    docker-compose down
    popd > /dev/null
}

# Test recovery
#
#          A     B
# BASE-----+-----+------o1 (recover to A)                              1
#          |     |           C
#          +.....|.......----+---o2 (regret, recover to B)             2
#                |           |    
#                +...........|..------o3 (regret again, recover to C)  3
#                            | 
#                            +........----                             4

test_recovery() {

    setup

    trap teardown EXIT

    primary=ha_p1_1
    standby=ha_p2_1

    info "[1] Start HA"
    "${MYDIR}"/witness_main.sh start -i $primary $standby

    info "[2] Create table and insert 1 and 2"
    psql -d "host=$VIP user=$SUPER_USER password=$SUPER_PASSWD" -c "create table a (i int);"

    psql -d "host=$VIP user=$SUPER_USER password=$SUPER_PASSWD" -c "insert into a values(1);"
    sleep 1
    ai1="$(date)"
    echo "$ai1"

    psql -d "host=$VIP user=$SUPER_USER password=$SUPER_PASSWD" -c "insert into a values(2);"
    sleep 1
    ai2="$(date)"
    echo "$ai2"

    info "[3] Recover to point after insert 1"
    "${MYDIR}"/witness_main.sh recover -t "$ai1" $primary $standby || die "recover to A failed"

    [[ $(psql -A -d "host=$VIP user=$SUPER_USER password=$SUPER_PASSWD" -c "select * from a;" | tee -a /dev/stderr | wc -l) != 3 ]] && die "recover to A with unexpected result "
    [[ $(docker exec $primary psql -A postgres postgres -c "select * from a;" | tee -a /dev/stderr | wc -l) != 3 ]] && die "recover to A with unexpected result "
    [[ $(docker exec $standby psql -A postgres postgres -c "select * from a;" | tee -a /dev/stderr | wc -l) != 3 ]] && die "recover to A with unexpected result "

    # mimic a delay between recoveries, if no delay, bad thing happens!
    sleep 3

    info "[4] Insert 3"
    psql -d "host=$VIP user=$SUPER_USER password=$SUPER_PASSWD" -c "insert into a values(3);"
    sleep 1
    ai3="$(date)"
    echo "$ai3"

    info "[5] Recover to point after insert 2"
    "${MYDIR}"/witness_main.sh recover -t "$ai2" $primary $standby || die "recover to B failed"
    [[ $(docker exec $primary psql -A postgres postgres -c "select * from a;" | tee -a /dev/stderr | wc -l) != 4 ]] && die "recover to B with unexpected result "
    [[ $(docker exec $standby psql -A postgres postgres -c "select * from a;" | tee -a /dev/stderr | wc -l) != 4 ]] && die "recover to B with unexpected result "

    # mimic a delay between recoveries, if no delay, bad thing happens!
    sleep 3


    info "[6] Recover to point after insert 3"
    "${MYDIR}"/witness_main.sh recover -t "$ai3" $primary $standby || die "recover to C failed"
    [[ $(docker exec $primary psql -A postgres postgres -c "select * from a;" | tee -a /dev/stderr | wc -l) != 4 ]] && die "recover to C with unexpected result "
    [[ $(docker exec $standby psql -A postgres postgres -c "select * from a;" | tee -a /dev/stderr | wc -l) != 4 ]] && die "recover to C with unexpected result "
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
    recovery
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
        "recovery")
            test_recovery "$@"
            ;;
        *)
            die "Unknwon action: $action!"
            ;;
    esac
    exit 0
}

main "$@"
