#!/bin/bash
#
# File: collect_node_diag.sh
#
# Created: Wednesday, May 22 2019
#

function usage() {
    echo "Usage: $0 -t <type> [options] [path]"
    echo " ----- Required --------"
    echo "   -t type -  valid choices are \"coss\", \"ddac\", \"dse\" "
    echo " ----- Options --------"
    echo "   -c cqlsh_options - e.g \"-u user -p password\" etc. Ensure you enclose with \""
    echo "   -n nodetool_options - options to pass to nodetool. Syntax the same as \"-c\""
    echo "   -d dsetool_options - options to pass to dsetool. Syntax the same as \"-c\""
    echo "   -p pid - PID of DSE or DDAC process"
    echo "   -f file_name - name of resulting file"
    echo "   -i insights - collect only data for DSE Insights"
    echo "   -I insights_dir - directory to find the insights .gz files"
    echo "   -o output_dir - where to put generated files. default: /var/tmp"
    echo "   -v - verbose output"
    echo "   path - top directory of COSS, DDAC or DSE installation (for tarball installs)"
}

#echo "Got args $*"

# ----------
# Setup vars
# ----------

VERBOSE=""
NT_OPTS=""
CQLSH_OPTS=""
DT_OPTS=""
PID=""
RES_FILE=""
INSIGHTS_MODE=""
INSIGHTS_DIR=""
IS_DDAC=""
IS_COSS=""
IS_TARBALL=""
IS_PACKAGE=""
OUTPUT_DIR="/var/tmp"
NODE_ADDR=""
CONN_ADDR=""
ROOT_DIR=""
DATA_DIR=""
CONF_DIR=""
DSE_CONF_DIR=""
LOG_DIR=""
TMP_DIR=""
OLDWD="$(pwd)"
HOST_OS="$(uname -s)"
JCMD="$JAVA_HOME/bin/jcmd"
DEFAULT_INSIGHTS_DIR="/var/lib/cassandra/insights_data/insights"

# settings overridable via environment variables
IOSTAT_LEN="${IOSTAT_LEN:-10}"

# ---------------
# Parse arguments
# ---------------

while getopts ":hivn:c:p:f:d:o:t:I:" opt; do
    case $opt in
        n) NT_OPTS="$OPTARG"
           ;;
        c) CQLSH_OPTS="$OPTARG"
           ;;
        p) PID="$OPTARG"
           ;;
        f) RES_FILE="$OPTARG"
           ;;
        d) DT_OPTS="$OPTARG"
           ;;
        o) OUTPUT_DIR="$OPTARG"
           ;;
        i) INSIGHTS_MODE="true"
           ;;
        I) INSIGHTS_DIR="$OPTARG"
            ;;
        t) TYPE=$OPTARG
           ;;
        v) VERBOSE=true
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
ROOT_DIR="$1"

mkdir -p "${OUTPUT_DIR}"

[ -n "${ROOT_DIR}" ] && echo "Using ${ROOT_DIR} as root dir for DSE/DDAC/C*"

function get_node_ip {
    NODE_ADDR="$(grep -e '^broadcast_address: ' $CONF_DIR/cassandra.yaml |sed -e 's|^broadcast_address:[ ]*\([^ ]*\)$|\1|')"
    CONN_ADDR="$NODE_ADDR"
    if [ -z "$NODE_ADDR" ]; then
        NODE_ADDR="$(grep -e '^listen_address: ' $CONF_DIR/cassandra.yaml |sed -e 's|^listen_address:[ ]*\([^ ]*\)$|\1|')"
        CONN_ADDR="$NODE_ADDR"
        if [ -z "$NODE_ADDR" ] || [ "$NODE_ADDR" = "127.0.0.1" ] || [ "$NODE_ADDR" = "localhost" ]; then
#            echo "Can't detect node's address from cassandra.yaml, or it's set to localhost. Trying to use the 'hostname'"
            if [ "$HOST_OS" = "Linux" ]; then
                NODE_ADDR="$(hostname -i)"
            else
                NODE_ADDR="$(hostname)"
            fi
        fi
        CONN_ADDR="$NODE_ADDR"
        if [ -z "$CONN_ADDR" ]; then
            echo "Can't detect node's address..."
            exit 1
        fi
    fi
    
}

