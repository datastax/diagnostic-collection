# -*- coding: utf-8 -*-
# Copyright 2020 DataStax Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

Feature: OSS Integration tests
    Verify that the collected artifacts are showing the expected data
    When the collection runs against Cassandra OSS without encryption nor auth

    Scenario: Verify logs
        Given artefacts are available in the configured artifacts directory
        Then I can see the "system.log" file in the "logs/cassandra" subdirectory for each node
        And I can see the "debug.log" file in the "logs/cassandra" subdirectory for each node

    Scenario: Verify number of collected nodes
        Given artefacts are available in the configured artifacts directory
        Then 3 folders exist in the "nodes" subdirectory

    Scenario: Verify the presence of jmx metrics
        Given artefacts are available in the configured artifacts directory
        Then 3 folders exist in the "nodes" subdirectory
        And I can parse the metrics file in the first node subdirectory
        And I can find the bean named "org.apache.cassandra.metrics:type=Table,keyspace=system,scope=batchlog,name=PendingFlushes" in the metrics file of the first node

    Scenario: Verify the os related file
        Given artefacts are available in the configured artifacts directory
        Then I can verify the content of the "os-release" file for a random node
        And I can verify the content of the "os-info.txt" file for a random node
        And I can verify the content of the "process_limits" file for a random node
        And I can verify the content of the "java_version.txt" file for a random node
        And I can verify the content of the "java_cmdline" file for a random node