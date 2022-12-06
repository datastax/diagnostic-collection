# Troubleshooting the Collector
The Collector has been designed and built to handle a wide variety of software versions and environmental topologies; this is part of why the configuration has so many options. The purpose of this document is to help provide some techniques to identifying problems encountered when running the collector, and include some work-arounds.

This document assumes you have some basic training and understanding of configuration and Collector execution - you know how to do a "happy path" collection on the toplogy (ssh/Docker/Kubernetes) being used.

---
ℹ️ It is strongly advised that you use the `-v` option when invoking `ds-collector` when you are experiencing problems, as this will capture the output into a dated log file in the base directory (e.g. `/tmp/datastax/ds-collector-2022-05-26-08-46-1653554777.log`). This file is more easily used by you to investigate the problems, and to send to others who may be able to help you.

---

Review of Process
=======

As a reminder, the high-level collector process after invoking `ds-collector` can be found in [PROCESS.md](PROCESS.md).

General Techniques
=======

## Look at Log Output Carefully!
The Collector can spew an overwhelming amount of text to the terminal - text that is not particularly human-friendly. The very last thing on the output is likely not the clue that you need to make sense of what has gone wrong. Scroll up in the log, there will usually be a number of places where `NOTOK` is found, and the first occurance is generally around where the problem resides. Note that the true cause of what has failed may be a few lines above the `NOTOK` line: look for words like `fail` or other similar clues that give you an indication of something not being quite right.

Using the `-v` option sends output to a log file, and this file can then be reviewed in a text editor, where it becomes straight-forward to search for the `NOTOK` text from the beginning of the output! This file is also helpful to have when asking for help/support on problems.

Finally, check the return code with `echo $?` after running the collector...if it is `0` then the collection process was successful, even if the log output might read as it is not successful. 

## Many Errors and Failures are "Okay"
The Collector tries to get a lot of information from the environment, but not all commands and directory permissions allow the Collector to run completely without problem. The Collector is written in such a way that it survives these problems, failing only when a mandatory command is unable to complete successfully. 

## Use `-d` Option While Troubleshooting
Most problems are resolved by making adjustments to the configuration. Rather than getting errors from every node in the cluster, use the `-d` option to `ds-collector`; this will have the collector run on the `-n` node only, and it will not try to run on all the nodes in the cluster. It is by design that the Collector keeps going if one node has a problem; it is trying to get an understanding of the entire cluster and should not fail because one node has a problem.

## Avoid Uploading Artifacts While Troubleshooting
To avoid uploading of artifacts during testing, you can configure `skipS3="true"`.  Remember to comment this out (or set `false`) when you are ready to run the Collector "for real."

## Customize the `update_env()` function
In the `ds-collector` script is a customizable function:

    update_env() {
      # if nodes have specific environments that needs setting up/declaring, do so here
      :
    }

This function can be edited to include any commands, and/or `export` any enviornment variables that need to be in place on each node before information is gathered. It is not a common requirement to do this - most environments are addressable through existing configuration, but just be aware that it is a customization point that can be used!

## When Bastion Cannot Access AWS S3 to Upload
Often, the Bastion exists on a network that cannot reach AWS. To work around this:
- Configure `skipS3="true"` : `sed -i 's/^#?skipS3=.*/skipS3=\"true\"/' collector.conf`
- Run `ds-collector` on the Bastion
- Find a Unix environment that can access both the Bastion and AWS
- Unpack `ds-collector` to this Unix environment, including the secret `.key` file
- Transfer files from the Bastion base directory (e.g. `/tmp/datastax`) to this Unix environment; place them in the same base directory
- Run `ds-collector` on this Linux environment, specifying the `-a` flag ("upload mode"); the collector will not run but the files will upload to S3. 


