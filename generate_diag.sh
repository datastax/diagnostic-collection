#!/bin/bash
#
# File: generate_diag.sh
#
# Created: Wednesday, May 22 2019
# Modified: $Format:%cD$ 
# Hash: $Format:%h$
#
# This script merges diagnostic from multiple nodes into single diagnostic tarball
##

DSE_PATTERN="diag"
INS_PATTERN="dse-insights"
PATTERN=$DSE_PATTERN
OUT_DIR="/var/tmp"
# size of insights file chunk, in Mb
INSIGHTS_CHUNK_SIZE=4500  # 4.5Gb
#INSIGHTS_CHUNK_SIZE=500

function usage() {
    echo "Usage: $0 [-f file_name] [-p file_pattern] [-i] [-o output_dir] [-r] path_to_dir_with_diag_tarballs"
    echo "   -f file_name - name of resulting file (default: $OUT_DIR/<CLUSTER_NAME>-diagnostics.tar.gz)"
    echo "   -p file_pattern - pattern to use to find individual files (default '${PATTERN}-*.tar.gz')"
    echo "   -o output_dir - where to put resulting file"
    echo "   -i - process insights files only (default is collect DSE only)"
    echo "   -r - remove individual diagnostic files after processing"
    echo "   -t - type, for selecting type of install"
    echo "   path_to_dir_with_diag_tarballs - path to directory with individual diagnostics"
}

RES_FILE=""
INSIGHTS=""
REMOVE_FILES=""
TYPE="dse"

while getopts ":hzvirkf:p:o:t:m:" opt; do
    case $opt in
        f) RES_FILE=$OPTARG
           ;;
        p) PATTERN=$OPTARG
           ;;
        i) INSIGHTS="true"
           PATTERN=$INS_PATTERN
           ;;
        o) OUT_DIR=$OPTARG
           ;;
        r) REMOVE_FILES="true"
           ;;
        t) TYPE=$OPTARG
           ;;
        k)
           ;;
        v)
           ;;
        m)
           ;;
        z)
           ;;
        h) usage
           exit 0
           ;;
        *) echo "Unknown flag '$opt'"
           usage
           exit 1
           ;;
    esac
done
shift "$((OPTIND -1))"


DIAGS_DIR=$1
if [ -z "$DIAGS_DIR" ]; then
    usage
    exit 1
fi

if [ ! -d "$DIAGS_DIR" ]; then
    echo "Specified directory '$DIAGS_DIR' doesn't exist!"
    usage
    exit 1
fi

OLDWD="$(pwd)"
TMPDIR=$OUT_DIR/diag.$$
if ! echo "$DIAGS_DIR"|grep -e '^/' > /dev/null ; then
#    echo "relative diags directory! adjusting..."
    DIAGS_DIR="$OLDWD/$DIAGS_DIR"
fi

DFILES="$(ls "$DIAGS_DIR"/${PATTERN}-*.tar.gz 2>/dev/null)"
if [ -z "$DFILES" ]; then
    if [ "$PATTERN" = "$DSE_PATTERN" ]; then
        DFILES="$(ls "$DIAGS_DIR"/${INS_PATTERN}-*.tar.gz 2>/dev/null)"
        INSIGHTS="true"
    fi
    if [ -z "$DFILES" ]; then
        echo "No diagnostic files or DSE Insights files found in the specified directory"
        exit 1
    fi
    echo "Haven't found the DSE diagnostic, but found DSE Insights files"
fi

FILE_TYPE=diagnostics
mkdir -p "$TMPDIR/cluster/nodes"
cd "$TMPDIR/cluster/nodes" || exit
for i in "$DIAGS_DIR"/${PATTERN}-*.tar.gz; do
    tar zxf "$i"
    if [ -n "$REMOVE_FILES" ]; then
        rm -f "$i"
    fi
done

