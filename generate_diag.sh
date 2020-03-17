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

function usage() {
    echo "Usage: $0 [-f file_name] [-p file_pattern] [-o output_dir] [-r] path_to_dir_with_diag_tarballs"
    echo "   -f file_name - name of resulting file (default: $OUT_DIR/<CLUSTER_NAME>-diagnostics.tar.gz)"
    echo "   -p file_pattern - pattern to use to find individual files (default '${PATTERN}-*.tar.gz')"
    echo "   -o output_dir - where to put resulting file"
    echo "   -r - remove individual diagnostic files after processing"
    echo "   -t - type, for selecting type of install"
    echo "   path_to_dir_with_diag_tarballs - path to directory with individual diagnostics"
}

RES_FILE=""
REMOVE_FILES=""
TYPE="dse"

while getopts ":hvrf:p:o:t:m:" opt; do
    case $opt in
        f) RES_FILE=$OPTARG
           ;;
        p) PATTERN=$OPTARG
           ;;
        o) OUT_DIR=$OPTARG
           ;;
        r) REMOVE_FILES="true"
           ;;
        t) TYPE=$OPTARG
           ;;
        v)
           ;;
        m)
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
    echo "No diagnostic files found in the specified directory"
    exit 1
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

CLUSTER_NAME="$(cat -- */conf/cassandra/cassandra.yaml|grep -e '^cluster_name: '|sed -e "s|^cluster_name:[ ]*\(.*\)\$|\1|"|tr -d "'"|head -n 1|tr ' ' '_')"
COLLECT_DATE="$(date '+%Y-%m-%d_%H_%M_%S')"
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

rm -rf "$TMPDIR"
cd "$OLDWD" || exit
