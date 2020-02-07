#!/bin/bash
#
# File: collect_node_diag.sh
#
# Created: Friday, May 31 2019
##

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
    echo "   -s ssh/pssh/scp options - options to pass to SSH/PSSH/SCP"
    echo "   -u timeout - timeout for PSSH/SSH in seconds (default: $TIMEOUT)"
    echo "   path - top directory of COSS, DDAC or DSE installation (for tarball installs)"
}

function check_type {
    # DDAC Install
    if [ "$TYPE" == "ddac" -o "$TYPE" == "coss" -o "$TYPE" == "dse" ]; then
        #COLLECT_OPTS="$COLLECT_OPTS -t $TYPE"
        echo ""
    else
    # No install type selected
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
DSE_PID=""
RES_FILE=""
INSIGHTS_MODE=""
INSIGHTS_DIR=""
IS_DDAC=""
IS_COSS=""
IS_TARBALL=""
IS_PACKAGE=""
ROOT_DIR=""
DATA_DIR=""
TMP_DIR=""
OLDWD="`pwd`"
PATTERN=""
PATTER_SUFFIX="diag"
HOST_OS=`uname -s`
OUT_DIR=$(mktemp -d)
TIMEOUT=600
HOST_FILE=""
INSIGHTS=""
SSH_OPTS=""
NT_OPTS=""
COLLECT_OPTS=""
REMOVE_OPTS=""
INSIGHT_COLLECT_OPTS=""

# ---------------
# Parse arguments
# ---------------

while getopts ":hirn:c:d:f:o:p:s:t:u:I:" opt; do
    case $opt in
        c) CQLSH_OPTS=$OPTARG
           ;;
        d) DT_OPTS=$OPTARG
           ;;
        f) HOST_FILE=$OPTARG
           ;;
        i) INSIGHTS="true"
           PATTERN_SUFFIX="dse-insights"
           COLLECT_OPTS="-i"
           ;;
        I) INSIGHTS_DIR=$OPTARG
            INSIGHT_COLLECT_OPTS="-I ${INSIGHTS_DIR}"
            ;;
        n) NT_OPTS=$OPTARG
           ;;
        o) OUT_DIR=$OPTARG
           ;;
        p) DSE_PID=$OPTARG
           ;;
        r) REMOVE_OPTS="-r"
           ;;
        s) SSH_OPTS=$OPTARG
           ;;
        t) TYPE=$OPTARG
           ;;
        u) TIMEOUT=$OPTARG
           ;;
        h) usage
           exit 0
           ;;
    esac
done
shift "$(($OPTIND -1))"
ROOT_DIR=$1
echo "Using output directory: ${OUT_DIR}"
PATTERN="${OUT_DIR}/${PATTERN_SUFFIX}"

# ------------------------
# Check valid install type
# ------------------------
check_type

DSE_DDAC_ROOT=$1
if [ -n "$IS_DDAC" -a -z "$DSE_DDAC_ROOT" ]; then
    echo "You must specify root location of DDAC installation"
    usage
    exit 1
fi

TMP_HOST_FILE=""
if [ -z "$HOST_FILE" -o ! -f "$HOST_FILE" ]; then
    echo "File with hosts isn't specified, or doesn't exist, using 'nodetool status'"
    TMP_HOST_FILE=${OUT_DIR}/diag-hosts.$$
    nodetool status|grep -e '^UN'|sed -e 's|^UN [ ]*\([^ ]*\) .*$|\1|' > $TMP_HOST_FILE
    HOST_FILE=$TMP_HOST_FILE
fi

#HAS_PSSH="`which pssh`"
if [ -z "$HAS_PSSH" ]; then
    echo "We don't have PSSH installed, so performing sequential execution..."
    # TODO: calculate ServerAliveCountMax based on the timeout & ServerAliveInterval...
    SSH_OPTS="$SSH_OPTS -o StrictHostKeyChecking=no -o ConnectTimeout=$TIMEOUT -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=40"
    for host in `cat $HOST_FILE`; do
        echo "Copying collect_node_diag.sh to $host..."
        scp $SSH_OPTS collect_node_diag.sh "${host}:~/"
        RES=$?
        if [ $RES -ne 0 ]; then
            echo "Error during execution SCP, copying script to host $host, exiting..."
            exit 1
        fi
        NODE_OUT_DIR=$(ssh $SSH_OPTS $host 'mktemp -d')
        ssh $SSH_OPTS $host "bash --login ./collect_node_diag.sh -t $TYPE -o $NODE_OUT_DIR $COLLECT_OPTS $INSIGHT_COLLECT_OPTS $CQLSH_OPTS $NT_OPTS $DT_OPTS $DSE_DDAC_ROOT"
        RES=$?
        if [ $RES -ne 0 ]; then
            echo "Error during execution PSSH, exiting..."
            exit 1
        fi
        scp $SSH_OPTS "${host}:${NODE_OUT_DIR}/*.tar.gz" $OUT_DIR
        RES=$?
        if [ $RES -ne 0 ]; then
            echo "Error during execution SCP, copying data from host $host, exiting..."
            exit 1
        fi
    done
else # use pssh
    echo "Use pssh..."
    PSSH_OPTS=""
    if [ -n "$SSH_OPTS" ]; then
        PSSH_OPTS="-X '$SSH_OPTS'"
    fi
    # set -x
    # TODO: need to debug passing the arguments to PSSH...
    cat collect_node_diag.sh| pssh -i -h mhosts -t $TIMEOUT -I -x "-o StrictHostKeyChecking=no" $PSSH_OPTS "cat > collect_node_diag.sh; chmod a+x collect_node_diag.sh"
    RES=$?
    if [ $RES -ne 0 ]; then
        echo "Error during execution PSSH, exiting..."
        exit 1
    fi
    pssh -i -h mhosts -t $TIMEOUT $PSSH_OPTS -x "-o StrictHostKeyChecking=no" "./collect_node_diag.sh $COLLECT_OPTS $NT_OPTS $CQLSH_OPTS $DT_OPTS $DSE_DDAC_ROOT"
    RES=$?
    if [ $RES -ne 0 ]; then
        echo "Error during execution PSSH, exiting..."
        exit 1
    fi
    for host in `cat $HOST_FILE`; do
        scp $SSH_OPTS "${host}:${PATTERN}-*.tar.gz" $OUT_DIR
    done
fi

./generate_diag.sh -o $OUT_DIR -t $TYPE $REMOVE_OPTS $COLLECT_OPTS $OUT_DIR

# do cleanup
if [ -n "$TMP_HOST_FILE" ]; then
    rm -f $TMP_HOST_FILE
fi

