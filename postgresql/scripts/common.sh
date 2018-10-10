#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Wed 11 Apr 2018 01:19:18 PM CST
# Description:
#########################################################################

#########################################################################
# LOG
#########################################################################

log() {
    level=$1
    shift
    n_arg=$#
    if test -t 1; then
        # see if it supports colors...
        ncolors=$(tput colors)

        if test -n "$ncolors" && test $ncolors -ge 8; then
            bold="$(tput bold)"
            underline="$(tput smul)"
            standout="$(tput smso)"
            normal="$(tput sgr0)"
            black="$(tput setaf 0)"
            red="$(tput setaf 1)"
            green="$(tput setaf 2)"
            yellow="$(tput setaf 3)"
            blue="$(tput setaf 4)"
            magenta="$(tput setaf 5)"
            cyan="$(tput setaf 6)"
            white="$(tput setaf 7)"

            declare -A level_color
            level_color=([debug]="$normal" [info]="$cyan" [warn]="$yellow" [error]="$red")
            output_fd=([debug]=1 [info]=1 [warn]=2 [error]=2)
        fi
    fi
    if [[ $n_arg = 0 ]]; then
        { echo -n ${level_color[$level]}; cat; echo -n ${normal}; }
    else
        { echo -n ${level_color[$level]}; echo "$*"; echo -n ${normal}; }
    fi
}

error() {
    # $@ can't be quoted, otherwise it will be passed as an empty string argument to log
    log error "$@"
}

warn() {
    log warn "$@"
}

info() {
    log info "$@"
}

debug() {
    log debug "$@"
}

#########################################################################
# HELPERS
#########################################################################

die() {
    error "$@" >&2
    exit 1
}

run_as_postgres() {
    pushd /tmp > /dev/null
    cmd=()
    for i in "$@"; do
        cmd+=(\'"$i"\')
    done
    su postgres -c "${cmd[*]}"
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

_pg_rewind() {
    run_as_postgres pg_rewind "$@"
}

_pg_basebackup() {
    run_as_postgres pg_basebackup "$@"
}

_repmgr() {
    run_as_postgres repmgr "$@"
}

##
# ensure specified line in specified file
# $1: line
# $2: file
line_in_file() {
    line="$1"
    file="$2"
    if ! grep -qE "^$line\$" "$file"; then
        echo "$line" >> "$file"
    fi
}

#################################################################################################################################################################
# SEARCH FOR WAL BY DATETIME
#################################################################################################################################################################

# specify a datetime: t ($1) and a wal segment: wal ($2), check whether:
# - t is earlier than the first commit timestamp inside wal                              : echo -1
# - t is later than the last commit timestamp inside wal                                 : echo 1|ts_diff
# - t is later than the first commit timestamp and earlier than the last commit timestamp: echo 0
# - wal has no commit timestamp                                                          : echo nothing

compare_wal_timestamp() {
    target_timestamp="$(date -d "$1" +%s)"
    wal_to_parse="$2"

    KEY_WORD="desc: COMMIT "

    local timestamps
    timestamps="$(pg_xlogdump -r Transaction "$wal_to_parse" | grep "$KEY_WORD" | sed "s/.*$KEY_WORD//" | sed "s/;.*//")"

    # no commit in this wal, just return
    if [[ -z ${timestamps} ]]; then
        return
    fi

    local first_ts last_ts
    first_ts=$(date -d "$(head -n 1 <<< "$timestamps")" +%s)
    last_ts=$(date -d "$(tail -n 1 <<< "$timestamps")" +%s)

    if [[ "$target_timestamp" -gt "$last_ts" ]]; then
        echo "1|$(bc -l <<<"$target_timestamp - $last_ts")"
    elif [[ "$target_timestamp" -lt "$first_ts" ]]; then
        echo "-1"
    else
        echo 0
    fi
}

# binary search for a timestamp: t ($1) among wal segments inside a directory: dir ($2), to find the wal segment 
# whoes commit timestamps either:
# - cover t or
# - least earlier than t or
# - least later than t (in case of there is no wal earlier than t)
# in other word, this wal is the fisrt wal should be kept to guarantee t is able to be recovered via PITR.
# NOTE: 
# - if all the wal segments have no commit timestamp, this function echo nothing and return 1

#################
# ATTENTION: THIS IS BUGGY!!!
#################

binary_search_broken() {
    target="$1"
    # shellcheck disable=SC2206
    sorted_items=(${@:2})
    lenth=${#sorted_items[@]}

    start=0
    end=$((lenth - 1))
    while [[ $start -le $end ]]; do
        middle=$((start + ( end - start ) / 2))
        item_at_middle=${sorted_items[$middle]}
        result=$(compare_wal_timestamp "$target" "$item_at_middle")
        case "$result" in
            -1)
                end=$((middle-1))
                last_result="$result"
                ;;
            1*)
                start=$((middle+1))
                last_result="$(cut -d "|" -f 2 <<< "$result")"
                ;;
            0)
                echo "${sorted_items[$middle]}"
                return
                ;;
            *)
                # no time info exists in current wal, we will shift the
                # sorted list to left by one item
                cur_length=${#sorted_items[@]}
                real_end=$((cur_length-1))
                sorted_items=("${sorted_items[@]: 0: $((middle)) }" "${sorted_items[@]: $((middle - real_end)): $((real_end - middle))}")
                ((end--))
                ;;
        esac
    done

    # can't find a match until end, then we should return:
    # 1. the item near target
    # 2. whether the item is greater or lesser
    case "$last_result" in
        -1)
            index="$start"
            # if target is less than the first timestamp in the indexed item,
            # then we try to access the item before it, whose last timestamp should be less than target
            if [[ $index -gt 0 ]]; then
                ((index--))
            fi
            ;;
        1)
            index="$end"
            ;;
        *)
            # no wal segments contain any commit timestamp
            return 1
            ;;
    esac
    echo "${sorted_items[$index]}"
}

# search from the first wal to end, compare the specified time (t) with each wal's commit time, to find the FIRST wal segment,
# whose commit timestamp either:
# - cover t or
# - FIRST least earlier than t
# in other word, this wal is the fisrt wal should be kept to guarantee t is able to be recovered via PITR.
# NOTE: 
# - if all the wal segments have no commit timestamp or later than t, this function echo nothing and return 1

linear_search() {
    target_time="$1"
    # shellcheck disable=SC2206
    sorted_wals=(${@:2})
    
    local first_least_earlier_wal ts_min_diff

    for wal in "${sorted_wals[@]}"; do
        result=$(compare_wal_timestamp "$target_time" "$wal")
        case "$result" in
            -1)
                # all wal are later than target time
                [[ -z $first_least_earlier_wal ]] && return 1
                echo "$first_least_earlier_wal"
                return
                ;;
            1*)
                ts_diff="$(cut -d "|" -f 2 <<< "$result")"
                if [[ -z $ts_min_diff ]] || [[ $ts_diff -lt $ts_min_diff ]]; then
                    ts_min_diff="$ts_diff"
                    first_least_earlier_wal="$wal"
                fi
                ;;
            0)
                echo "$wal"
                return
                ;;
            *)
                # no time info exists in current wal, just skip
                ;;
        esac
    done
}

search_wal_by_datetime() {
    t="$1"
    dir="$2"

    wals=()
    for f in "$dir"/*; do
        if [[ $(basename "$f") != *.* ]]; then
            wals+=("$f")
        fi
    done
    linear_search "$t" "${wals[@]}"
}

#################################################################################################################################################################
