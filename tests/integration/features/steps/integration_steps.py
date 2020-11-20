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


import configparser
import json
import os
import random

from behave import given, when, then

@given(r'artefacts are available in the configured artifacts directory')
def _artefacts_are_available_in_the_configured_artifacts_directory(context):
    assert os.path.isdir(context.artifact_directory)

@then(u'{nb_folders} folders exist in the "{subfolder_name}" subdirectory')
def _folders_exist_in_the_subdirectory(context, nb_folders, subfolder_name):
    folders = get_nodes(context)
    print("folders ({}): {}".format(len(folders), folders))

    assert len(folders) == int(nb_folders)

@then(u'I can see the "{expected_file}" file in the "{subdirectory}" subdirectory for each node')
def _i_can_see_the_file_in_the_subdirectory_for_each_node(context, expected_file, subdirectory):
    for folder in get_nodes(context):
        assert os.path.isfile(os.path.join(context.artifact_directory, "nodes", folder, subdirectory, expected_file))

@then(u'I can parse the metrics file in the first node subdirectory')
def _i_can_parse_the_metrics_file(context):
    _parse_metrics_file_of_the_first_node(context)

@then(u'I can find the bean named "{bean_name}" in the metrics file of the first node')
def _i_can_find_the_bean_named(context, bean_name):
    json_metrics = _parse_metrics_file_of_the_first_node(context)    
    for bean in json_metrics['beans']:
        if bean["name"] == bean_name:
            return
    
    print("Couldn't find the following bean in the metrics dump: {}".format(bean_name))
    assert False

@then(u'I can verify the content of the "{filename}" file for a random node')
def _i_can_verify_the_content_of_the_file_for_a_random_node(context, filename):
    if filename == "os-release":
        verify_os_release(context)
    elif filename == "os-info.txt":
        verify_os_info(context)
    elif filename == "debian_version":
        verify_debian_version(context)
    elif filename == "java_cmdline":
        verify_java_cmdline(context)
    elif filename == "java_version.txt":
        verify_java_version(context)
    elif filename == "process_limits":
        verify_process_limits(context)
    elif filename == "ps-aux.txt":
        verify_ps_file(context)

def verify_os_release(context):
    node = get_random_node_path(context)
    parser = parse_config_file(os.path.join(context.artifact_directory, "nodes", node, "os-release"))
    assert str(parser["DUMMY"]["NAME"]) == '"Ubuntu"'

def verify_os_info(context):
    node = get_random_node_path(context)
    parser = parse_config_file(os.path.join(context.artifact_directory, "nodes", node, "os-info.txt"))
    assert parser["DUMMY"]["kernel_name"] == "Linux"

def verify_debian_version(context):
    node = get_random_node_path(context)
    with open(os.path.join(context.artifact_directory, "nodes", node, "debian_version")) as fp:
        assert float(fp.read()) >= 9.0

def verify_java_cmdline(context):
    node = get_random_node_path(context)
    with open(os.path.join(context.artifact_directory, "nodes", node, "java_cmdline")) as fp:
        assert "org.apache.cassandra.service.CassandraDaemon" in fp.read()

def verify_java_version(context):
    node = get_random_node_path(context)
    with open(os.path.join(context.artifact_directory, "nodes", node, "java_version.txt")) as fp:
        assert "1.8.0" in fp.read()

def verify_process_limits(context):
    node = get_random_node_path(context)
    with open(os.path.join(context.artifact_directory, "nodes", node, "process_limits")) as fp:
        content = fp.read()
        assert "Max open files" in content
        assert "Max file locks" in content

def verify_ps_file(context):
    node = get_random_node_path(context)
    with open(os.path.join(context.artifact_directory, "nodes", node, "os-metrics/ps-aux.txt")) as fp:
        assert "org.apache.cassandra.service.CassandraDaemon" in fp.read()

def get_nodes(context):
    return list(filter(
            lambda folder: not folder.startswith("."),
            os.listdir(os.path.join(context.artifact_directory, "nodes"))
        ))

def get_first_node_path(context):
    return get_nodes(context)[0]

def get_random_node_path(context):
    nodes = get_nodes(context)
    return nodes[random.randint(0, len(nodes)-1)]

def parse_config_file(filename):
    with open(filename) as fp:
        content = fp.read()
        p = configparser.ConfigParser()
        p.read_string("""
        [DUMMY]
        """ + content)
        return p

def _parse_metrics_file_of_the_first_node(context):
    first_node_folder = get_first_node_path(context)
    with open(os.path.join(context.artifact_directory, "nodes", first_node_folder, "jmx_dump.json"), 'r') as metrics_file:
        return json.load(metrics_file)