function set_paths {
    # tmp and output paths
    if [ -d "$OUTPUT_DIR" ]; then 
        TMP_DIR="$OUTPUT_DIR/diag.$$"
    else
        TMP_DIR="/var/tmp/diag.$$"
    fi
    mkdir -p $TMP_DIR

    # log paths
    if [ -z "$LOG_DIR" ] && [ -n "$IS_PACKAGE" ]; then 
        LOG_DIR=/var/log/cassandra
    elif [ -z "$LOG_DIR" ] && [ -n "$IS_TARBALL" ]; then
        LOG_DIR=$ROOT_DIR/logs
    fi
 
    # config paths
    if [ -z "$CONF_DIR" ]; then
        # DDAC - we have only tarball...
        if [ -n "$IS_DDAC" ]; then
            CONF_DIR="$ROOT_DIR/conf"
        elif [ -n "$IS_TARBALL" ] && [ -n "$IS_COSS" ]; then
            CONF_DIR="$ROOT_DIR/conf"
        elif [ -n "$IS_TARBALL" ] && [ -n "$IS_DSE" ]; then
            CONF_DIR="$ROOT_DIR/resources/cassandra/conf"
            DSE_CONF_DIR="$ROOT_DIR/resources/dse/conf"
            # DSE package
        elif [ -n "$IS_PACKAGE" ] && [ -n "$IS_DSE" ]; then
            CONF_DIR=/etc/dse/cassandra
            DSE_CONF_DIR=/etc/dse/
            # COSS package
        elif [ -n "$IS_PACKAGE" ] && [ -n "$IS_COSS" ]; then
            CONF_DIR=/etc/cassandra
        fi
    fi

    # binary paths
    if [ -z "$BIN_DIR" ]; then
        if [ -n "$IS_DDAC" ]; then
            BIN_DIR="$ROOT_DIR/bin"
            # DSE tarball
        elif [ -n "$IS_TARBALL" ] && [ -n "$IS_DSE" ]; then
            BIN_DIR="$ROOT_DIR/bin"
            # COSS tarball
        elif [ -n "$IS_TARBALL" ] && [ -n "$IS_COSS" ]; then
            BIN_DIR="$ROOT_DIR/bin"
            # DSE package
        elif [ -n "$IS_PACKAGE" ] && [ -n "$IS_DSE" ]; then
            BIN_DIR=/usr/bin
            # COSS package
        elif [ -n "$IS_PACKAGE" ] && [ -n "$IS_COSS" ]; then
            BIN_DIR=/usr/bin
        fi
    fi

    [ -n "$VERBOSE" ] && echo "CONF_DIR=${CONF_DIR}"
    [ -n "$VERBOSE" ] && echo "DSE_CONF_DIR=${DSE_CONF_DIR}"
    [ -n "$VERBOSE" ] && echo "BIN_DIR=${BIN_DIR}"
    [ -n "$VERBOSE" ] && echo "LOG_DIR=${LOG_DIR}"
    [ -n "$VERBOSE" ] && echo "TMP_DIR=${TMP_DIR}"

    [[ -d "$CONF_DIR" ]] || { echo "Missing CONF_DIR"; exit 1; }
    [[ -z "${DSE_CONF_DIR}" || -d "$DSE_CONF_DIR" ]] || { echo "Missing DSE_CONF_DIR"; exit 1; }
    [[ -d "$BIN_DIR" ]] || { echo "Missing BIN_DIR"; exit 1; }
    [[ -d "$TMP_DIR" ]] || { echo "Missing TMP_DIR"; exit 1; }
}

