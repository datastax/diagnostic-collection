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
    echo "   -e encryption key file - Key file for encryption of the generated tarball"
    echo "   -f file_name - file with list of hosts where to execute command (default - try to get list from 'nodetool status')"
    echo "   -k keystore_ssl_info - collect keystore and truststore information"   
    echo "   -i insights - collect only data for DSE Insights"
    echo "   -I insights_dir - directory that contains insights .gz files"
    echo "   -n nodetool_options - options to pass to nodetool. Syntax the same as \"-c\""
    echo "   -o output_dir - where to put resulting file (default: $OUT_DIR)"
    echo "   -p pid - PID of DSE or DDAC process"
    echo "   -r - remove collected files after generation of resulting tarball"
    echo "   -s ssh/scp options - options to pass to SSH/SCP"
    echo "   -B S3 bucket - AWS S3 bucket to upload the artifacts to"
    echo "   -S S3 secret - AWS secret for the S3 upload"
    echo "   -K S3 key - AWS key for the S3 upload"
    echo "   -T ticket number - Ticket for the S3 upload and encrypted tarball naming"
    echo "   -u timeout - timeout for SSH in seconds (default: $TIMEOUT)"
    echo "   -m collection_mode - light, normal, extended. Default: normal"
    echo "   -v - verbose output"
    echo "   -z - don't execute commands that require sudo"
    echo "   -P top directory of COSS, DDAC or DSE installation (for tarball installs)"
    echo "   -C path - explicitly set Cassandra configuration location"
    echo "   -D path - explicitly set DSE configuration location"
}

function check_type {
    if [ "$TYPE" != "ddac" ] && [ "$TYPE" != "coss" ] && [ "$TYPE" != "dse" ]; then
        usage
        exit 1
    fi
}

function debug {
    if [ -n "$VERBOSE" ]; then
        DT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "[${DT}]: $1"
    fi
}

function s3_push() {
  srcFilePath="$1"
  dstFileName="$2"
  ticket="$3"
  s3_bucket="$4"
  s3_key="$5"
  s3_secret="$6"
  timestamp="$7"
  contentType="application/octet-stream"
  s3Date="$(LC_ALL=C date -u +"%a, %d %b %Y %X %z")"
  
  resource="/${s3_bucket}/${ticket}-${timestamp}/${dstFileName}"
  
  stringToSign="PUT\n\n${contentType}\n${s3Date}\n${resource}"
  signature=$(echo -en "${stringToSign}" | openssl sha1 -hmac "${s3_secret}" -binary | base64)
  echo "Uploading ${srcFilePath} to s3://${s3_bucket}/${ticket}-${timestamp}/"
  curl -X PUT -T "${srcFilePath}" \
        -H "Host: ${s3_bucket}.s3.amazonaws.com" \
        -H "Date: ${s3Date}" \
        -H "Content-Type: ${contentType}" \
        -H "Authorization: AWS ${s3_key}:${signature}" \
        https://"${s3_bucket}.s3.amazonaws.com/${ticket}-${timestamp}/${dstFileName}"

  statusState=$?
  print_status_state
  return $statusState
}


# ----------
# Setup vars
# ----------

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
VERBOSE=""
TYPE=""
ENCRYPTION_KEY=""
TICKET=""
S3_BUCKET=""
DSE_DDAC_ROOT=""
CONF_DIR=""
DSE_CONF_DIR=""

# ---------------
# Parse arguments
# ---------------

