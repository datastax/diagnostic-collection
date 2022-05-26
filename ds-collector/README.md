DataStax Diagnostic Collector for Apache Cassandra&trade; and DataStax Enterprise (DSE)&trade;
===============================================================================================

The Diagnostic Collector bundle is used to collect diagnostic snapshots over all nodes in an Apache Cassandra or DataStax Enterprise cluster. 

It can be run on Linux or Mac server that has ssh/docker/k8s access to the nodes in the cluster. It cannot be directly run on a node in the cluster.



Quick Start
-----------

Just do it, the following instructions ​work for most​ people.

```
# extract the bundle on the jumpbox/bastion server (this cannot be a Cassandra node)
tar -xvf ds-collector.*.tar.gz
cd collector

# if an encryption file has been provided, copy it to this folder
cp <some-path>/*_secret.key .

# go through the configuration file, set all parameters as suited
edit collector.conf

# test connections to all nodes can be made, replace <CASSANDRA_CONTACT_POINT> with the ip of a Cassandra node 
# one node is enough, the ips of the other nodes will be found automatically.
./ds-collector -T -f collector.conf -n <CASSANDRA_CONTACT_NODE>

# collect diagnostics from every node
./ds-collector -X -f collector.conf -n <CASSANDRA_CONTACT_NODE>
```

