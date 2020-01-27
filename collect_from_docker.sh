#!/bin/bash
#
# File: collect_from_docker.sh
#
# Created: Friday, June 21 2019
#

COLLECT_OPTS="-i"
DEST_DIR=/var/tmp/
for host in `docker ps|grep dse-server|cut -f 1 -d ' '`; do
    docker cp collect_node_diag.sh ${host}:/var/tmp/
    LFILE=/var/tmp/${host}.log
    docker exec -ti $host /var/tmp/collect_node_diag.sh $COLLECT_OPTS /opt/dse 2>&1 > $LFILE
    IFILE=`cat $LFILE|tr -d '\r'|grep 'Data is collected into'|sed -e 's|^Data is collected into \(.*\)$|\1|'`
    if [ -n "$IFILE" ]; then
        docker cp ${host}:${IFILE} $DEST_DIR
        docker exec $host rm ${IFILE}
    else
        echo "Can't generate diagnostic file"
        cat $LFILE
    fi
    rm -f $LFILE
done
./generate_diag.sh $COLLECT_OPTS -r $DEST_DIR
