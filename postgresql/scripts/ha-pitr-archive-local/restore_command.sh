#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Sun 30 Sep 2018 06:20:22 PM CST
# Description:
#########################################################################

MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"&& pwd)"
MYNAME="$(basename "${BASH_SOURCE[0]}")"
# shellcheck disable=SC1090
. "$MYDIR"/../common.sh
# shellcheck disable=SC1090
. "$MYDIR"/../config.sh

archive_file_name="$1"
archive_file_path="$2"

real_archive_file="$(find "$ARCHIVE_DIR_LOCAL" -name "*-$archive_file_name")"
n_real_archive_file="$(wc -l <<<"$real_archive_file")"
if [[ $n_real_archive_file != 1 ]]; then
    die "incorrect real_archive_file amount: $n_real_archive_file"
fi

cp "$real_archive_file" "$archive_file_path"

exit $?
