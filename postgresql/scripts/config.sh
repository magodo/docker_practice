#!/bin/bash

#########################################################################
# Author: Zhaoting Weng
# Created Time: Fri 06 Jul 2018 04:52:23 PM CST
# Description:
#########################################################################


#########################################################################
# Config shared between scripts and docker-compose
#########################################################################
VIP=172.255.255.254
SUBNET=172.255.255.0/24
SCRIPT_ROOT=/opt/scripts
HA_SCRIPT_ROOT=/opt/scripts/ha
BACKUP_ROOT=/mnt/backup
ARCHIVE_DIR=$BACKUP_ROOT/archive
ARCHIVE_DIR_LOCAL=$PGDATA/archive
BASEBACKUP_DIR=$BACKUP_ROOT/basebackup

# store runtime info, should be replaced by DB
RUNTIME_INFO_RECOVERY_POINT_MAP_FILE=$BACKUP_ROOT/pg_recovery_point_mapping.txt

# restore each recovery time, the line # is the time line ID (starts from 1)
RUNTIME_INFO_RECOVERY_HISTORY_FILE=$BACKUP_ROOT/pg_recovery_history.txt

#########################################################################
# REPLICATION
#########################################################################
REPL_USER=repl_user
REPL_PASSWD=123
REPL_SLOT=repl_slot

#########################################################################
# SUPER (this is needed for pg_rewind)
#########################################################################
SUPER_USER=postgres
SUPER_PASSWD=123

#########################################################################
# COMMON
#########################################################################
PEER_HOST_RECORD="$PGDATA/peer"

#########################################################################
# BARMAN
#########################################################################
# barman is used for management, it should be created at pg node
BARMAN_USER=barman
BARMAN_PASSWD=123
# barman repl is used for wal streaming, it should be created at pg node
BARMAN_REPL_USER=barman_repl
BARMAN_REPL_PASSWD=123
