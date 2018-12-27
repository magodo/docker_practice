#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Thu 27 Dec 2018 02:26:02 PM CST
# Description:
#########################################################################

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"&& pwd)"
MYNAME="$(basename "${BASH_SOURCE[0]}")"

. "$MYDIR"/common.sh
. "$MYDIR"/../config.sh

#########################################################################
# action: config
#########################################################################
usage_config() {
    cat << EOF
Usage: ./${MYNAME} [options] server_id

Options:
    -h|--help			show this message
Arguments:
    server_id
EOF
}

do_config() {
    while :; do
        case $1 in
            -h|--help)
                usage_config 
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

    server_id=$1

    # rm default auto.cnf which contains same server uuid on install
    rm "$DATA_DIR"/auto.cnf

    # server config
    cat << EOF > "$HOME/.my.cnf"
[mysqld]

log_bin             = $DATA_DIR/mysql-bin.log
log_bin_index       = $DATA_DIR/mysql-bin.log.index
relay_log           = $DATA_DIR/mysql-relay-bin
relay_log_index     = $DATA_DIR/mysql-relay-bin.index
log_slave_updates   = 1
server_id           = $server_id

bind_address = 0.0.0.0
EOF

    # start server
    do_start

    # create user
    cat << EOF | mysql
create user '$SUPER_USER'@'%' identified by '$SUPER_PASSWD';
grant all privileges on *.* to '$SUPER_USER'@'%' with grant option;
EOF
}

#########################################################################
# action: setup
#########################################################################
usage_setup() {
    cat << EOF
Usage: ./${MYNAME} [options] 

Options:
    -h|--help			show this message

Arguments:
    peer_hostname
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

    peer=$1
    local peer_ipv4="$(getent ahostsv4 $peer | grep "STREAM $peer" | cut -d' ' -f 1)"
    local my_ipv4="$(getent ahostsv4 "$(hostname)" | grep "STREAM" | grep -v $VIP | cut -d' ' -f 1)"

    master_status="$(mysql -h$peer_ipv4 -p$SUPER_PASSWD -u$SUPER_USER -B -r --vertical <<< "show master status")"
    master_bin_file="$(grep "File:" <<< $master_status | awk '{print $2}')"
    master_bin_pos="$(grep "Position:" <<< $master_status | awk '{print $2}')"


    cat << EOF | mysql
STOP SLAVE;
CHANGE MASTER TO master_host='$peer_ipv4', master_port=3306, master_user='$SUPER_USER', master_password='$SUPER_PASSWD', master_log_file='$master_bin_file', master_log_pos=$master_bin_pos;
START SLAVE;
EOF
}

#########################################################################
# action: start
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

    [[ -e /var/run/mysqld ]] || install -m 755 -o mysql -g root -d /var/run/mysqld
    mysqld_safe &>"$DATA_DIR"/start.log &

    for i in $(seq 1 10); do
        mysqladmin -s ping && break
        sleep 1 
    done
    if ! output=$(mysqladmin ping 2>&1); then
        error "$output"
        return 1
    fi
    return 0
}


#########################################################################
# action: stop
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

    if ! output=$(mysqladmin shutdown 2>&1); then
        error "$output"
        return 1
    fi
    return 0
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
    setup           Setup dual master DB cluster
    start           Start DB cluster
    stop            Stop DB cluster
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
        "config")
            do_config "$@"
            ;;
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
