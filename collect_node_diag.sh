#!/bin/bash
#
# File: collect_node_diag.sh
#
# Created: Wednesday, May 22 2019
# Modified: $Format:%cD$
# Hash: $Format:%h$
#
# This script collects diagnostic for individual node
##

function usage() {
    echo "Usage: $0 -t <type> [options] [path]"
    echo " ----- Required --------"
    echo "   -t type -  valid choices are \"coss\", \"ddac\", \"dse\" "
    echo " ----- Options --------"
    echo "   -c cqlsh_options - e.g \"-u user -p password\" etc. Ensure you enclose with \""
    echo "   -n nodetool_options - options to pass to nodetool. Syntax the same as \"-c\""
    echo "   -d dsetool_options - options to pass to dsetool. Syntax the same as \"-c\""
    echo "   -p pid - PID of DSE or DDAC/Cassandra process"
    echo "   -f file_name - name of resulting file"
    echo "   -k keystore_ssl_info - collect keystore and truststore information"
    echo "   -i insights - collect only data for DSE Insights"
    echo "   -I insights_dir - directory to find the insights .gz files"
    echo "   -o output_dir - where to put generated files. Default: /var/tmp"
    echo "   -l log_dir - manually set log directory instead of relying on autodetection"
    echo "   -m collection_mode - light, normal, extended. Default: normal"
    echo "   -v - verbose output"
    echo "   -z - don't execute commands that require sudo"
    echo "   -P path - top directory of COSS, DDAC or DSE installation (for tarball installs)"
    echo "   -C path - explicitly set Cassandra configuration location"
    echo "   -D path - explicitly set DSE configuration location"
    echo "   -e timeout - e.g. \"-e 600\" allow for a longer timeout on operations"
}

#echo "Got args $*"

# ----------
# Setup vars
# ----------

VERBOSE=""
NT_OPTS=""
COLLECT_SSL=""
CQLSH_OPTS=""
DT_OPTS=""
PID=""
RES_FILE=""
INSIGHTS_MODE=""
INSIGHTS_DIR=""
IS_COSS=""
IS_DSE=""
IS_TARBALL=""
IS_PACKAGE=""
OUTPUT_DIR="/var/tmp"
NODE_ADDR=""
CONN_ADDR=""
CONN_PORT=9042
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
DEFAULT_MCAC_DIR="/var/lib/cassandra/mcac_data/insights"
MODE="normal"
NOSUDO=""
JMX_OPTS=""
ROOT_DIR=""
TIMEOUT="120"

# ---------------
# Parse arguments
# ---------------

while getopts ":hzivke:l:c:n:p:f:d:o:t:I:m:P:C:D:" opt; do
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
        k) COLLECT_SSL="true"
           ;;
        z) NOSUDO="true"
           ;;
        l) LOG_DIR="$OPTARG"
           ;;
        m) MODE="$OPTARG"
           if [ "$MODE" != "normal" ] && [ "$MODE" != "extended" ] && [ "$MODE" != "light" ]; then
               echo "Incorrect collection mode: $MODE"
               usage
               exit 1
           fi
           ;;
        t) TYPE=$OPTARG
           ;;
        v) VERBOSE=true
           ;;
        P) ROOT_DIR="$OPTARG"
           ;;
        C) CONF_DIR="$OPTARG"
           ;;
        D) DSE_CONF_DIR="$OPTARG"
           ;;
        e) TIMEOUT="$OPTARG"
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


mkdir -p "${OUTPUT_DIR}"

[ -n "${ROOT_DIR}" ] && echo "Using ${ROOT_DIR} as root dir for DSE/DDAC/C*"

# settings overridable via environment variables
if [ "$MODE" = "extended" ]; then
    IOSTAT_LEN="${IOSTAT_LEN:-30}"
else
    IOSTAT_LEN="${IOSTAT_LEN:-5}"
fi

MAYBE_RUN_WITH_TIMEOUT=""
if [ -n "$(command -v timeout)" ]; then
    MAYBE_RUN_WITH_TIMEOUT="timeout --foreground $TIMEOUT"
fi

function debug {
    if [ -n "$VERBOSE" ]; then
        DT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "[${DT}]: $1"
    fi
}

