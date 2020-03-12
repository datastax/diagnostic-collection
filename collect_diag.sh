#!/usr/bin/env bash
#
# File: collect_diag.sh
#
# Created: Friday, May 31 2019
# Modified: $Format:%cD$ 
# Hash: $Format:%h$
#
# This script collects diagnostic from multiple nodes of cluster
##

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "You need to use Bash 4 or higher, but you have ${BASH_VERSION}"
    exit 1
fi

function usage() {
    echo "Usage: $0 -t <type> [options] [path]"
    echo " ----- Required --------"
    echo "   -t type -  valid choices are \"coss\", \"ddac\", \"dse\" "
    echo " ----- Options --------"
    echo "   -c cqlsh_options - e.g \"-u user -p password\" etc. Ensure you enclose with \""
    echo "   -d dsetool_options - options to pass to dsetool. Syntax the same as \"-c\""
    echo "   -f file_name - file with list of hosts where to execute command (default - try to get list from 'nodetool status')"
    echo "   -i insights - collect only data for DSE Insights"
    echo "   -I insights_dir - directory that contains insights .gz files"
    echo "   -n nodetool_options - options to pass to nodetool. Syntax the same as \"-c\""
    echo "   -o output_dir - where to put resulting file (default: $OUT_DIR)"
    echo "   -p pid - PID of DSE or DDAC process"
    echo "   -r - remove collected files after generation of resulting tarball"
    echo "   -s ssh/scp options - options to pass to SSH/SCP"
    echo "   -u timeout - timeout for SSH in seconds (default: $TIMEOUT)"
    echo "   -m collection_mode - light, normal, extended. Default: normal"
    echo "   -v - verbose output"
    echo "   path - top directory of COSS, DDAC or DSE installation (for tarball installs)"
}

function check_type {
    if [ "$TYPE" != "ddac" ] && [ "$TYPE" != "coss" ] && [ "$TYPE" != "dse" ]; then
        usage
        exit 1
    fi
}

# ----------
# Setup vars
# ----------

NT_OPTS=""
CQLSH_OPTS=""
DT_OPTS=""
OLDWD="$(pwd)"
OUT_DIR=$(mktemp -d)
TIMEOUT=600
HOST_FILE=""
SSH_OPTS=""
NT_OPTS=""
COLLECT_OPTS=""
REMOVE_OPTS=""
INSIGHT_COLLECT_OPTS=""

# ---------------
# Parse arguments
# ---------------

while getopts ":hivrn:c:d:f:o:p:s:t:u:I:m:" opt; do
    case $opt in
        c) CQLSH_OPTS="$OPTARG"
           ;;
        d) DT_OPTS="$OPTARG"
           ;;
        f) HOST_FILE="$OPTARG"
           ;;
        i) COLLECT_OPTS="$COLLECT_OPTS -i"
           ;;
        I) INSIGHT_COLLECT_OPTS="-I '${OPTARG}'"
           ;;
        n) NT_OPTS=$OPTARG
           ;;
        o) OUT_DIR=$OPTARG
           ;;
        p) COLLECT_OPTS="$COLLECT_OPTS -p $OPTARG"
           ;;
        r) REMOVE_OPTS="-r"
           ;;
        s) SSH_OPTS=$OPTARG
           ;;
        t) TYPE=$OPTARG
           ;;
        u) TIMEOUT=$OPTARG
           ;;
        v) COLLECT_OPTS="$COLLECT_OPTS -v"
           ;;
        m) MODE="$OPTARG"
           if [ "$MODE" != "normal" ] && [ "$MODE" != "extended" ] && [ "$MODE" != "light" ]; then
               echo "Incorrect collection mode: '$MODE'"
               usage
               exit 1
           fi
           COLLECT_OPTS="$COLLECT_OPTS -m $MODE"
           ;;
        h) usage
           exit 0
           ;;
        *) echo "Unknown flag passed: '$opt'"
           usage
           exit 1
           ;;
    esac
done
shift "$((OPTIND -1))"
echo "Using output directory: ${OUT_DIR}"

# ------------------------
# Check valid install type
# ------------------------
check_type