function detect_install {
    # DDAC Install
    if [ "$TYPE" == "ddac" ]; then
        IS_DDAC="true"
        if [ -d "$ROOT_DIR" ] && [ -d "$ROOT_DIR/conf" ]; then
            IS_TARBALL="true"
        else
            echo "DDAC install: no tarball directory found, or was specified."
            usage
            exit 1
        fi
    # COSS Install
    elif [ "$TYPE" == "coss" ]; then
        IS_COSS="true"
        # COSS package install
        if [ -d "/etc/cassandra" ] && [ -f "/etc/default/cassandra" ] && [ -d "/usr/share/cassandra" ]; then
            IS_PACKAGE="true"
            ROOT_DIR="/etc/cassandra"
            [ -n "$VERBOSE" ] && echo "COSS install: package directories successfully found. Proceeding..."
        # COSS tarball install
        elif [ -d "$ROOT_DIR" ] && [ -d "$ROOT_DIR/conf" ]; then
            IS_TARBALL="true"
            [ -n "$VERBOSE" ] && echo "COSS install: tarball directories successfully found. Proceeding..."
        else
            echo "COSS install: no package or tarball directories found, or no tarball directory specified."
            usage
            exit 1
        fi
    # DSE install
    elif [ "$TYPE" == "dse" ]; then
        IS_DSE="true"
        # DSE package install
        [ -n "$VERBOSE" ] && echo "DSE install: Checking install type..."
        if [ -d "/etc/dse" ] && [ -f "/etc/default/dse" ] && [ -d "/usr/share/dse/" ]; then
            IS_PACKAGE="true"
            ROOT_DIR="/etc/dse"
            [ -n "$VERBOSE" ] && echo "DSE install: package directories successfully found. Proceeding..."
        # DSE tarball install
        elif [ -d "$ROOT_DIR" ] && [ -d "$ROOT_DIR/resources/cassandra/conf" ] && [ -d "$ROOT_DIR/resources/dse/conf" ]; then
            IS_TARBALL="true"
            [ -n "$VERBOSE" ] && echo "DSE install: tarball directories successfully found. Proceeding..."
        else
            echo "DSE install: no package or tarball directories found, or no tarball directory specified."
            usage
            exit 1
        fi
    else
    # No install type selected
        usage
        exit 1
    fi

    # Select user (defaults to current user for tarball, "cassandra" for package
    if [ -z "$CASS_USER" ]; then
        if [ -n "$IS_PACKAGE" ]; then
           CASS_USER="cassandra"
        else
           CASS_USER=$USER
        fi
    fi
}  

function get_pid {
    if [ -z "$PID" ] && ([ -n "$IS_COSS" ] || [ -n "$IS_DDAC" ]) ; then
        PID="$(ps -aef|grep org.apache.cassandra.service.CassandraDaemon|grep java|sed -e 's|^[ ]*[^ ]*[ ]*\([^ ]*\)[ ].*|\1|')"
    elif [ -z "$PID" ] && [ -n "$IS_DSE" ]; then
        PID="$(ps -aef|grep com.datastax.bdp.DseModule|grep java|sed -e 's|^[ ]*[^ ]*[ ]*\([^ ]*\)[ ].*|\1|')"
    fi
}