if [ -z "$INSIGHTS" ]; then # processing just DSE diagnostic
    CLUSTER_NAME=$(cat -- */conf/cassandra/cassandra.yaml|grep -e '^cluster_name: '|sed -e "s|^cluster_name:[ ]*\(.*\)\$|\1|"|tr -d "'"|head -n 1|tr ' ' '_'| tr '"' '_')
    COLLECT_DATE="$(date -u '+%Y-%m-%d_%H_%M_%S')"
    echo "Cluster name='$CLUSTER_NAME' collected at $COLLECT_DATE"

    # Remove sensitive data
    BACKUP_SUFFIX=".bak"
    OSTYPE="$(uname -s)"
    if [ "$OSTYPE" = "Darwin" ]; then
        BACKUP_SUFFIX=" .bak"
    fi
    sed -i${BACKUP_SUFFIX} -e 's|^\(.*password: \).*$|\1redacted|' -- */conf/cassandra/cassandra.yaml
    sed -i${BACKUP_SUFFIX} -e 's|^\(.*StorePassword=\).*\(".*\)$|\1redacted\2|' -- */conf/cassandra/cassandra-env.sh
    if [ "$TYPE" = "dse" ]; then # DSE
        sed -i${BACKUP_SUFFIX} -e 's|^\(.*password: \).*$|\1redacted|' -- */conf/dse/dse.yaml
    fi
    find . -name \*.bak -print0 |xargs -0 rm -f

    # Pack everything together
    cd "$TMPDIR" || exit
    CL_DIR="${CLUSTER_NAME}-${FILE_TYPE}-${COLLECT_DATE}"
    mv cluster "$CL_DIR"
    
    if [ -z "$RES_FILE" ]; then
        RES_FILE="${OUT_DIR}/${CLUSTER_NAME}-${FILE_TYPE}.tar.gz"
    fi
    rm -f "$RES_FILE"
    tar zcf "$RES_FILE" "$CL_DIR"
    echo "Complete $FILE_TYPE tarball is in $RES_FILE"
else # processing insights
    cd "$TMPDIR" || exit
    FILE_TYPE=insights
    mv cluster/nodes/* cluster/
    rmdir cluster/nodes
    GZ_FILE="$(find cluster -name \*.gz|head -n 1)"
    GZ_LINE="$(gzip -dc "$GZ_FILE"|cut -b 6-|grep -a '"cluster":"'|grep -a '"timestamp":'|head -n 1)"
    CLUSTER_NAME="$(echo "$GZ_LINE"|sed -e 's|^.*"cluster":"\([^"]*\)".*$|\1|'|tr ' ' '_')"
    COLLECT_DATE="$(echo "$GZ_LINE"|sed -e 's|^.*"timestamp":\([^,]*\),.*$|\1|'|tr ':' '_')"

    # Pack everything together, splitting into chunks if required
    cd "$TMPDIR" || exit
    file_num=0
#    set -x
    num_dirs_left="$(find cluster -maxdepth 2 -mindepth 1 -type d|wc -l)"
    ORIG_RES_FILE="$RES_FILE"
    while [ "$num_dirs_left" -gt 0 ] ; do
        CL_DIR="${CLUSTER_NAME}-${FILE_TYPE}-${COLLECT_DATE}-${file_num}"
        mkdir "$CL_DIR"
        while true ; do
            num_dirs_left="$(find cluster -maxdepth 2 -mindepth 1 -type d|wc -l)"
            cl_size="$(du -ms "$CL_DIR"|cut -f 1)"
#            echo "check num_dirs_left=$num_dirs_left cl_size=$cl_size"
            if [ "$num_dirs_left" -eq 0 ] || [ "$cl_size" -ge "$INSIGHTS_CHUNK_SIZE" ]; then
#                echo "break num_dirs_left=$num_dirs_left cl_size=$cl_size"
                break
            fi
            dir_to_move="$(find cluster -maxdepth 2 -mindepth 1 -type d|head -n 1)"
            if [ -n "$dir_to_move" ]; then
#                echo "moving $dir_to_move to $CL_DIR"
                mv "$dir_to_move" "$CL_DIR"
            fi
        done

        collected_dirs="$(find "$CL_DIR" -maxdepth 2 -mindepth 1 -type d|wc -l)"
        if [ "$collected_dirs" -gt 0 ] ; then
            if [ -z "$ORIG_RES_FILE" ]; then
                RES_FILE="${OUT_DIR}/${CLUSTER_NAME}-${FILE_TYPE}-${file_num}.tar"
            else
                RES_FILE="${ORIG_RES_FILE}-${file_num}"
            fi
            rm -f "$RES_FILE"
            #  pack into tar because the files are gzipped anyway?
            tar cf "$RES_FILE" "$CL_DIR"
            rm -rf "$CL_DIR"
            echo "Insights tarball for chunk $file_num is in $RES_FILE"
            ((file_num++))
        fi
    done
fi
    
rm -rf "$TMPDIR"
cd "$OLDWD" || exit