DSE_DDAC_ROOT=$1
if [ "$TYPE" = "ddac" ] && [ -z "$DSE_DDAC_ROOT" ]; then
    echo "You must specify root location of DDAC installation"
    usage
    exit 1
fi

TMP_HOST_FILE=""
if [ -z "$HOST_FILE" ] || [ ! -f "$HOST_FILE" ]; then
    echo "File with hosts isn't specified, or doesn't exist, using 'nodetool status'"
    TMP_HOST_FILE=${OUT_DIR}/diag-hosts.$$
    nodetool status|grep -e '^UN'|sed -e 's|^UN [ ]*\([^ ]*\) .*$|\1|' > "$TMP_HOST_FILE"
    HOST_FILE=$TMP_HOST_FILE
fi

# TODO: calculate ServerAliveCountMax based on the timeout & ServerAliveInterval...
SSH_OPTS="$SSH_OPTS -o StrictHostKeyChecking=no -o ConnectTimeout=$TIMEOUT -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=40"

declare -A servers
for host in $(cat "$HOST_FILE"); do
    echo "Copying collect_node_diag.sh to $host..."
    scp $SSH_OPTS collect_node_diag.sh "${host}:~/"
    RES=$?
    if [ $RES -ne 0 ]; then
        echo "Error during execution SCP, copying script to host $host, exiting..."
        exit 1
    fi
    NODE_OUT_DIR="$(ssh $SSH_OPTS "$host" 'mktemp -d'| tr -d '\r')"
    if [ $RES -ne 0 ]; then
        echo "Error creating a temp directory on host $host, exiting..."
        exit 1
    fi
    servers[$host]=$NODE_OUT_DIR
    echo "host: $host out_dir=$NODE_OUT_DIR"
done
    
declare -A pids
for host in "${!servers[@]}"; do
    NODE_OUT_DIR="${servers[$host]}"
    ssh $SSH_OPTS $host "bash --login ./collect_node_diag.sh -t $TYPE -o $NODE_OUT_DIR $COLLECT_OPTS $INSIGHT_COLLECT_OPTS -c '$CQLSH_OPTS' -n '$NT_OPTS' -d '$DT_OPTS' '$DSE_DDAC_ROOT'" &
    pids[$host]="${!}"
done

declare -a hosts_failed
declare -a hosts_success
for host in "${!pids[@]}"; do
    echo "Going to wait for PID ${pids[$host]} for host $host"
    if wait ${pids[$host]}; then
        RES=$?
        if [ "$RES" -eq 0 ]; then
            hosts_success+=("$host")
        else
            hosts_failed+=("$host")
        fi
    else
        hosts_failed+=("$host")
    fi
done

failed_len=${#hosts_failed[@]}
if [ "$failed_len" -gt 0 ]; then
    if [ "$failed_len" -eq ${#servers[@]} ]; then
        echo "Collection failed on all hosts!"
        exit 1
    else
        echo "Collection failed on $failed_len hosts: ${hosts_failed[*]}"
        echo "We will generate diagnostic tarball only for hosts where collection was successful"
    fi
fi

# we continue to 
for host in "${hosts_success[@]}"; do
    NODE_OUT_DIR="${servers[$host]}"
    echo "host: $host out_dir=$NODE_OUT_DIR"
    scp $SSH_OPTS "${host}:${NODE_OUT_DIR}/*.tar.gz" "$OUT_DIR"
    RES=$?
    if [ $RES -ne 0 ]; then
        echo "Error during execution SCP, copying data from host $host, exiting..."
        exit 1
    fi
    if [ -n "$REMOVE_OPTS" ] && [ "$NODE_OUT_DIR" != "/" ] ; then
        ssh $SSH_OPTS "$host" "rm -rf '$NODE_OUT_DIR'"
    fi
done

./generate_diag.sh -o "$OUT_DIR" -t "$TYPE" $REMOVE_OPTS $COLLECT_OPTS "$OUT_DIR"

# do cleanup
if [ -n "$TMP_HOST_FILE" ]; then
    rm -f "$TMP_HOST_FILE"
fi

cd "$OLDWD" || exit 1