while getopts ":hzivrk:c:n:d:f:o:p:s:t:u:I:m:e:S:K:T:B:P:C:D:" opt; do
    case $opt in
        c) CQLSH_OPTS="$OPTARG"
           ;;
        d) DT_OPTS="$OPTARG"
           ;;
        e) ENCRYPTION_KEY="$OPTARG"
           ;;
        f) HOST_FILE="$OPTARG"
           ;;
        k) COLLECT_OPTS="$COLLECT_OPTS -k"
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
           VERBOSE="true"
           ;;
        z) COLLECT_OPTS="$COLLECT_OPTS -z"
           ;;
        m) MODE="$OPTARG"
           if [ "$MODE" != "normal" ] && [ "$MODE" != "extended" ] && [ "$MODE" != "light" ]; then
               echo "Incorrect collection mode: '$MODE'"
               usage
               exit 1
           fi
           COLLECT_OPTS="$COLLECT_OPTS -m $MODE"
           ;;
        S) export DS_AWS_SECRET="$OPTARG"
           ;;
        K) export DS_AWS_KEY="$OPTARG"
           ;;
        B) S3_BUCKET="$OPTARG"
           ;;
        T) TICKET="$OPTARG"
           ;;
        P) DSE_DDAC_ROOT="$OPTARG"
           ;;
        C) CONF_DIR="$OPTARG"
           ;;
        D) DSE_CONF_DIR="$OPTARG"
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

if [ "$TYPE" = "ddac" ] && [ -z "$DSE_DDAC_ROOT" ]; then
    echo "You must specify root location of DDAC installation"
    usage
    exit 1
fi

TMP_HOST_FILE=""
if [ -z "$HOST_FILE" ] || [ ! -f "$HOST_FILE" ]; then
    echo "File with hosts isn't specified, or doesn't exist, using 'nodetool status'"
    TMP_HOST_FILE=${OUT_DIR}/diag-hosts.$$
    nodetool $NT_OPTS status|grep -e '^UN'|sed -e 's|^UN [ ]*\([^ ]*\) .*$|\1|' > "$TMP_HOST_FILE"
    HOST_FILE=$TMP_HOST_FILE
fi

# TODO: calculate ServerAliveCountMax based on the timeout & ServerAliveInterval...
SSH_OPTS="$SSH_OPTS -o StrictHostKeyChecking=no -o ConnectTimeout=$TIMEOUT -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=40"

[[ $0 == */* ]] && LAUNCH_PATH=${0%/*}/ || LAUNCH_PATH=./

declare -A servers
for host in $(cat "$HOST_FILE"); do
    debug "Copying collect_node_diag.sh to $host..."
    scp $SSH_OPTS "${LAUNCH_PATH}collect_node_diag.sh" "${host}:~/"
    if [ "$TYPE" = "coss" ]; then
        debug "Copying sjk jar to $host..."
        scp $SSH_OPTS "${LAUNCH_PATH}libs/sjk-plus.jar" "${host}:~/"
    fi
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
    debug "host: $host out_dir=$NODE_OUT_DIR"
done
    
declare -A pids
for host in "${!servers[@]}"; do
    NODE_OUT_DIR="${servers[$host]}"
    ssh $SSH_OPTS $host "bash --login ./collect_node_diag.sh -t $TYPE -o $NODE_OUT_DIR $COLLECT_OPTS $INSIGHT_COLLECT_OPTS -c '$CQLSH_OPTS' -n '$NT_OPTS' -d '$DT_OPTS' -P '$DSE_DDAC_ROOT' -C '$CONF_DIR' -D '$DSE_CONF_DIR'" &
    pids[$host]="${!}"
done

declare -a hosts_failed
declare -a hosts_success
for host in "${!pids[@]}"; do
    debug "Going to wait for PID ${pids[$host]} for host $host"
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
    debug "host: $host out_dir=$NODE_OUT_DIR"
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

${LAUNCH_PATH}generate_diag.sh -o "$OUT_DIR" -t "$TYPE" $REMOVE_OPTS $COLLECT_OPTS "$OUT_DIR"

if [ -f "$ENCRYPTION_KEY" ] && [ -n "$TICKET" ] && [ -n "$S3_BUCKET" ]; then # encrypt and upload the generated tarball
    tarball_path=$(ls $OUT_DIR/*.tar.gz)
    ${LAUNCH_PATH}encrypt_and_upload.sh -e $ENCRYPTION_KEY -f $tarball_path -B $S3_BUCKET -T $TICKET
else
    echo "No valid encryption file provided. Tarball will not get encrypted nor uploaded."
fi

# do cleanup
if [ -n "$TMP_HOST_FILE" ]; then
    rm -f "$TMP_HOST_FILE"
fi

cd "$OLDWD" || exit 1
