ds-collector
=============

This script will connect to a target host generate an artifact bundle and transfer that bundle back to the execution host. From there they are pushed to a "dead drop" S3 bucket using HTTPS.

The package contains the three files:

* `ds-collector` the script that does the work.
* `collector.conf` configuration settings, see help in the file.
* `collector.hosts` optional list of hosts to get information from.


Usage
-----

```
usage: ds-collector [option1] [option2] [option...] [mode]

options:
-n=[HOST_IP | HOST_NAME | HOST_FILE_PATH]   IP address or hostname of Cassandra node to obtain
                                              the list of hosts to run collector on. Can also
                                              specify path to file with list of nodes or
                                              ip addresses.
-f=CONFIG_FILE_PATH     Path to a configuration file. Will override all defaults and options.
-a=ARTIFACT_PATH        Path to single artifact to upload to s3.
-p                      Ping the host prior to connecting to it. Can only be used with Test Mode.
-d                      Run script on a single node only, disabling auto discovery when the -n
                          option specifies a hostname or IP address. Can only be used with
                          Test Mode and Execute Mode.
-h                      Print this help and exit.

modes:
-T  Test Mode:      Complete a connection test.
-X  Execute Mode:   Execute collector on a cluster using arguments passed above.
-C  Client Mode:    Execute collector for only the node this script is run on. (internal use only)
```

Directions
----------

* Extract the three files to your central host (e.g. bastion or jumpbox). Do not run this script on a Cassandra/DSE node.
* Copy the generated encryption key into the same directory as the ds-collector script.
* Make sure the correct permissions are set on the ds-collector so it is executable.
    ```
    chmod +x ds-collector
    ```
* Update `collector.conf` variable "userName" to the name of a user who can log into the nodes.
* You must be able to ssh from the central host to each node, using ssh agent forwarding, an identity file, or sshpass.
* Update all other options in `collector.conf` accordingly.
* Test the connection with command
    ```
    ./ds-collector -T -f collector.conf -n <contact point>
    ```
* If test returns `NOTOK` please notify DataStax via email including the message.
* Run the script to collect data and script will automatically upload to a secure S3 bucket.
    ```
    ./ds-collector -X -f collector.conf -n <CASSANDRA_CONTACT_POINT>
    ```
* If you need to run the collector against a single node only use the `-d` option.
    ```
    ./ds-collector -X -d -f collector.conf -n <CASSANDRA_CONTACT_POINT>
    ```
* If you need to manually transfer a single file, use the `-a` option followed by the path to the file
    ```
    ./ds-collector -f collector.conf -a /tmp/heap_dump_001.gz