function get_node_ip {
    CONN_ADDR="$(grep -E '^(native_transport_broadcast_address|broadcast_rpc_address): ' "$CONF_DIR/cassandra.yaml" |sed -e 's|^[^:]*:[ ]*\([^ ]*\)[ ]*$|\1|'|head -n 1|tr -d "'")"
    if [ -z "$CONN_ADDR" ]; then
        CONN_ADDR="$(grep -E '^(native_transport_address|rpc_address): ' "$CONF_DIR/cassandra.yaml" |sed -e 's|^[^:]*:[ ]*\([^ ]*\)[ ]*$|\1|'|head -n 1|tr -d "'")"
    fi
    if [ -z "$CONN_ADDR" ]; then
        IFACE="$(grep -E '^(native_transport_interface|rpc_interface): ' "$CONF_DIR/cassandra.yaml" |sed -e 's|^[^:]*:[ ]*\([^ ]*\)[ ]*$|\1|'|head -n 1|tr -d "'")"
        if [ -n "$IFACE" ]; then
            if [ "$HOST_OS" = "Linux" ]; then
                CONN_ADDR="$(ifconfig "$IFACE"|grep 'inet addr:'|sed -e 's|^.*inet addr:\([^ ]*\) .*[ ]*$|\1|')"
            else
                CONN_ADDR="$(ipconfig getifaddr "$IFACE")"
            fi
        fi
    fi
    # extract listen address
    NODE_ADDR="$(grep -e '^broadcast_address: ' "$CONF_DIR/cassandra.yaml" |sed -e 's|^[^:]*:[ ]*\([^ ]*\)[ ]*$|\1|'|tr -d "'")"
    if [ -z "$NODE_ADDR" ]; then
        IFACE="$(grep -E '^listen_interface: ' "$CONF_DIR/cassandra.yaml" |sed -e 's|^[^:]*:[ ]*\([^ ]*\)[ ]*$|\1|'|tr -d "'")"
        if [ -n "$IFACE" ]; then
            if [ "$HOST_OS" = "Linux" ]; then
                NODE_ADDR="$(ifconfig "$IFACE"|grep 'inet addr:'|sed -e 's|^.*inet addr:\([^ ]*\) .*[ ]*$|\1|')"
            else
                NODE_ADDR="$(ipconfig getifaddr "$IFACE")"
            fi
        fi
        if [ -z "$NODE_ADDR" ]; then
            NODE_ADDR="$(grep -e '^listen_address: ' "$CONF_DIR/cassandra.yaml" |sed -e 's|^[^:]*:[ ]*\([^ ]*\)[ ]*$|\1|'|tr -d "'")"
            if [ -z "$NODE_ADDR" ] || [ "$NODE_ADDR" = "127.0.0.1" ] || [ "$NODE_ADDR" = "localhost" ] || [ $(checkIP $NODE_ADDR) = "false" ]; then
                   echo "Can't detect node's address from cassandra.yaml, or it's set to localhost. Trying to use the 'hostname'"
                if [ "$HOST_OS" = "Linux" ]; then
                    NODE_ADDR="$(hostname -i)"
                else
                    NODE_ADDR="$(hostname)"
                fi
            fi
        fi
    fi
    debug "Native (RPC) address=$CONN_ADDR, Listen address=$NODE_ADDR"
    if [ -z "$CONN_ADDR" ]; then
        CONN_ADDR="$NODE_ADDR"
    fi
    if [ -z "$CONN_ADDR" ]; then
        echo "Can't detect node's address..."
        exit 1
    fi
    TSTR="$(grep -e '^native_transport_port: ' "$CONF_DIR/cassandra.yaml" |sed -e 's|^[^:]*:[ ]*\([^ ]*\)$|\1|'|tr -d "'")"
    if [ -n "$TSTR" ]; then
        CONN_PORT="$TSTR"
    fi
    debug "NODE_ADDR=$NODE_ADDR CONN_ADDR=$CONN_ADDR CONN_PORT=$CONN_PORT"
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
        if [ -n "$IS_TARBALL" ] && [ -n "$IS_COSS" ]; then
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
        if [ -n "$IS_TARBALL" ]; then
            BIN_DIR="$ROOT_DIR/bin"
        elif [ -n "$IS_PACKAGE" ]; then
            BIN_DIR=/usr/bin
        fi
    fi

    debug "CONF_DIR=${CONF_DIR}"
    debug "DSE_CONF_DIR=${DSE_CONF_DIR}"
    debug "BIN_DIR=${BIN_DIR}"
    debug "LOG_DIR=${LOG_DIR}"
    debug "TMP_DIR=${TMP_DIR}"

    [[ -d "$CONF_DIR" ]] || { echo "The CONF_DIR doesn't exist"; exit 1; }
    if [ -n "$IS_DSE" ]; then
      [[ -d "$DSE_CONF_DIR" ]] || { echo "The DSE_CONF_DIR doesn't exist"; exit 1; }
    fi
    [[ -d "$BIN_DIR" ]] || { echo "BIN_DIR points to a non-existing directory"; exit 1; }
    [[ -d "$TMP_DIR" ]] || { echo "TMP_DIR points to a non-existing directory"; exit 1; }
}

function detect_install {
    # DDAC Install
    if [ "$TYPE" == "ddac" ]; then
        if [ -d "$ROOT_DIR" ] && [ -d "$ROOT_DIR/conf" ]; then
            IS_TARBALL="true"
            IS_COSS="true" # structure of DDAC is the same as OSS
        else
            echo "DDAC install: no tarball directory found, or was specified."
            usage
            exit 1
        fi
    # COSS Install
    elif [ "$TYPE" == "coss" ]; then
        IS_COSS="true"
        # COSS package install
        if [ -z "$ROOT_DIR" ] && [ -d "/etc/cassandra" ] && [ -d "/usr/share/cassandra" ]; then
            IS_PACKAGE="true"
            ROOT_DIR="/etc/cassandra"
            debug "COSS install: package directories successfully found. Proceeding..."
        # COSS tarball install
        elif [ -d "$ROOT_DIR" ] && [ -d "$ROOT_DIR/conf" ]; then
            IS_TARBALL="true"
            debug "COSS install: tarball directories successfully found. Proceeding..."
        else
            echo "COSS install: no package or tarball directories found, or no tarball directory specified."
            usage
            exit 1
        fi
    # DSE install
    elif [ "$TYPE" == "dse" ]; then
        IS_DSE="true"
        # DSE package install
        debug "DSE install: Checking install type..."
        if [ -z "$ROOT_DIR" ] && [ -d "/etc/dse" ] && [ -f "/etc/default/dse" ] && [ -d "/usr/share/dse/" ]; then
            IS_PACKAGE="true"
            ROOT_DIR="/etc/dse"
            debug "DSE install: package directories successfully found. Proceeding..."
        # DSE tarball install
        elif [ -d "$ROOT_DIR" ] && [ -d "$ROOT_DIR/resources/cassandra/conf" ] && [ -d "$ROOT_DIR/resources/dse/conf" ]; then
            IS_TARBALL="true"
            debug "DSE install: tarball directories successfully found. Proceeding..."
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
    if [ -z "$PID" ]; then
        if [ -n "$IS_COSS" ] ; then
            PID="$(ps -aef|grep org.apache.cassandra.service.CassandraDaemon|grep java|sed -e 's|^[ ]*[^ ]*[ ]*\([^ ]*\)[ ].*|\1|')"
        else
            PID="$(ps -aef|grep com.datastax.bdp.DseModule|grep java|sed -e 's|^[ ]*[^ ]*[ ]*\([^ ]*\)[ ].*|\1|')"
        fi
    fi
    if [ -n "$PID" ]; then
        if [ -n "$IS_DSE" ]; then
            ps -aef|grep "$PID"|grep com.datastax.bdp.DseModule > "$DATA_DIR/java_cmdline"
        else
            ps -aef|grep "$PID"|grep CassandraDaemon > "$DATA_DIR/java_cmdline"
        fi
    fi
}

