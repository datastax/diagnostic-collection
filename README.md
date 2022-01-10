# DataStax Diagnostic Collector for Apache Cassandra&trade; and DataStax Enterprise (DSE) &trade;

A script for collecting a diagnostic snapshot from each node in a Cassandra based cluster.

The code for the collector script is in the _ds-collector/_ directory. It must first be built into a collector tarball.

This collector tarball is then extracted onto a bastion or jumpbox that has access to the nodes in the cluster. Once extracted, the configuration file (collector.conf) can be edited to match any cluster deployment customisations (e.g. non-default port numbers, non-default log location, etc). The ds-collector script can then be executed; first in test mode and then in collection mode.

# Building the Collector

Build the collector using the following make command syntax. You will need make and Docker.


```bash
# The ISSUE variable is typically a JIRA ID, but can be any unique label
export ISSUE=<JIRA_ID>
make
```

This will generate a _.tar.gz_ tarball with the `issueId` set in the packaged configuration file. The archive will named in the format `ds-collector.$ISSUE.tar.gz`.

# Building the Collector with automatic upload ability

If the collector is built with the following variables defined, all collected diagnostic snapshots will be encrypted and uploaded to a specific AWS S3 bucket. Encryption will use a one-off built encryption key, that will be stored in an AWS Secrets Manager.

```bash
# AWS Key and secret for S3 bucket, where the diagnostic snapshots will be uploaded to
export COLLECTOR_S3_AWS_KEY=xxx
export COLLECTOR_S3_AWS_SECRET=yyy
# AWS Key and secret for Secrets Manager, where the one-off build-specific encryption key will be stored
export COLLECTOR_SECRETSMANAGER_KEY=zzz
export COLLECTOR_SECRETSMANAGER_SECRET=qqq
```

After the keys and secrets are defined in the environment, the process to build the collector is the same as described above. To use this feature you will need the aws-cli and openssl installed on your local machine as well.

```bash
export ISSUE=<JIRA_ID>
make
```

This will then generate a .tar.gz tarball as described above, additionally with the AWS credentials set in the packaged configuration file.

In addition to the _.tar.gz_ tarball, an encryption key is now generated. The encryption key must be placed in the same directory as the extracted collector tarball for it to execute. If the tarball is being sent to someone else, it is recommeneded to send the encryption key via a different (and preferably secured) medium. The key is also uploaded to Secrets Manager, as defined by the COLLECTOR_SECRETSMANAGER_* variables.

Please be careful with the encryption key. It should only be stored in the Secrets Manager, and temporarily on the jumpbox or bastion where and while the collector script is being executed. The encryption key ensures the diagnostic snapshots are secured when transferred over the network and stored in the AWS S3 bucket.

# Executing the Collector Script against a Cluster

Instructions for execution of the Collector script are found in `ds-collector/README.md`. These instructions are also bundled into the built collector tarball.
