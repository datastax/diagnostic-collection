# Collector Process Overview

The Collector has been designed and built to handle a wide variety of software versions and environmental topologies; this is part of why the configuration has so many options. The purpose of this document is to help provide some techniques to identifying problems encountered when running the collector, and include some work-arounds.


1. Do basic checks on the Bastion: can we make `baseDir` (e.g. `/tmp/datastax`), and do we have the right commands available?
2. If doing `-T` test mode:
    - Connect to the `-n` Node if it is not a file, and get list of nodes via `nodetool status`
    - Confirm the command `date` can be invoked on each Node
3. Connect to the `-n` Node if it is not a file, and get list of nodes via `nodetool status`
4. For each Node in the list:
    - Transfer a number of files from the Bastion to the Node
    - Run the collection script on the node
    - Pull the collected `.tar.gz` tarball back to the Bastion
    - Remove collected `.tar.gz` from the Node
5. For each collected `.tar.gz` file on the Bastion:
    - Encrpyt the file if so configured
    - Send the file to S3 if so configured
    - Remove the file if it has been transferred to S3, and if `keepArtifact=` is not configured, or set to `false`.
    - Files not uploaded will remain on the Bastion in the `baseDir`