If "NOTOK" appears in any of the output, then troubleshoot… you can find some troubleshooting guidelines in [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

 
<br /> 
 
---


Full Instructions
=================

**Contents**

* Full Instructions
  * Usage
  * Directions
* Recipes
* Troubleshooting
* What is Collected
* Limitations
* Contact


The collector tool (the ds-collector script and associated files) is used to collect diagnostic snapshots from every node in a cluster from the command line. 

Provided is either a casandra_contact_node or the path to the collector.hosts file. With a casandra_contact_node specified the script will discover and collect diagnostics from all nodes in the cluster. With a collector.hosts file specified the script will collect diagnostics only from those nodes listed in the file. 

For each node the script performs a number of steps: connect to a target host and upload script, binary and configuration files, execute the script in client mode collecting all diagnostic information, generate an artifact tarball of all this information, and then transfer that bundle back to the execution host. 

Once all nodes have been collected, the script on the bastion/jumpbox then may encrypt all the diagnostic node tarballs, and upload them to the configured S3 bucket.

Files of note in the bundle are:

* `ds-collector` the script that does the work.
* `collector.conf` configuration settings, see help in the file. Must be configured before first run.
* `collector.hosts` optional, list of hosts to get information from, skips the discovery process.
* `collector-*.jar` custom jar of the jmx_exporter library, from which JmxExporter.class is used.
* `dstat` vanilla upstream copy of the dstat binary, bundled for systems without it installed.
* `collect-info` custom binary used for most of the diagnostic execution.
* `rust-commands/` source code to the `collect-info` binary, only provided for (optional) auditing purposes.


Help and Usage
--------------

For help on usage and all command line options, run:
```
./ds-collector -h
```
The help displayed comes from the `ds-collector` scripts [`hjalp`](https://github.com/datastax/diagnostic-collection/blob/master/ds-collector/ds-collector#L727-L752) function.

Directions
----------

* Extract the three files to your central host (e.g. bastion or jumpbox). Do not run this script on a Cassandra/DSE node.
```
tar -xvf ds-collector.*.tar.gz
cd collector
```

* If an encryption key has been provided, copy it to the same extracted directory (where the ds-collector script is found).
```
cp <path-to-encryption-file>/*_secret.key .
```

* Make sure the correct permissions are set on the ds-collector so it is executable.
```
ls -l ds-collector
chmod +x ds-collector
```

* Update `collector.conf`, read through the file and configure each option if and as neccessary. Do not change `issueId`, `keyId`, or `keySecret`.

* Test the connection with command. `-T` invokes test mode. `-f …` is used to specify the configuration file. `-n …` is used to provide one alive Cassandra/DSE node in the cluster to contact with to discover the other nodes in the cluster. The `-p` option can also be added to first test with a ping to the contact node specified.
```
./ds-collector -T -f collector.conf -n <CASSANDRA_CONTACT_NODE>
```

* If test returns `NOTOK` please notify us including the message.

* Run the script to collect data. `-X` invokes the execute mode. Diagnostic snapshots will be collected from all reachable nodes. Also, if enabled the script will encrypt the diagnostic tarballs, and upload them to a secure S3 bucket. 
```
./ds-collector -X -f collector.conf -n <CASSANDRA_CONTACT_NODE>
```

* If the run returns `NOTOK` please notify us including the message.


The script, with the same configuration and encryption key, can be run multiple times as diagnostic snapshots are timestamped.

Recipes
=======

* To run the collector against a single node only, use the `-d` option.
```
./ds-collector -X -d -f collector.conf -n <CASSANDRA_NODE>
```

* To run the collector against a specified list of nodes only, disabling the discovery of all nodes, use the `collector.hosts` file. The format of this file is each entry on a separate line, with the last line blank.
```
./ds-collector -X -d -f collector.conf -n collector.hosts
```

* To collect diagnostics from nodes in different data centers, where one bastion/jumpbox cannot access all. Run the collector separately in each data center, nodes that are unreachable will be ignored. Let us know when the collector has been run against all data centers.

* To manually transfer all files in a directory, use the `-a` option followed by the path to the directory
```
./ds-collector -f collector.conf -a /tmp/datastax
```

* To manually transfer a single file, use the `-a` option followed by the path to the file
```
./ds-collector -f collector.conf -a /tmp/datastax/some-node_artifacts_some_timestamp.tar.gz.enc
```

* To run the collector on a Cassandra/DSE node (and only that node).
```
cd /tmp/
tar -xvf <path-to-bundle>/<bundle>.tar.gz
mv collector datastax
cd datastax
wget https://github.com/datastax/diagnostic-collection/raw/master/ds-collector/collector-0.11.1-SNAPSHOT.jar
# edit collector.conf, then run the ds-collector in client-mode
./ds-collector -C -f collector.conf 
# if the node has internet access, upload directly to s3
./ds-collector -f collector.conf -a some-node_artifacts_some_timestamp.tar.gz
```

* Auditing the diagnostic tarballs before uploading them. If you need to audit the contents of the tarballs before they are securely uploaded to us, do the following
```
sed -i 's/^#?keepArtifact=.*/keepArtifact=\"true\"/'
sed -i 's/^#?skipS3=.*/skipS3=\"true\"/'

./ds-collector -X -f collector.conf -n <CASSANDRA_CONTACT_NODE>

# audit files in /tmp/datastax/

# when ready to upload to s3
./ds-collector -f collector.conf -a /tmp/datastax
```

Troubleshooting
===============

* The script is failing and the error message is not clear. Please enable verbose in the script by adding the `-v` option on the command line. Run the script again. If the failure is still unclear, contact us for further help attaching the log files found in `/tmp/datastax`.

* The bastion/jumpbox does not have an internet access and the s3 upload fails. In this scenario, pull the diagnostic tarballs onto a machine that does have internet access and upload from there.
```
scp -r <bastion/jumpbox>:/path-to-collector-folder> .
scp -r <bastion/jumpbox>:/tmp/datastax .

cd collector
./ds-collector -f collector.conf -a "$(pwd)/../datastax"
```

* To run the collector when `xxd` is unavailable on the bastion, manually download the `collector-0.11.1-SNAPSHOT.jar` file to the `collector/` folder.
```
cd collector
wget https://github.com/datastax/diagnostic-collection/raw/master/ds-collector/collector-0.11.1-SNAPSHOT.jar
```

* The `nodetool` command is not found in $PATH on the nodes. While the `addPath` and `prependPath` options (see collector.conf) can be used for other commands to be found on the node, the `nodetool` command is used before these variables are applied. To fix this manually update the `nodetoolCmd` variable in the `list_cassandra_nodes` function in the `ds-colllector` script. (See https://github.com/datastax/diagnostic-collection/issues/83 )

* Disabling the s3 upload. The artifacts will be left in the `/tmp/datastax/` folder.
```
sed -i 's/^#?skipS3=.*/skipS3=\"true\"/'
```

* Keeping the artifacts on disk after the s3 upload
```
sed -i 's/^#?keepArtifact=.*/keepArtifact=\"true\"/'
```


What is Collected
=================

The script collects following information:

* Cassandra/DSE configuration files - e.g. `cassandra.yaml` and `dse.yaml`
* Cassandra/DSE log files 
* data from `nodetool` and `dsetool` sub-commands, like, `status`, `ring`, `tablestats`, `tpstats`, etc.
* jmx metrics
* database schema
* the Statistics.db files for each SSTable
* schema and configuration for DSE Search cores
* system information to help identify the problems caused by incorrect system settings
  * information about CPUs, block devices, disks, memory, etc.
  * information about operating system (name, version, etc.)
  * limits for user that runs Cassandra/DSE
  
  
The following are expected to be installed on the Cassandra/DSE nodes: `blockdev`, `curl`, `date`, `df`, `ethtool`, `hostname`, `iostat`, `ip`, `lsblk`, `lsof`, `lspci`, `lvdisplay`, `lvs`, `netstat`, `ntpq`, `ntpstat`, `numactl`, `ps`, `pvdisplay`, `sar`, `slabtop`, `sysctl`, `timeout`, `uname`, and `uptime`.


On a debian/ubuntu server these can be installed by running:
```
apt-get install -y procps  ethtool  lsof  net-tools  sysstat pciutils ntp ntpstat numactl lvm2 curl
```

**Important**: no sensitive information is collected. See the `audit.log` file generated for a list of commands executed on each node.


Limitations
===========

* The collector script can run on a Linux or MacOS bastion/jumpbox.
* The collector script can only collect from Cassandra/DSE nodes that are running Linux.
* The collector script can only collect from Cassandra versions 1.2 and above.

For other limitations, please see the list of open [Issues](https://github.com/datastax/diagnostic-collection/issues) and [PRs](https://github.com/datastax/diagnostic-collection/pulls).

Contact
=======

For questions, to report an issue, to request a feature/enhancement, etc., please use [GitHub Issue](https://github.com/datastax/diagnostic-collection/issues/new) or visit our Community Forums: https://community.datastax.com
