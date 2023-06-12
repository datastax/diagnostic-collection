# DataStax Diagnostic Collector for Apache Cassandra&trade; and DataStax Enterprise (DSE) &trade;

A script for collecting a diagnostic snapshot from each node in a Cassandra based cluster.

The code for the collector script is in the _ds-collector/_ directory. It must first be built into a collector tarball.

This collector tarball is then extracted onto a bastion or jumpbox that has access to the nodes in the cluster. Once extracted, the configuration file (collector.conf) can be edited to match any cluster deployment customisations (e.g. non-default port numbers, non-default log location, etc). The ds-collector script can then be executed; first in test mode and then in collection mode.

# Pre-configuring the Collector Configuration
When building the collector, it can be instructed to pre-configure the collector.conf by setting the following variables:

```bash
# If the target cluster being collected is DataStax Enterprise, please set is_dse=true, otherwise it will assume Apache Cassandra.
export is_dse=true
# If the target cluster is running on docker containers, please set is_docker=true, this will result in the script issuing commands via docker and not ssh.
export is_docker=true
# If the target cluster is running on k8s, please set is_k8s=true, this will result in the script issueing commands via kubectl and not ssh.
export is_k8s=true
```

If no variables are set, then the collector will be pre-configured to assume Apache Cassandra running on hosts which can be accessed via SSH.

# Building the Collector
Build the collector using the following make command syntax. You will need make and Docker.

```bash
# The ISSUE variable is typically a JIRA ID, but can be any unique label
export ISSUE=<JIRA_ID>
make
```

This will generate a _.tar.gz_ tarball with the `issueId` set in the packaged configuration file. The archive will named in the format `ds-collector.$ISSUE.tar.gz`.

# Building the Collector with automatic s3 upload ability

If the collector is built with the following variables defined, all collected diagnostic snapshots will be encrypted and uploaded to a specific AWS S3 bucket. Encryption will use a one-off built encryption key that is created locally.

```bash
export ISSUE=<JIRA_ID>
# AWS Key and secret for S3 bucket, where the diagnostic snapshots will be uploaded to
export COLLECTOR_S3_BUCKET=yourBucket
export COLLECTOR_S3_AWS_KEY=yourKey
export COLLECTOR_S3_AWS_SECRET=yourSecret
make
```

To use this feature you will need the aws-cli and openssl installed on your local machine as well.

This will then generate a .tar.gz tarball as described above, additionally with the AWS credentials set in the packaged configuration file, and the bucket name set within the ds-collector script.

In addition to the _.tar.gz_ tarball, an encryption key is now generated. The encryption key must be placed in the same directory as the extracted collector tarball for it to execute. If the tarball is being sent to someone else, it is recommeneded to send the encryption key via a different (and preferably secured) medium.

# Storing Encryption keys within the AWS Secrets Manager
The collector build process also supports storing and retrieving keys from the AWS secrets manager, to use this feature, 2 additional environment variables must be provided before the script is run.

```bash
export ISSUE=<JIRA_ID>
# AWS Key and secret for S3 bucket, where the diagnostic snapshots will be uploaded to
export COLLECTOR_S3_BUCKET=yourBucket
export COLLECTOR_S3_AWS_KEY=yourKey
export COLLECTOR_S3_AWS_SECRET=yourSecret
# AWS Key and secret for Secrets Manager, where the one-off build-specific encryption key will be stored
export COLLECTOR_SECRETSMANAGER_KEY=anotherKey
export COLLECTOR_SECRETSMANAGER_SECRET=anotherSecret
make
```

When the collector is built, it will also upload the generated encryption key to the Secrets Manager, as defined by the COLLECTOR_SECRETSMANAGER_* variables.

Please be careful with the encryption keys. They should only be stored in a secure vault (such as the AWS Secrets Manager), and temporarily on the jumpbox or bastion where and while the collector script is being executed. The encryption key ensures the diagnostic snapshots are secured when transferred over the network and stored in the AWS S3 bucket.

# Executing the Collector Script against a Cluster

Instructions for execution of the Collector script are found in `ds-collector/README.md`. These instructions are also bundled into the built collector tarball.