# try to detect if we're running in the cloud, and then collect more cloud-specific information
function collect_cloud_info() {
    CLOUD="none"
    if [ -f /sys/hypervisor/uuid ]; then
        if [[ "$(cat /sys/hypervisor/uuid)" =~ ec2.* ]]; then
            CLOUD="AWS"
        fi
    fi
    if [ "$CLOUD" = "none" ] && [ -n "$(command -v dmidecode)" ] && [ -z "$NOSUDO" ]; then
        BIOS_INFO="$(sudo dmidecode -s bios-version)"
        if [[ "$BIOS_INFO" =~ .*amazon.* ]]; then
            CLOUD="AWS"
        elif [[ "$BIOS_INFO" =~ Google.* ]]; then
            CLOUD="GCE"
        elif [[ "$BIOS_INFO" =~ .*OVM.* ]]; then
            CLOUD="Oracle"
        fi
    fi
    if [ "$CLOUD" = "none" ] && [ -r /sys/devices/virtual/dmi/id/product_uuid ]; then
        if [ "$(head -c 3 /sys/devices/virtual/dmi/id/product_uuid)" == "EC2" ]; then
            CLOUD="AWS"
        fi
    fi
    AZ_API_VERSION="2019-11-01"
    if [ "$CLOUD" = "none" ]; then
        if curl -s -m 2 http://169.254.169.254/latest/dynamic/instance-identity/document 2>&1 |grep '"availabilityZone"' > /dev/null ; then
            CLOUD="AWS"
        elif curl -s -m 2 -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/zone > /dev/null 2>&1 ; then
            CLOUD="GCE"
        elif curl -s -m 2 -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=$AZ_API_VERSION"  2>&1 |grep "azEnvironment" > /dev/null ; then
            CLOUD="Azure"
        fi
    fi

    debug "detected cloud provider: $CLOUD"
    echo "cloud provider: $CLOUD" > "$DATA_DIR/os-metrics/cloud_info"
    if [ "$CLOUD" = "AWS" ]; then
        curl -s http://169.254.169.254/latest/dynamic/instance-identity/document > "$DATA_DIR/os-metrics/cloud_aws"
        {
            echo "instance type: $(curl -s http://169.254.169.254/latest/meta-data/instance-type)"
            echo "availability zone: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)"
            echo "public hostname: $(curl -s http://169.254.169.254/latest/meta-data/public-hostname)"
            echo "public IP: $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
            echo "private hostname: $(curl -s http://169.254.169.254/latest/meta-data/hostname)"
            echo "private IP: $(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
        } >> "$DATA_DIR/os-metrics/cloud_info"
    fi
    if [ "$CLOUD" = "GCE" ]; then
        {
            echo "instance type: $(curl -s -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/machine-type|sed -e 's|^.*/\([^/]*\)$|\1|')"
            echo "availability zone: $(curl -s -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/zone|sed -e 's|^.*/\([^/]*\)$|\1|')"
            # echo "public hostname: "
            echo "public IP: $(curl -s -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)"
            echo "private hostname: $(curl -s -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/hostname)"
            echo "private IP: $(curl -s -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)"
        } >> "$DATA_DIR/os-metrics/cloud_info"
    fi
    if [ "$CLOUD" = "Azure" ]; then
        FNAME=$DATA_DIR/os-metrics/cloud_azure
        curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=$AZ_API_VERSION" > $FNAME
        {
            echo "instance type: $(sed -e 's|^.*"vmSize":"\([^"]*\)".*$|\1|' $FNAME)"
            echo "availability zone: $(sed -e 's|^.*"zone":"\([^"]*\)".*$|\1|' $FNAME)"
            echo "public IP: $(sed -e 's|^.*"publicIpAddress":"\([^"]*\)".*$|\1|' $FNAME)"
            echo "private IP: $(sed -e 's|^.*"privateIpAddress":"\([^"]*\)".*$|\1|' $FNAME)"
        } >> "$DATA_DIR/os-metrics/cloud_info"
    fi
}

# Collects OS info
function collect_system_info() {
    debug "Collecting OS level info..."
    if [ "$HOST_OS" = "Linux" ]; then
        if [ -f /etc/lsb-release ]; then
            cp /etc/lsb-release "$DATA_DIR/os-metrics/"
        fi
        if [ -f /etc/os-release ]; then
            cp /etc/os-release "$DATA_DIR/"
        fi
        if [ -f /etc/redhat-release ]; then
            cp /etc/redhat-release "$DATA_DIR/"
        fi
        if [ -f /etc/debian_version ]; then
            cp /etc/debian_version "$DATA_DIR/"
        fi
        if [ -n "$PID" ]; then
            cat "/proc/$PID/limits" > "$DATA_DIR/process_limits" 2>&1
        fi
        cat /sys/kernel/mm/transparent_hugepage/enabled > "$DATA_DIR/os-metrics/hugepage_enabled" 2>&1
        cat /sys/kernel/mm/transparent_hugepage/defrag > "$DATA_DIR/os-metrics/hugepage_defrag" 2>&1
        if [ -n "$(command -v blockdev)" ]; then
            if [ -z "$NOSUDO" ]; then
                sudo blockdev --report 2>&1 |tee > "$DATA_DIR/os-metrics/blockdev_report"
            fi
        else
            echo "Please install 'blockdev' to collect data about devices"
        fi
        if [ -n "$(command -v dmidecode)" ] && [ -z "$NOSUDO" ]; then
            sudo dmidecode |tee > "$DATA_DIR/os-metrics/dmidecode"
        fi
        free > "$DATA_DIR/os-metrics/free" 2>&1
        if [ -n "$(command -v iostat)" ]; then
            if [ "$MODE" != "light" ]; then
                iostat -ymxt 1 "$IOSTAT_LEN" > "$DATA_DIR/os-metrics/iostat" 2>&1
            fi
        else
            echo "Please install 'iostat' to collect data about I/O activity"
        fi
        if [ -n "$(command -v vmstat)" ]; then
            vmstat  -w -t -s > "$DATA_DIR/os-metrics/wmstat-stat" 2>&1
            if [ "$MODE" != "light" ]; then
                vmstat  -w -t -a 1 "$IOSTAT_LEN" > "$DATA_DIR/os-metrics/wmstat-mem" 2>&1
                vmstat  -w -t -d 1 "$IOSTAT_LEN" > "$DATA_DIR/os-metrics/wmstat-disk" 2>&1
            fi
        else
            echo "Please install 'vmstat' to collect data about Linux"
        fi
        if [ -n "$(command -v lscpu)" ]; then
            lscpu > "$DATA_DIR/os-metrics/lscpu" 2>&1
        fi
        ps auxww > "$DATA_DIR/os-metrics/ps-aux.txt" 2>&1
        cat /proc/cpuinfo > "$DATA_DIR/os-metrics/cpuinfo" 2>&1
        cat /proc/meminfo > "$DATA_DIR/os-metrics/meminfo" 2>&1
        cat /proc/interrupts > "$DATA_DIR/os-metrics/interrupts" 2>&1
        cat /proc/version > "$DATA_DIR/os-metrics/version_proc" 2>&1
        if [ -n "$(command -v numactl)" ]; then
            numactl -show > "$DATA_DIR/os-metrics/numactl" 2>&1
            numactl --hardware > "$DATA_DIR/os-metrics/numactl_hardware" 2>&1
        else
            echo "Please install 'numactl' to collect data about NUMA subsystem"
        fi
        # collect information about CPU frequency, etc.
        if [ -d /sys/devices/system/cpu/cpu0/cpufreq/ ]; then
            mkdir -p "$DATA_DIR/os-metrics/cpus/"
            for i in /sys/devices/system/cpu/cpu[0-9]*; do
                CPUN="$(basename "$i")"
                for file in $i/cpufreq/*; do
                    echo "$(basename "$file"): $(cat "$file" 2>/dev/null)" >> "$DATA_DIR/os-metrics/cpus/$CPUN"
                done
            done
        fi
        if [ -f /proc/sys/vm/zone_reclaim_mode ]; then
            cat /proc/sys/vm/zone_reclaim_mode > "$DATA_DIR/os-metrics/zone_reclaim_mode"
        fi
        if [ -f /etc/fstab ]; then
            cp /etc/fstab "$DATA_DIR/os-metrics/fstab"
        fi
        if [ -f /etc/security/limits.conf ]; then
            cp /etc/security/limits.conf "$DATA_DIR/os-metrics/limits.conf"
        fi
        if [ -d /etc/security/limits.d/ ]; then
            mkdir -p "$DATA_DIR/os-metrics/limits.d/"
            cp -r /etc/security/limits.d/* "$DATA_DIR/os-metrics/limits.d/"
        fi

        if [ -n "$(command -v lsblk)" ]; then
            lsblk > "$DATA_DIR/os-metrics/lsblk" 2>&1
            lsblk -oname,kname,fstype,mountpoint,label,ra,model,size,rota > "$DATA_DIR/os-metrics/lsblk_custom" 2>&1
        fi
        if [ -n "$(command -v sar)" ]; then
            sar -B > "$DATA_DIR/os-metrics/sar" 2>&1
        fi
        if [ -n "$(command -v lspci)" ]; then
            lspci> "$DATA_DIR/os-metrics/lspci" 2>&1
        fi
        if [ -n "$(command -v ss)" ]; then
            ss -at > "$DATA_DIR/os-metrics/ss" 2>&1
        fi
        uptime > "$DATA_DIR/os-metrics/uptime" 2>&1

        if [ -n "$(command -v pvdisplay)" ] && [ -z "$NOSUDO" ]; then
            sudo pvdisplay 2>&1|tee > "$DATA_DIR/os-metrics/pvdisplay"
        fi
        if [ -n "$(command -v vgdisplay)" ] && [ -z "$NOSUDO" ]; then
            sudo vgdisplay 2>&1|tee > "$DATA_DIR/os-metrics/vgdisplay"
        fi
        if [ -n "$(command -v lvdisplay)" ] && [ -z "$NOSUDO" ]; then
            sudo lvdisplay -a 2>&1|tee > "$DATA_DIR/os-metrics/lvdisplay"
        fi
        if [ -n "$(command -v lvs)" ] && [ -z "$NOSUDO" ]; then
            sudo lvs -a 2>&1|tee > "$DATA_DIR/os-metrics/lvs"
        fi

        for i in /sys/block/*; do
            DSK="$(basename "$i")"
            if [[ "$DSK" =~ loop* ]]; then
                continue
            fi
            mkdir -p "$DATA_DIR/os-metrics/disks/"
            if [ -n "$(command -v smartctl)" ] && [ -b "/dev/$DSK" ] && [ -z "$NOSUDO" ]; then
                sudo smartctl -H -i "$DM" 2>&1|tee > "$DATA_DIR/os-metrics/disks/smartctl-$DSK"
            fi
            for file in $i/queue/*; do
                if [ -f "$file" ]; then
                    echo "$(basename "$file"): $(cat "$file" 2>/dev/null)" >> "$DATA_DIR/os-metrics/disks/$DSK"
                fi
            done
        done
        if [ -d /sys/devices/system/clocksource/clocksource0/ ]; then
            echo "available: $(cat /sys/devices/system/clocksource/clocksource0/available_clocksource)" > "$DATA_DIR/os-metrics/clocksource"
            echo "current: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)" >> "$DATA_DIR/os-metrics/clocksource"
        fi
        if [ -n "$(command -v dmesg)" ]; then
            dmesg -T > "$DATA_DIR/os-metrics/dmesg"
        fi
        if [ -n "$(command -v ifconfig)" ]; then
            ifconfig > "$DATA_DIR/os-metrics/ifconfig"
            if [ -n "$(command -v ethtool)" ]; then
                mkdir -p "$DATA_DIR/os-metrics/ethtool/"
                for i in $(ifconfig |grep -e '^[a-z]'|cut -f 1 -d ' '); do
                    ethtool -i "$i" > "$DATA_DIR/os-metrics/ethtool/$i" 2>&1
                done
            fi
        fi
        if [ -n "$(command -v netstat)" ]; then
            if [ -z "$NOSUDO" ]; then
                sudo netstat -laputen 2>&1|tee > "$DATA_DIR/os-metrics/netstat"
            fi
        else
            echo "Please install 'netstat' to collect data about network connections"
        fi
        if [ -n "$(command -v netstat)" ]; then
            netstat --statistics > "$DATA_DIR/os-metrics/netstat-stats" 2>&1
        fi

    fi
    df -k > "$DATA_DIR/os-metrics/df" 2>&1
    sysctl -a > "$DATA_DIR/os-metrics/sysctl" 2>&1

    # Collect uname info (for Linux)
    debug "Collecting uname info..."
    if [ "$HOST_OS" = "Linux" ]; then
        cat /etc/*-release > "$DATA_DIR/os.txt"
        {
            echo "kernel_name: $(uname -s)"
            echo "node_name: $(uname -n)"
            echo "kernel_release: $(uname -r)"
            echo "kernel_version: $(uname -v)"
            echo "machine_type: $(uname -m)"
            echo "processor_type: $(uname -p)"
            echo "platform_type: $(uname -i)"
            echo "os_type: $(uname -o)"
        } > "$DATA_DIR/os-info.txt" 2>&1
    # Collect uname info (for MacOS)
    elif [ "$HOST_OS" = "Darwin" ]; then
        {
            echo "hardware_name: $(uname -m)"
            echo "node_name: $(uname -n)"
            echo "processor_type: $(uname -p)"
            echo "os_release: $(uname -r)"
            echo "os_version: $(uname -v)"
            echo "os_name: $(uname -s)"
        } > "$DATA_DIR/os-info.txt" 2>&1
    else
        echo "os type $HOST_OS not catered for or detected" > "$DATA_DIR/os-info.txt" 2>&1
    fi
    # Collect NTP info (for Linux)
    debug "Collecting ntp info..."
    if [ "$HOST_OS" = "Linux" ]; then
        if [ -n "$(command -v ntptime)" ]; then
            ntptime > "$DATA_DIR/ntp/ntptime" 2>&1
        fi
        if [ -n "$(command -v ntpstat)" ]; then
            ntpstat > "$DATA_DIR/ntp/ntpstat" 2>&1
        fi
        if [ -n "$(command -v ntpq)" ]; then
            ntpq -p > "$DATA_DIR/os-metrics/ntpq_p" 2>&1
        fi
    fi
    # Collect Chrony info (for Linux)
    debug "Collecting Chrony info..."
    if [ "$HOST_OS" = "Linux" ]; then
        if [ -n "$(command -v chronyc)" ]; then
            mkdir -p "$DATA_DIR"/os-metrics/chrony
            chronyc tracking > "$DATA_DIR/os-metrics/chrony/tracking" 2>&1
            chronyc sources -v > "$DATA_DIR/os-metrics/chrony/sources" 2>&1
            chronyc sourcestats -v > "$DATA_DIR/os-metrics/chrony/sourcestats" 2>&1
        fi
    fi
    # Collect TOP info (for Linux)
    debug "Collecting top info..."
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
        }' > "$DATA_DIR/os-metrics/cpu.txt" 2>&1
    fi
    # Collect FREE info (for Linux)
    debug "Collecting free info..."
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
                print "swap total: "total"\nswap used: "used"\nswap free: "free}}' > "$DATA_DIR/os-metrics/memory.txt" 2>&1
    fi
    # Collect JVM system info (for Linux)
    debug "Collecting jvm system info..."
    java -version > "$DATA_DIR/java_version.txt" 2>&1
    if [ -n "$PID" ] && [ "$HOST_OS" = "Linux" ] && [ -n "$JAVA_HOME" ] && [ "$MODE" != "light" ]; then
        # TODO: think how to do it without sudo?
        if [ -n "$IS_PACKAGE" ]; then
            sudo -u "$CASS_USER" "$JCMD" "$PID" VM.system_properties 2>&1| tee > "$DATA_DIR/java_system_properties.txt"
            sudo -u "$CASS_USER" "$JCMD" "$PID" VM.command_line 2>&1 |tee > "$DATA_DIR/java_command_line.txt"
        else
            "$JCMD" "$PID" VM.system_properties > "$DATA_DIR/java_system_properties.txt" 2>&1
            "$JCMD" "$PID" VM.command_line > "$DATA_DIR/java_command_line.txt" 2>&1
        fi
    fi
    # Collect Data DIR info
    debug "Collecting disk info..."
    # TODO: rewrite this to be not dependent on OS, plus check both java_command_line.txt & java_cmdline
    if [ "$HOST_OS" = "Linux" ]; then
        # Try to read the data and commitlog directories from config file.
        # The multiple sed statements strip out leading / trailing lines
        # and concatenate on the same line where multiple directories are
        # configured to allow Nibbler to read it as a csv line
        DATA_CONF=$(sed -n '/^data_file_directories:/,/^[^- ]/{//!p;};/^data_file_directories:/d' "$CONF_DIR/cassandra.yaml" | grep -e "^[ ]*-" | sed -e "s/^.*- *//" | tr $'\n' ',' | sed -e "s/.$/\n/")
        COMMITLOG_CONF=$(grep -e "^commitlog_directory:" "$CONF_DIR/cassandra.yaml" |sed -e 's|^commitlog_directory:[ ]*\(.*\)[ ]*$|\1|')
        # Checks the data and commitlog variables are set. If not then
        # read the JVM variable cassandra.storagedir and append paths as
        # necessary.
        if [ -n "$DATA_CONF" ]; then
            echo "data: $DATA_CONF" > "$DATA_DIR/os-metrics/disk_config.txt" 2>&1
        elif [ -f "$DATA_DIR/java_command_line.txt" ]; then
            DATA_CONF=$(tr " " "\n" < "$DATA_DIR/java_command_line.txt" | grep "cassandra.storagedir" | awk -F "=" '{print $2"/data"}')
            echo "data: $DATA_CONF" > "$DATA_DIR/os-metrics/disk_config.txt" 2>&1
        fi
        if [ -n "$COMMITLOG_CONF" ]; then
            echo "commitlog: $COMMITLOG_CONF" >> "$DATA_DIR/os-metrics/disk_config.txt" 2>&1
        elif [ -f "$DATA_DIR/java_command_line.txt" ]; then
            COMMITLOG_CONF=$(tr " " "\n" < "$DATA_DIR/java_command_line.txt" | grep "cassandra.storagedir" | awk -F "=" '{print $2"/commitlog"}')
            echo "commitlog: $COMMITLOG_CONF" >> "$DATA_DIR/os-metrics/disk_config.txt" 2>&1
        fi
        # Since the data dir might have multiple items we need to check
        # each one using df to verify the physical device
        #for DEVICE in $(cat "$CONF_DIR/cassandra.yaml" | sed -n "/^data_file_directories:/,/^$/p" | grep -E "^.*-" | awk '{print $2}')
        for DEVICE in $(echo "$DATA_CONF" | awk '{gsub(/,/,"\n");print}')
        do
            DM="$(df -h "$DEVICE" | grep -v "Filesystem" | awk '{print $1}')"
            if [ -z "$DATA_MOUNT" ]; then
                DATA_MOUNT="$DM"
            else
                DATA_MOUNT="$DATA_MOUNT,$DM"
            fi
        done
        COMMITLOG_MOUNT=$(df -h "$COMMITLOG_CONF" | grep -v "Filesystem" | awk '{print $1}')
        echo "data: $DATA_MOUNT" > "$DATA_DIR/os-metrics/disk_device.txt" 2>&1
        echo "commitlog: $COMMITLOG_MOUNT" >> "$DATA_DIR/os-metrics/disk_device.txt" 2>&1
    fi
}

# Collects data from nodes
function collect_data {
    echo "Collecting data from node $NODE_ADDR..."

    $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/cqlsh $CQLSH_OPTS -e 'describe cluster;' "$CONN_ADDR" "$CONN_PORT" > /dev/null 2>&1
    RES=$?
    if [ "$RES" -ne 0 ]; then
        echo "Can't execute cqlsh command, exit code: $RES. If you're have cluster with authentication,"
        echo "please pass the option -c with user name/password and other options, like:"
        echo "-c '-u username -p password'"
        echo "If you have SSL enabled for client connections, pass --ssl in -c"
        exit 1
    fi

    for i in cassandra-rackdc.properties cassandra.yaml cassandra-env.sh jvm.options logback-tools.xml logback.xml jvm-clients.options jvm-server.options jvm11-clients.options jvm11-server.options jvm8-clients.options jvm8-server.options; do
        if [ -f "$CONF_DIR/$i" ] ; then
            cp $CONF_DIR/$i "$DATA_DIR/conf/cassandra/"
        fi
    done

    # collecting nodetool information
    debug "Collecting nodetool output..."
    for i in cfstats compactionhistory compactionstats describecluster getcompactionthroughput getstreamthroughput gossipinfo info netstats proxyhistograms ring status statusbinary tpstats version cfhistograms; do
        $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/nodetool $NT_OPTS $i > "$DATA_DIR/nodetool/$i" 2>&1
    done

    if [ "$MODE" = "extended" ]; then
        for i in tablestats tpstats ; do
            $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/nodetool $NT_OPTS -F json $i > "$DATA_DIR/nodetool/$i.json" 2>&1
        done
    fi

    # collecting schema
    debug "Collecting schema info..."
    $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/cqlsh $CQLSH_OPTS -e 'describe cluster;' "$CONN_ADDR" "$CONN_PORT" > "$DATA_DIR/driver/metadata" 2>&1
    $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/cqlsh $CQLSH_OPTS -e 'describe schema;' "$CONN_ADDR" "$CONN_PORT" > "$DATA_DIR/driver/schema" 2>&1
    $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/cqlsh $CQLSH_OPTS -e 'describe full schema;' "$CONN_ADDR" "$CONN_PORT" > "$DATA_DIR/driver/full-schema" 2>&1

    # collecting process-related info
    collect_system_info

    # collection of cloud-related information
    collect_cloud_info

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

    for entry in "$CASS_DSE_LOG_DIR"/*.log
    do
        cp $entry "$DATA_DIR/logs/cassandra/"
    done

    if [ "$MODE" == "extended" ]; then
        for entry in "$CASS_DSE_LOG_DIR"/*.log.*
        do
            cp $entry "$DATA_DIR/logs/cassandra/"
        done
    fi
    if [ -f "$DATA_DIR/java_cmdline" ]; then
        GC_LOG="$(sed -e 's|^.* -Xloggc:\([^ ]*\) .*$|\1|' < "$DATA_DIR/java_cmdline")"
        if [ -n "$GC_LOG" ] && [ -f "$GC_LOG" ]; then
            cp "$GC_LOG" "$DATA_DIR/logs/cassandra/"
        fi
    fi

    # Collect metrics from JMX for OSS C* and DDAC
    if [ -n "$IS_COSS" ] ; then
        if [ "$MODE" != "light" ]; then
            $MAYBE_RUN_WITH_TIMEOUT java -jar ~/sjk-plus.jar mxdump $JMX_OPTS > "$DATA_DIR/jmx_dump.json" 2>&1
        fi
    fi

    # The rest of DSE-specific things
    if [ -n "$IS_DSE" ]; then
        if [ -f "$DSE_CONF_DIR/dse.yaml" ]; then
            cp "$DSE_CONF_DIR/dse.yaml" "$DATA_DIR/conf/dse/"
        fi
        if [ -f /etc/default/dse ]; then
            cp /etc/default/dse "$DATA_DIR/conf/dse/"
        fi
        # TODO: decide, if we need to collect Tomcat logs
        # if [ -f "$DATA_DIR/java_cmdline" ]; then
        #     # TOMCAT_DIR="`cat "$DATA_DIR/java_cmdline"|sed -e 's|^.*-Dtomcat.logs=\([^ ]*\) .*$|\1|'`"
        #     # if [ -n "$TOMCAT_DIR" -a -d "$TOMCAT_DIR" ]; then
        #     #
        #     # fi
        # fi

        if [ -f "$CASS_DSE_LOG_DIR/audit/dropped-events.log" ]; then
            mkdir -p "$DATA_DIR/logs/cassandra/audit"
            cp "$CASS_DSE_LOG_DIR/audit/dropped-events.log" "$DATA_DIR/logs/cassandra/audit"
        fi

        # Versions to determine if nodesync available
        DSE_VERSION="$($BIN_DIR/dse -v)"
        DSE_MAJOR_VERSION="$(echo $DSE_VERSION|sed -e 's|^\([0-9]\)\..*$|\1|')"

        debug "Collecting DSE information..."
        if [ "$MODE" != "light" ]; then
            $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/nodetool $NT_OPTS sjk mxdump > "$DATA_DIR/jmx_dump.json" 2>&1
        fi

        for i in status ring ; do
            $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/dsetool $DT_OPTS $i > "$DATA_DIR/dsetool/$i" 2>&1
        done

        if [ "$MODE" != "light" ]; then
            $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/dsetool $DT_OPTS insights_config --show_config > "$DATA_DIR/dsetool/insights_config" 2>&1
            $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/dsetool $DT_OPTS insights_filters --show_filters > "$DATA_DIR/dsetool/insights_filters" 2>&1
            $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/dsetool $DT_OPTS perf cqlslowlog recent_slowest_queries > "$DATA_DIR/dsetool/slowest_queries" 2>&1
            # collect nodesync rate
            if [ "$DSE_MAJOR_VERSION" -gt "5" ]; then
                $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/nodetool $NT_OPTS nodesyncservice getrate > "$DATA_DIR/nodetool/nodesyncrate" 2>&1
            fi
        fi

        # collect DSE Search data
        debug "Collecting DSE Search information..."
		for core in $(grep -e 'CREATE CUSTOM INDEX.*Cql3SolrSecondaryIndex' "$DATA_DIR/driver/schema"  2>/dev/null |sed -e 's|^.* ON \([^ ]*\) (.*).*$|\1|'|tr -d '"' | uniq); do
            debug "collecting data for DSE Search core $core"
            mkdir -p "$DATA_DIR/solr/$core/"
            # it's faster to execute cqlsh than dsetool, but it's internal info
            $BIN_DIR/cqlsh $CQLSH_OPTS -e "select blobAsText(resource_value) from solr_admin.solr_resources where core_name = '$core' and resource_name ='solrconfig.xml.bak' ;"  "$CONN_ADDR" "$CONN_PORT"|grep '<?xml version='|sed -e 's|^ *\(<?xml version=.*\)$|\1|'|sed -e "s|\\\n|\n|g" > "$DATA_DIR/solr/$core/solrconfig.xml" 2>&1
            $BIN_DIR/cqlsh $CQLSH_OPTS -e "select blobAsText(resource_value) from solr_admin.solr_resources where core_name = '$core' and resource_name ='schema.xml.bak' ;"  "$CONN_ADDR" "$CONN_PORT"|grep '<?xml version='|sed -e 's|^ *\(<?xml version=.*\)$|\1|'|sed -e "s|\\\n|\n|g" > "$DATA_DIR/solr/$core/schema.xml" 2>&1
            if [ "$MODE" != "light" ]; then
                #$BIN_DIR/dsetool $DT_OPTS get_core_config "$core" > "$DATA_DIR/solr/$core/config.xml" 2>&1
                #$BIN_DIR/dsetool $DT_OPTS get_core_schema "$core" > "$DATA_DIR/solr/$core/schema.xml" 2>&1
                $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/dsetool $DT_OPTS list_core_properties "$core" > "$DATA_DIR/solr/$core/properties" 2>&1
            fi
            if [ "$MODE" = "extended" ]; then
                $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/dsetool $DT_OPTS core_indexing_status "$core" > "$DATA_DIR/solr/$core/status" 2>&1
                $MAYBE_RUN_WITH_TIMEOUT $BIN_DIR/dsetool $DT_OPTS list_index_files "$core" > "$DATA_DIR/solr/$core/index_files" 2>&1
            fi
        done
        if [ -d "$DATA_DIR/solr/" ]; then
            SOLR_DATA_DIR=$(grep -E '^solr_data_dir: ' "$DSE_CONF_DIR/dse.yaml" 2>&1|sed -e 's|^solr_data_dir:[ ]*\(.*\)$|\1|')
            # if it's not specified explicitly
            if [ -z "$SOLR_DATA_DIR" ] && [ -n "$DATA_CONF" ]; then
                debug "No Solr directory is specified in dse.yaml, detecting from DATA_CONF: $DATA_CONF"
                SOLR_DATA_DIR="$(echo "$DATA_CONF"|sed -e 's|^\([^,]*\)\(,.*\)?$|\1|')/solr.data"
                debug "SOLR_DATA_DIR is defined as: $SOLR_DATA_DIR"
            fi
            if [ -n "$SOLR_DATA_DIR" ] && [ -d "$SOLR_DATA_DIR" ]; then
                cd "$SOLR_DATA_DIR" && du -s -- * 2>&1 > "$DATA_DIR/solr/cores-sizes.txt"
            fi
        fi
    elif [ -n "$IS_COSS" ]; then
        if [ -f /etc/default/cassandra ]; then
            cp /etc/default/cassandra "$DATA_DIR/conf/cassandra/default"
        fi
    fi
}

function collect_insights {
    echo "Collecting insights data"
    if [ -z "$INSIGHTS_DIR" ]; then
        if [ -n "$IS_DSE" ]; then
            INSIGHTS_DIR="$DEFAULT_INSIGHTS_DIR"
            # TODO: naive attempt to parse options - need to do better
            while read line; do
                name=$line
                case $name in
                    *"$INSIGHTS_OPTIONS"*|*"$INSIGHTS_DATA_DIR"*)
                        if [[ $name != \#* ]];
                        then
                            awk '{i=1;next};i && i++ <= 3' $DSE_CONF_DIR/dse.yaml
                            if [[ $name == data_dir* ]]; then
                                INS_DIR="$(echo $name |grep -i 'data_dir:' |sed -e 's|data_dir:[ ]*\([^ ]*\)$|\1|')"
                                if [ -n "$INS_DIR" ] && [ -d "$INS_DIR" ] && [ -d "$INS_DIR/insights" ]; then
	                            INSIGHTS_DIR="$INS_DIR/insights "
                                fi
                                break
                            fi
                        fi
                esac
            done < "$DSE_CONF_DIR/dse.yaml"
        elif [ -n "$IS_COSS" ]; then
            INSIGHTS_DIR="$DEFAULT_MCAC_DIR"
            MCAC_HOME=""
            if [ -f "$DATA_DIR/java_cmdline" ]; then
                MCAC_HOME=$(grep -E -- '-javaagent:[^ ]*/lib/datastax-mcac-agent[^ /]*.jar' "$DATA_DIR/java_cmdline"|sed -e 's|^.*-javaagent:\([^ ]*\)/lib/datastax-mcac-agent[^ /]*.jar.*$|\1|')
            fi
            if [ -z "$MCAC_HOME" ] && [ -f "$CONF_DIR/jvm.options" ]; then
                MCAC_HOME=$(grep -v -h -E '^#' "$CONF_DIR/jvm.options" | grep -E -- '-javaagent:[^ ]*/datastax-mcac-agent[^ /]*.jar'|sed -e 's|^.*-javaagent:\([^ ]*\)/lib/datastax-mcac-agent[^ /]*.jar.*$|\1|')
            fi
            if [ -z "$MCAC_HOME" ] && [ -f "$CONF_DIR/cassandra-env.sh" ]; then
                MCAC_HOME=$(grep -v -h -E '^[ ]*#' "$CONF_DIR/cassandra-env.sh" | grep -E -- '-javaagent:[^ ]*/datastax-mcac-agent[^ /]*.jar'|sed -e 's|^.*-javaagent:\([^ ]*\)/lib/datastax-mcac-agent[^ /]*.jar.*$|\1|')
            fi
            if [ -n "$MCAC_HOME" ] && [ -d "$MCAC_HOME" ]; then
                if [ -f "$MCAC_HOME/config/metric-collector.yaml" ]; then
                    CASS_DATA_DIR=$(grep -e '^data_dir:' $MCAC_HOME/config/metric-collector.yaml|sed -e 's|^data_dir:[ ]*\(.*\)$|\1|')
                    if [ -n "$CASS_DATA_DIR" ]; then
                        INSIGHTS_DIR="$CASS_DATA_DIR/mcac_data/insights"
                    fi
                fi
            else
                echo "No installation of Metric Collector for Apache Cassandra was detected"
            fi
        fi
    fi

    if [ ! -d "$INSIGHTS_DIR" ]; then
        echo "Can't find find directory with insights data, or it doesn't exist! $INSIGHTS_DIR"
        echo "Please pass directory name via -I option (see help)"
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

function collect_ssl_info {
    # Java location is assumed as per L641 but jcmd uses $JAVA_HOME...
    debug "Collecting SSL related information"
    is_client_ssl_enabled=$(find_yaml_sub_property client_encryption_options enabled)
    is_server_ssl_enabled=$(find_yaml_sub_property server_encryption_options internode_encryption)
    if [ ! -z $is_client_ssl_enabled ] && [ $is_client_ssl_enabled = true ]; then
        debug "collecting keystore and truststore for client_encryption_options"
        client_keystore=$(find_yaml_sub_property client_encryption_options keystore)
        client_keystore_pass=$(find_yaml_sub_property client_encryption_options keystore_password)
        client_truststore=$(find_yaml_sub_property client_encryption_options truststore)
        client_truststore_pass=$(find_yaml_sub_property client_encryption_options truststore_password)
        if [ ! -z $client_keystore ] && [ ! -z $client_keystore_pass ]; then
            keytool -list -v -keystore $client_keystore -storepass $client_keystore_pass > "$DATA_DIR/conf/security/client-keystore.txt" 2>&1
        fi
        if [ ! -z $client_truststore ] && [ ! -z $client_truststore_pass ]; then
            keytool -list -v -keystore $client_truststore -storepass $client_truststore_pass > "$DATA_DIR/conf/security/client-truststore.txt" 2>&1
        fi
    fi
    if [ ! -z $is_server_ssl_enabled ]; then
        if [ $is_server_ssl_enabled = "all" ] || [ $is_server_ssl_enabled = "dc" ] || [ $is_server_ssl_enabled = "rack" ]; then
            debug "collecting keystore and truststore for server_encryption_options"
            server_keystore=$(find_yaml_sub_property server_encryption_options keystore)
            server_keystore_pass=$(find_yaml_sub_property server_encryption_options keystore_password)
            server_truststore=$(find_yaml_sub_property server_encryption_options truststore)
            server_truststore_pass=$(find_yaml_sub_property server_encryption_options truststore_password)
            if [ ! -z "$server_keystore" ] && [ ! -z "$server_keystore_pass" ]; then
                keytool -list -v -keystore $server_keystore -storepass $server_keystore_pass > "$DATA_DIR/conf/security/server-keystore.txt" 2>&1
            fi
            if [ ! -z $server_keystore ] && [ ! -z $server_keystore_pass ]; then
                keytool -list -v -keystore $server_truststore -storepass $server_truststore_pass > "$DATA_DIR/conf/security/server-truststore.txt" 2>&1
            fi
        fi
    fi
}

# Two arguments:
# 1) yaml property to begin searching
# 2) yaml subproperty to find under 1
# tolower and stripping quotes could be removed from this function in future to make this more general purpose
# Currenly only supports property values with no spaces
function find_yaml_sub_property {
  awk_str="awk '/$1:/ {
      getline;
      while (\$0 ~ /^\s+|^#/) {
        if (\$1 ~ /^$2:/) {
          print tolower(\$2);
          exit;
        } else {
          getline;
        }
      }
    }'  \"$CONF_DIR/cassandra.yaml\"
    | tr -d \"\\\"'\""
  eval $awk_str
}

function create_directories {
    # Common for COSS / DDAC & DSE
    mkdir -p "$DATA_DIR"/{logs/cassandra,nodetool,conf/cassandra,driver,os-metrics,ntp}
    if [ -n "$IS_DSE" ]; then
        mkdir -p "$DATA_DIR"/{logs/tomcat,dsetool,conf/dse}
    fi
    if [ -n "$COLLECT_SSL" ]; then
        mkdir -p "$DATA_DIR"/conf/security
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
    debug "Removing temp directory $TMP_DIR"
    rm -rf "$TMP_DIR"
}

function adjust_nodetool_params {
    local jmx_port=7199
    local jmx_host=127.0.0.1
    local tmp=""
    
    # Get the JMX user/password from the NT_OPTS and put them in a format that sjk will understand
    JMX_OPTS=$(echo $NT_OPTS | sed -En "s/-u /--username /p" | sed -En "s/-pw /--password /p")

    if [ -f "$DATA_DIR/java_cmdline" ]; then
        tmp=$(grep 'cassandra.jmx.local.port=' "$DATA_DIR/java_cmdline"|sed -e 's|^.*-Dcassandra.jmx.local.port=\([^ ]*\).*$|\1|')
        if [ -n "$tmp" ]; then
            jmx_port="$tmp"
        else
            tmp=$(grep 'cassandra.jmx.remote.port=' "$DATA_DIR/java_cmdline"|sed -e 's|^.*-Dcassandra.jmx.remote.port=\([^ ]*\).*$|\1|')
            if [ -n "$tmp" ]; then
                jmx_port="$tmp"
            fi
            tmp=$(grep 'java.rmi.server.hostname=' "$DATA_DIR/java_cmdline"|sed -e 's|^.*-Djava.rmi.server.hostname=\([^ ]*\).*$|\1|')
            if [ -n "$tmp" ]; then
                jmx_host="$tmp"
            fi
        fi
    fi
    if [ -n "$(command -v nc)" ]; then
        if ! nc -z "$jmx_host" "$jmx_port" ; then
            echo "JMX isn't available at $jmx_host:$jmx_port"
        fi
    fi

    if [ "$jmx_port" != "7199" ]; then
        NT_OPTS="$NT_OPTS -p $jmx_port"
    fi
    if [ "$jmx_host" != "127.0.0.1" ]; then
        NT_OPTS="$NT_OPTS -h $jmx_host"
    fi

    JMX_OPTS="$JMX_OPTS -s $jmx_host:$jmx_port"
}

function checkIP() {

  if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "true"
  else
    echo "false"
  fi

}

# Call functions in order

debug "Collection mode: $MODE"
detect_install
set_paths
get_node_ip
DATA_DIR="$TMP_DIR/$NODE_ADDR"
create_directories
get_pid
adjust_nodetool_params

if [ -n "$INSIGHTS_MODE" ]; then
    collect_insights
else
    collect_data
fi

if [ -n "$COLLECT_SSL" ]; then
    collect_ssl_info
fi

create_archive
cleanup

cd "$OLDWD" || exit 1
