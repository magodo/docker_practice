#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Fri 06 Jul 2018 04:48:49 PM CST
# Description:
#########################################################################

export PGDATA="/var/lib/pgsql/9.6/data"
export PATH="/usr/pgsql-9.6/bin:$PATH"

die() {
    echo "$1" >&2
    exit 1
}