## Files to be audited/obfuscated before uploading
Some sites have requirements to audit and/or obfuscate the collected files before they are uploaded. To address this:
- Configure `skipS3="true"` : `sed -i 's/^#?skipS3=.*/skipS3=\"true\"/' collector.conf`
- Run `ds-collector`
- When complete, files are in the base directory (e.g. `/tmp/datastax`) on the bastion as `.tar.gz` files. For each file in turn,
    - Unpack the file
    - Review/obfucate
    - Repack into a `.tar.gz` file
- Run `ds-collector`, specifying the `-a` flag ("upload mode"); the node collection process will will not run but the files will upload to S3

## Files to be kept after uploading
If you want to keep the collected files after uploading, configure `keepArtifact="true"` : `sed -i 's/^#?keepArtifact=.*/keepArtifact=\"true\"/' collector.conf`

Known Problems and Issues
=======

This list of problems is most definitely not exhaustive. If you find a new problem, the solution for which is not readily apparent from the Collector feedback nor included on this list, please feel free to add to this list via a Pull Request!

## You are being prompted for a password, possibly for the `root` user
### Condition:

    read configuration from file: completed OK RC=0
    version:
    debugging to /tmp/datastax/ds-collector-2022-05-26-09-58-1653559129.log
    root@ds-collector-tests_cassandra-00_1's password:

### Why it Happens:
During preliminary checks, the Bastion process attempts to connect to the `-n` Node (in the example, `ds-collector-tests_cassandra-00_1`). It is unable to connect, likely because the configuration is not correct.

### What to do:
- Is `root` the right user to connect as? If not, configure `userName=`.
- Do you need to specify a password when connecting as this user? Configure `sshPassword=`, and ensure the Bastion has `sshpass` installed.
- If you are not supposed to specify a password, is the Bastion user's public key in the Nodes `authorized_keys` file?
- Do you need to specify additional arguments to `ssh` command? Configure `sshArgs=` (and you many also need to configure `scpArgs=` at the same time).