# Collects OS info
function collect_system_info() {
    [ -n "$VERBOSE" ] && echo "Collecting OS level info..."
    if [ "$HOST_OS" = "Linux" ]; then
        if [ -n "$PID" ]; then
            cat "/proc/$PID/limits" > $DATA_DIR/process_limits 2>&1
        fi
        cat /sys/kernel/mm/transparent_hugepage/defrag > $DATA_DIR/os-metrics/hugepage_defrag 2>&1
        sudo blockdev --report 2>&1 |tee > $DATA_DIR/os-metrics/blockdev_report 
        free > $DATA_DIR/os-metrics/free 2>&1
        iostat -ymxt 1 $IOSTAT_LEN > $DATA_DIR/os-metrics/iostat 2>&1
        vmstat  -w -t -a > $DATA_DIR/os-metrics/wmstat-mem 2>&1
        vmstat  -w -t -s > $DATA_DIR/os-metrics/wmstat-stat 2>&1
        vmstat  -w -t -d > $DATA_DIR/os-metrics/wmstat-disk 2>&1
        sysctl -a > $DATA_DIR/os-metrics/sysctl 2>&1
        lscpu > $DATA_DIR/os-metrics/lscpu 2>&1
    fi
    df -k > $DATA_DIR/os-metrics/df 2>&1
    # Collect uname info (for Linux)
    [ -n "$VERBOSE" ] && echo "Collecting uname info..."
    if [ "$HOST_OS" = "Linux" ]; then
        echo "kernel_name: $(uname -s)" > $DATA_DIR/os-info.txt 2>&1
        echo "node_name: $(uname -n)" >> $DATA_DIR/os-info.txt 2>&1
        echo "kernel_release: $(uname -r)" >> $DATA_DIR/os-info.txt 2>&1
        echo "kernel_version: $(uname -v)" >> $DATA_DIR/os-info.txt 2>&1
        echo "machine_type: $(uname -m)" >> $DATA_DIR/os-info.txt 2>&1
        echo "processor_type: $(uname -p)" >> $DATA_DIR/os-info.txt 2>&1
        echo "platform_type: $(uname -i)" >> $DATA_DIR/os-info.txt 2>&1
        echo "os_type: $(uname -o)" >> $DATA_DIR/os-info.txt 2>&1
    # Collect uname info (for MacOS)
    elif [ "$HOST_OS" = "Darwin" ]; then
        echo "hardware_name: $(uname -m)" > $DATA_DIR/os-info.txt 2>&1
        echo "node_name: $(uname -n)" >> $DATA_DIR/os-info.txt 2>&1
        echo "processor_type: $(uname -p)" >> $DATA_DIR/os-info.txt 2>&1
        echo "os_release: $(uname -r)" >> $DATA_DIR/os-info.txt 2>&1
        echo "os_version: $(uname -v)" >> $DATA_DIR/os-info.txt 2>&1
        echo "os_name: $(uname -s)" >> $DATA_DIR/os-info.txt 2>&1
    else
        echo "os type $HOST_OS not catered for or detected" > $DATA_DIR/os-info.txt 2>&1
    fi 
    # Collect NTP info (for Linux)
    [ -n "$VERBOSE" ] && echo "Collecting ntp info..."
    if [ "$HOST_OS" = "Linux" ]; then
        ntptime > $DATA_DIR/ntp/ntptime 2>&1
        ntpstat > $DATA_DIR/ntp/ntpstat 2>&1
    fi
    # Collect TOP info (for Linux)
    [ -n "$VERBOSE" ] && echo "Collecting top info..."
    if [ "$HOST_OS" = "Linux" ]; then
        top -n1 -b | \
        grep "Cpu" | \
        cut -d\: -f2 | \
        awk '{
            user=$1;
            systm=$3;
            nice=$5;
            idle=$7;
            iowait=$9;
            steal=$15
            } 
            END {
            print "user: "user "\nnice: "nice "\nsystem: "systm "\niowait: "iowait "\nsteal: "steal "\nidle: "idle
        }' > $DATA_DIR/os-metrics/cpu.txt 2>&1
    fi
    # Collect FREE info (for Linux)
    [ -n "$VERBOSE" ] && echo "Collecting free info..."
    if [ "$HOST_OS" = "Linux" ]; then
        free -m | \
        grep -E "Mem|Swap" | \
        awk '{
            type=$1; 
            total=$2; 
            used=$3; 
            free=$4; 
            shared=$5; 
            buffcache=$6; 
            avail=$7; 
            if (type=="Mem:"){
                print "mem total: "total"\nmem used: "used"\nmem free: "free"\nmem shared: "shared"\nmem buff/cache: "buffcache"\nmem available: "avail
                } else {
                print "swap total: "total"\nswap used: "used"\nswap free: "free}}' > $DATA_DIR/os-metrics/memory.txt 2>&1
    fi
    # Collect JVM system info (for Linux)
    [ -n "$VERBOSE" ] && echo "Collecting jvm system info..."
    if [ -n "$PID" ] && [ "$HOST_OS" = "Linux" ] && [ -n "$JAVA_HOME" ]; then
        if [ -n "$IS_PACKAGE" ]; then
            sudo -u "$CASS_USER" "$JCMD" "$PID" VM.system_properties 2>&1| tee > $DATA_DIR/java_system_properties.txt
            sudo -u "$CASS_USER" "$JCMD" "$PID" VM.command_line 2>&1 |tee > $DATA_DIR/java_command_line.txt
        else 
            "$JCMD" "$PID" VM.system_properties > $DATA_DIR/java_system_properties.txt 2>&1
            "$JCMD" "$PID" VM.command_line > $DATA_DIR/java_command_line.txt 2>&1
        fi
    fi       
    # Collect Data DIR info
    [ -n "$VERBOSE" ] && echo "Collecting disk info..."
    # TODO: rewrite this to be not dependent on OS, plus check both java_command_line.txt & java_cmdline
    if [ "$HOST_OS" = "Linux" ]; then
       # Try to read the data and commitlog directories from config file.
       # The multiple sed statements strip out leading / trailing lines
       # and concatenate on the same line where multiple directories are
       # configured to allow Nibbler to read it as a csv line
       DATA_CONF=$(sed -n -E "/^data_file_directories:/,/^[a-z]?.*$/p" < "$CONF_DIR/cassandra.yaml" | grep -E "^.*-" | sed -e "s/^- *//" | sed -z "s/\n/,/g" | sed -e "s/.$/\n/")
       COMMITLOG_CONF=$(sed -n "/^commitlog_directory:/,/^$/p" < "$CONF_DIR/cassandra.yaml" | grep -v -E "^$" | awk '{print $2}')
       # Checks the data and commitlog variables are set. If not then
       # read the JVM variable cassandra.storagedir and append paths as
       # necessary.
       if [ -n "$DATA_CONF" ]; then
           echo "data: $DATA_CONF" > $DATA_DIR/os-metrics/disk_config.txt 2>&1
       else
           DATA_CONF=$(tr " " "\n" < $DATA_DIR/java_command_line.txt | grep "cassandra.storagedir" | awk -F "=" '{print $2"/data"}')
           echo "data: $DATA_CONF" > $DATA_DIR/os-metrics/disk_config.txt 2>&1
       fi
       if [ -n "$COMMITLOG_CONF" ]; then
           echo "commitlog: $COMMITLOG_CONF" >> $DATA_DIR/os-metrics/disk_config.txt 2>&1
       else
           COMMITLOG_CONF=$(tr " " "\n" < $DATA_DIR/java_command_line.txt | grep "cassandra.storagedir" | awk -F "=" '{print $2"/commitlog"}')
           echo "commitlog: $COMMITLOG_CONF" >> $DATA_DIR/os-metrics/disk_config.txt 2>&1
       fi
       # Since the data dir might have multiple items we need to check
       # each one using df to verify the physical device
       #for DEVICE in $(cat $CONF_DIR/cassandra.yaml | sed -n "/^data_file_directories:/,/^$/p" | grep -E "^.*-" | awk '{print $2}')
       for DEVICE in $(echo "$DATA_CONF" | awk '{gsub(/,/,"\n");print}')
       do
           DATA_MOUNT="$DATA_MOUNT,"$(df -h $DEVICE | grep -v "Filesystem" | awk '{print $1}')
       done
       COMMITLOG_MOUNT=$(df -h "$COMMITLOG_CONF" | grep -v "Filesystem" | awk '{print $1}')
       echo "data: $DATA_MOUNT" > $DATA_DIR/os-metrics/disk_device.txt 2>&1
       echo "commitlog: $COMMITLOG_MOUNT" >> $DATA_DIR/os-metrics/disk_device.txt 2>&1
    fi
} 

