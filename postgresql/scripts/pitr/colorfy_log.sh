#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Wed 11 Apr 2018 01:19:18 PM CST
# Description:
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
        { echo -n ${level_color[$level]}; cat; echo -n ${normal}; } >&"${output_fd[$level]}"
    else
        { echo -n ${level_color[$level]}; echo "$*"; echo -n ${normal}; } >&"${output_fd[$level]}"
    fi
}

error() {
    # $@ can't be quoted, otherwise it will be passed as an empty string argument to log
    log error $@
}

warn() {
    log warn $@
}

info() {
    log info $@
}

debug() {
    log debug $@
}
