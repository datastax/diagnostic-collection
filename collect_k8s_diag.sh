#!/usr/bin/env bash
#
# File: collect_k8s_diag.sh
#
# Created: Wed, Oct 6, 2021
# Modified: $Format:%cD$
# Hash: $Format:%h$
#
# This script collects diagnostic from multiple nodes of cluster via kubectl
##

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "You need to use Bash 4 or higher, but you have ${BASH_VERSION}"
    exit 1
fi

function usage() {
    echo "Usage: $0 <dcname> <namespace>"
    echo " ----- Required --------"
    echo "   dcname -  the kubernetes CassandraDataCenter name"
    echo "   namespace - the namespace where you can find the CassandraDataCenter"
}


if [ "$#" -ne 2 ]; then
    usage
   exit 1
fi

DC=$1
NS=$2
CLUSTER_NAME=$(kubectl get cassandradatacenter -n $NS -o json | jq -r ".items[0].spec.clusterName")
NUMBER_NODES=$(kubectl get cassandradatacenter -n $NS -o json | jq -r ".items[0].spec.size")
SECRET_NAME=$CLUSTER_NAME-superuser
CASS_USER=$(kubectl -n $NS get secret $SECRET_NAME -o json | jq -r '.data.username' | base64 --decode)
CASS_PASS=$(kubectl -n $NS get secret $SECRET_NAME -o json | jq -r '.data.password' | base64 --decode)
COLLECT_DATE="$(date -u '+%Y-%m-%d_%H_%M_%S')"
DIR=$CLUSTER_NAME-diagnostics-${COLLECT_DATE}
TAR=""
NODE_NAME=""

function copy_node() {
    echo "moving ./collect_node_diag.sh to $NODE_NAME"
    kubectl cp -n $NS -c cassandra ./collect_node_diag.sh $NODE_NAME:/opt/dse/collect_node_diag.sh
    kubectl exec -n $NS $NODE_NAME  -it -c cassandra -- /opt/dse/collect_node_diag.sh -z -t dse -P /opt/dse -c "-u $CASS_USER -p $CASS_PASS"
    echo "capturings logs for $NODE_NAME"
    TAR=$(kubectl exec -n $NS -it $NODE_NAME -c cassandra -- ls -l  /var/tmp/ | grep ".tar.gz" | awk '{print $9}' | tr -d '\r')
    kubectl exec -n $NS $NODE_NAME  -it -c cassandra -- rm /opt/dse/collect_node_diag.sh
    echo "retrieving tarball '$TAR' from $NODE_NAME"
    if [ -z "$TAR" ]
    then
        echo "WARN no tarball collected for node $NODE_NAME skipping"
    else
        kubectl cp -n $NS -c cassandra $NODE_NAME:/var/tmp/$TAR $DIR/nodes/$TAR
        kubectl exec -n $NS $NODE_NAME  -it -c cassandra -- rm /var/tmp/$TAR
        tar zxvf $DIR/nodes/$TAR  -C $DIR/nodes/
        rm $DIR/nodes/$TAR
    fi
}

mkdir -p $DIR/nodes

NODES=$(kubectl get pods -n $NS -l cassandra.datastax.com/datacenter=$DC -o name)
for node in $NODES
do
   NODE_NAME=${node:4}
   echo "copying node $NODE_NAME"
   copy_node
done

tar czvf diagnostic.tar.gz $DIR
rm -fr $DIR