# Collects data from nodes
function collect_data {
    echo "Collectihg data from node..."

    if [ -n "$PID" ]; then
        if [ -n "$IS_DSE" ]; then
            ps -aef|grep "$PID"|grep com.datastax.bdp.DseModule > $DATA_DIR/java_cmdline
        else
            ps -aef|grep "$PID"|grep CassandraDaemon > $DATA_DIR/java_cmdline
        fi
    fi
    
    for i in cassandra-rackdc.properties cassandra.yaml cassandra-env.sh jvm.options logback-tools.xml logback.xml; do
        if [ -f "$CONF_DIR/$i" ] ; then
            cp $CONF_DIR/$i $DATA_DIR/conf/cassandra/
        fi
    done

    # collecting nodetool information
    [ -n "$VERBOSE" ] && echo "Collecting nodetool output..."
    for i in cfstats compactionhistory compactionstats describecluster getcompactionthroughput getstreamthroughput gossipinfo info netstats proxyhistograms ring status statusbinary tpstats version cfhistograms; do
        $BIN_DIR/nodetool $NT_OPTS $i > $DATA_DIR/nodetool/$i 2>&1
    done
    
    for i in tablestats tpstats ; do
        $BIN_DIR/nodetool $NT_OPTS -F json $i > $DATA_DIR/nodetool/$i.json 2>&1
    done
    
    # collecting schema
    [ -n "$VERBOSE" ] && echo "Collecting schema info..."
    $BIN_DIR/cqlsh $CQLSH_OPTS -e 'describe cluster;' $CONN_ADDR > $DATA_DIR/driver/metadata 2>&1
    $BIN_DIR/cqlsh $CQLSH_OPTS -e 'describe schema;' $CONN_ADDR > $DATA_DIR/driver/schema 2>&1
    $BIN_DIR/cqlsh $CQLSH_OPTS -e 'describe full schema;' $CONN_ADDR > $DATA_DIR/driver/full-schema 2>&1
    
    # collecting process-related info
    collect_system_info

    # collect logs
    # auto-detect log directory
    if [ -f "$DATA_DIR/java_cmdline" ]; then
        TLDIR="$(sed -e 's|^.*-Dcassandra.logdir=\([^ ]*\) .*$|\1|' < "$DATA_DIR/java_cmdline")"
        if [ -n "$TLDIR" ] && [ -d "$TLDIR" ]; then
            CASS_DSE_LOG_DIR=$TLDIR
        fi
    fi
    # if not set, then default
    if [ -z "$CASS_DSE_LOG_DIR" ]; then
        CASS_DSE_LOG_DIR="$LOG_DIR"
    fi
    for i in debug.log system.log gc.log output.log gremlin.log dse-collectd.log; do
        if [ -f "$CASS_DSE_LOG_DIR/$i" ]; then
            cp "$CASS_DSE_LOG_DIR/$i" $DATA_DIR/logs/cassandra/
        fi
    done
    if [ -f "$DATA_DIR/java_cmdline" ]; then
        GC_LOG="$(sed -e 's|^.* -Xloggc:\([^ ]*\) .*$|\1|' < "$DATA_DIR/java_cmdline")"
        if [ -n "$GC_LOG" ] && [ -f "$GC_LOG" ]; then
            cp "$GC_LOG" $DATA_DIR/logs/cassandra/
        fi
    fi
    
    # The rest of DSE-specific things
    if [ -n "$IS_DSE" ]; then
        if [ -f "$DSE_CONF_DIR/dse.yaml" ]; then
            cp "$DSE_CONF_DIR/dse.yaml" $DATA_DIR/conf/dse/
        fi
        if [ -f /etc/default/dse ]; then
            cp /etc/default/dse $DATA_DIR/conf/dse/
        fi
        # TODO: decide, if we need to collect Tomcat logs
        # if [ -f "$DATA_DIR/java_cmdline" ]; then
        #     # TOMCAT_DIR="`cat $DATA_DIR/java_cmdline|sed -e 's|^.*-Dtomcat.logs=\([^ ]*\) .*$|\1|'`"
        #     # if [ -n "$TOMCAT_DIR" -a -d "$TOMCAT_DIR" ]; then
        #     #     
        #     # fi
        # fi

        # Versions to determine if nodesync available
        DSE_VERSION="$($BIN_DIR/dse -v)"
        DSE_MAJOR_VERSION="$(echo $DSE_VERSION|sed -e 's|^\([0-9]\)\..*$|\1|')"

        $BIN_DIR/nodetool $NT_OPTS sjk mxdump > $DATA_DIR/jmx_dump.json 2>&1

        for i in status ring ; do
            $BIN_DIR/dsetool $DT_OPTS $i > $DATA_DIR/dsetool/$i 2>&1
        done

        # collect nodesync rate
        if [ "$DSE_MAJOR_VERSION" -gt "5" ]; then
            $BIN_DIR/nodetool $NT_OPTS nodesyncservice getrate > $DATA_DIR/nodetool/nodesyncrate 2>&1
        fi
    fi
}

