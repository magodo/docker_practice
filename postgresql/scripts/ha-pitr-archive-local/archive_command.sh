#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Sun 30 Sep 2018 06:17:34 PM CST
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

[[ -n "$(find "$ARCHIVE_DIR_LOCAL" -name "*-$archive_file_name")" ]] || cp "$archive_file_path" "$ARCHIVE_DIR_LOCAL/$(date +%s)-$archive_file_name"

exit $?