If you have a different password for each node, [this change](https://github.com/datastax/diagnostic-collection/issues/129) should facilitate that. But in the interim you will need to either paste in the password for each node, or alternately have a `.conf` file for each node and invoke `ds-collector` (again for each node) with the `-d` option.


## Error indicating `Name or service not known` or `Cluster has 0 nodes` with `exit 5`
### Condition:

    ssh: Could not resolve hostname 10.0.3.13: Name or service not known
    running command set -o pipefail ; nodetool -h 127.0.0.1 -p 7199   status | grep UN | tr -s ' ' | cut -d' ' -f2 on 10.0.3.13 NOTOK RC=255
    Is Cassandra/DSE running on ds-collector-tests_cassandra- ?

or

    + echo 'Expected 6 artifacts. Cluster has 0 nodes.'
    + echo ----
    + '[' true '!=' true ']'
    + return 5
    + exit 5

### Why it Happens:
You have specified a Node with `-n` but the tool has been unable to connect to the Node in order to learn about the cluster. Scroll up in the ouput to where it is trying to `ssh` to the node and run `nodetool`:

    +++ sshpass -p oakytn146 ssh root@ds-collector-tests_****-00_1 -tt -n -t 'set -o pipefail ; nodetool -h 127.0.0.1 -p 7199   status | grep UN | tr -s '\'' '\'' | cut -d'\'' '\'' -f2'
    Pseudo-terminal will not be allocated because stdin is not a terminal.

On the line after this is likely the evidence you need to resolve the problem.

Problem 1: The `sshPassword` is not correct

    Permission denied, please try again.

Problem 2: `-n` Node name is not resolvable from the Bastion

    ssh: Could not resolve hostname ds-collector-tests_****-00_1: Name or service not known

Problem 3: Unable to connect to `127.0.0.1:7199`

    nodetool: Failed to connect to '127.0.0.1:7199' - ConnectException: 'Connection refused (Connection refused)'.

### What to do:
Problems 1 and 2 should be easily addressed by changing the values used. 

Resolution to Problem 3 is more involved as it can occur for a number of reasons. 
- Confirm that Cassandra/DSE is actually up and running on the `-n` Node. This is the most common issue; choose a different `-n` Node.
- When running `nodetool`, do you need to specify `-p`? Configure `jmxPort=`.
- When running `nodetool`, do you need to specify `-u` and/or `-pw`? Configure `jmxUsername=` and/or `jmxPassword=`.
- When running `nodetool`, do you need to specify `--ssl`? Configure `jmxSSL="true"`.
- When running `nodetool`, do you need to specify a value for `-h` other than `127.0.0.1` or `$(hostname)`? This is not currently configurable, you will need to edit `ds-collector` and hard-code `jmxHost=` to an appropriate value. Note this could be a `$(command that gets the correct value)`.

## Error about `nodetool` command not found
### Condition:

    bash: nodetool: command not found
    running command set -o pipefail ; nodetool -h 127.0.0.1 -p 7199   status | grep UN | tr -s ' ' | cut -d' ' -f2 on ds-collector-tests_cassandra-00_1 NOTOK RC=1
    Is Cassandra/DSE running on ds-collector-tests_cassandra-00_1 ?
    WARNING: Not using encryption

### Why it Happens:
While the `addPath` and `prependPath` options can be used for other commands to be found on the node, the `nodetool` command is used before these variables are applied.

### What to do:
Until [this issue](https://github.com/datastax/diagnostic-collection/issues/83) is resolved, you will need to edit `ds-collector` and update the `nodetoolCmd=` variable (assigned in the `list_cassandra_nodes()` function) to be the full path to the `nodetool` script.


## Error about `sudo`
### Condition:

    sudo (without password) is not configured. Configure it, or set skipSudo to true

### Why it Happens:
A number of commands are run using `sudo` (to `root`). You can find these in the `collect-info.rs` script, they will have `use_sudo: true` configured.

### What to do:
While one can configure `skipSudo=true` to bypass these commands, a number of them do provide useful information to a Health Check. If running the collector only for sizing purposes, or to get a general idea as to the health of the cluster, then  `skipSudo=true` would be a reasonable course of action.

It is not a show-stopper to have `skipSudo=true` even in a Health Check context, but the preferable course of action here would be to configure `sudoers` to allow the `userName` to run `sudo` (without password) on each of the nodes, if only temporarily. This will result in the Health Check being able to assess a number of OS-level configuration settings.

## Problems Connecting With `cqlsh`
### Condition:
Failures connecting to `cqlsh` can manifest in a number of ways, but will typically have a command line `cqlsh` followed by `…` and some sort of error text, and the next line being `failed`. For example:

    executing `cqlsh ds-collector-tests_cassandra-00_1 9042  --username=**** --password=**** -f /var/local/tmp/datastax/TEST_artifacts_2022_05_24_1513_1653405227/execute_schema.cql > schema.cql`… Connection error: ('Unable to connect to any servers', {'10.193.204.58': ConnectionShutdown('Connection to 10.193.204.58 was closed',)})
    failed

### Why it Happens:
The Collector attempts to run `cqlsh` from each Node, connecting to the local Node. It is unable to connect for some reason. Usually this is an unspecified username/password but some secured environments have configured for exclusive encryption access.

### What to do:
Set username and password:
- When connecting with `cqlsh`, do you need to specify `-u`? Configure `cqlshUsername=`.
- When connecting with `cqlsh`, do you need to use a password? Configure `cqlshPassword=`.

When the port is not 9042:
- Configure `cqlsh_port=`

When `$(hostname)` resolves to an address that is not being listened to for client connections (this is typically caused by ordering in `/etc/hosts`):
- Configure `cqlsh_host=`. Note this could be a `$(command that gets the correct value)`.

When Client Encryption is required:
- Configure `cqlshSSL="true"`
- You may need to configure `cqlsh_port=` to the secure port
- You may need to specify additional command line options, for example `--cqlshrc=/path/to/cqhshrc`. Configure `cqlshOpts=`.

Other command-line arguments are needed:
- Configure `cqlshOpts=`


## Error: `xxd needs to be installed`
### Condition

    xxd needs to be installed

### Why it Happens:
The `xxd` utility is used to convert a text file included with the collector into a `.jar` file that can be used to process metrics.

### What to do:
You can install the `xxd` utility on the platform (e.g. it is stand-alone package in Ubuntu, included as part of `vim-common` on RHEL). Alternately, you can download the compiled `.jar` file into the same folder on the Bastion as you have unpacked the `ds-collector` script. The `.jar` can be downloaded from [https://github.com/datastax/diagnostic-collection/raw/master/ds-collector/collector-0.17.2.jar](https://github.com/datastax/diagnostic-collection/raw/master/ds-collector/collector-0.17.2.jar).


## Error Involving `cpReadable.sh`
### Condition:

    executing `/var/local/tmp/datastax/etc/cpReadable.sh /var/log/cassandra /var/local/tmp/datastax/TEST_artifacts_2022_05_24_1544_1653407055/logs > `…   usage: /var/local/tmp/datastax/etc/cpReadable.sh sourceDir targetDir

    sourceDir : must be a directory containing files to copy
    targetDir : must be an existing directory, or a valid path where a directory can be created

    failed

### Why it Happens:
Most commonly, it is because the `sourceDir` passed to `cpReadable.sh` (the first argument) is not a directory.

### What to do:
The `targetDir` (second argument) to `cpReadable.sh` will give a clue as to what it was trying to copy.

| `targetDir` | What to do | 
| ---------------- | ---------- | 
| `.../logs` | Configure `logHome=` to the directory containing Cassandra logs | 
| `.../conf` | Configure `confHome=` to the directory containing Cassandra configuration, e.g. `cassandra.yaml` | 
| `.../conf/dse` | This is optional; the Collector is currently hard-coded to look in `/etc/default/dse`. Ignore for now, it is resolved by [this issue](https://github.com/datastax/diagnostic-collection/issues/134) |


## Error about needing space at /tmp/datastax
### Condition:
You may get an error reported like:

    There must be at least 1GB free at /tmp/datastax

Or like:

    A diagnostic collection of 20 nodes requires at least 10GB free at /tmp/datastax

### Why it Happens:
- The Bastion and each Node must have at least 1GB of free space at the base directory (e.g. `/tmp/datastax`). 
- Once the Collector understands how many nodes are in the cluster (in the above example, 20), it multiples this by 500MB and ensures there is enough space in the Bastion base directory (e.g. `/tmp/datastax`).

### What to do:
- Ensure there is sufficient free space available by removing unnecessary files
- Until [this change](https://github.com/datastax/diagnostic-collection/issues/133) is available, you can edit the `ds-collector` script on the Bastion. Change the `baseDir="/tmp/datastax"` to a directory that can be created (via `mkdir -p`) on the Bastion and the Nodes.

## Error about Malformed IPv6 address when running `nodetool` or `dsetool`
### Condition:
You may get an error reported like:

   executing nodetool -h localhost -p 7199 ****  status > nodetool/status.txt... nodetool: Failed to connect to 'localhost:7199' - URISyntaxException: 'Malformed IPv6 address at index 7: rmi://[localhost]:7199'.

### Why it Happens:
- This is a known problem caused by the introduction of Java8 u332 to Cassandra and DSE environments that do not have a patch containing fix for [CASSANDRA-17581](https://issues.apache.org/jira/browse/CASSANDRA-17581)
- More detail is available [here](https://datastaxcommunities.force.com/support/s/article/Malformed-IPv6-address-at-index-7-when-running-nodetool-and-dsetool)

### What to do:
- Until [this change](https://github.com/datastax/diagnostic-collection/issues/152) is available, search for the text `issue/152` in the `ds-collector` script (it appears TWICE), and make the suggested edit in both places.