function collect_insights {
    echo "Collecting insights data"
    INSIGHTS_DIR=${INSIGHTS_DIR:-${DEFAULT_INSIGHTS_DIR}}
    if [ "$TYPE" = "dse" ] && [ "$INSIGHTS_DIR" = "$DEFAULT_INSIGHTS_DIR" ]; then
        # TODO: was taken from Mani's code as-is, maybe need to improve, like, read the top-level sections, etc.... 
        while read line; do
            name=$line
            case $name in
                *"$INSIGHTS_OPTIONS"*|*"$INSIGHTS_DATA_DIR"*)
                    if [[ $name != \#* ]];
                    then
                        awk '{i=1;next};i && i++ <= 3' $DSE_CONF_DIR/dse.yaml
                        if [[ $name == data_dir* ]];
       	                then
	                    INSIGHTS_LOG_DIR="$(echo $name |grep -i 'data_dir:' |sed -e 's|data_dir:[ ]*\([^ ]*\)$|\1|')"/insights 
                            break	    
                        fi
                    fi
            esac
        done < $DSE_CONF_DIR/dse.yaml
    fi
    
    if [ ! -d "$INSIGHTS_DIR" ]; then
        echo "Can't find Insights directory, or it doesn't exist! $INSIGHTS_DIR"
        exit 1
    fi
    if [ -z "$RES_FILE" ]; then
        RES_FILE=$OUTPUT_DIR/dse-insights-$NODE_ADDR.tar.gz
    fi
    DFILES="$(ls -1 $INSIGHTS_DIR/*.gz 2>/dev/null |head -n 20)"
    if [ -z "$DFILES" ]; then
        echo "No Insights files in the specified directory"
        exit 1
    fi

    NODE_ID="$($BIN_DIR/nodetool $NT_OPTS info|grep -E '^ID'|sed -e 's|^ID.*:[[:space:]]*\([0-9a-fA-F].*\)|\1|')"
    # Node could be offline, so nodetool may not work
    if [ -n "$NODE_ID" ]; then
        NODE_ADDR="$NODE_ID"
    fi
    DATA_DIR="$TMP_DIR"/"$NODE_ADDR"
    mkdir -p "$DATA_DIR"

    # we should be careful when copying the data - list of files could be very long...
    HAS_RSYNC="$(command -v rsync)"
    if [ -n "$HAS_RSYNC" ]; then
        rsync -r --include='*.gz' --exclude='*' "$INSIGHTS_DIR/" "$DATA_DIR/"
    elif [ "$HOST_OS" = "Linux" ]; then
        find "$INSIGHTS_DIR/" -maxdepth 1 -name '*.gz' -print0|xargs -0 cp -t "$DATA_DIR"
    else
        cp "$INSIGHTS_DIR"/*.gz "$DATA_DIR"
    fi
}

function create_directories {
    # Common for COSS / DDAC & DSE
    mkdir -p "$DATA_DIR"/{logs/cassandra,nodetool,conf/cassandra,driver,os-metrics,ntp}
    if [ -n "$IS_DSE" ]; then
        mkdir -p "$DATA_DIR"/{logs/tomcat,dsetool,conf/dse}
    fi
}

function create_archive {
    if [ -z "$RES_FILE" ]; then
        RES_FILE=$OUTPUT_DIR/diag-$NODE_ADDR.tar.gz
    fi
    echo "Creating archive file $RES_FILE"
    # Creates tar/gzip file without base dir same as node IP
    tar -C "$TMP_DIR" -czf "$RES_FILE" "$NODE_ADDR"
}

function cleanup {
    [ -n "$VERBOSE" ] && echo "Removing temp directory $TMP_DIR"
    rm -rf "$TMP_DIR"
}

# Call functions in order
detect_install
set_paths
get_node_ip
DATA_DIR="$TMP_DIR/$NODE_ADDR"
get_pid
create_directories

if [ -n "$INSIGHTS_MODE" ]; then
    collect_insights
else
    collect_data
fi

create_archive
cleanup

cd "$OLDWD" || exit 1
