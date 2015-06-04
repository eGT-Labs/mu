#
# Cookbook Name:: splunk
# Recipe:: client
#
# Author: Joshua Timberman <joshua@getchef.com>
# Copyright (c) 2014, Chef Software, Inc <legal@getchef.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This recipe encapsulates a completely configured "client" - a
# Universal Forwarder configured to talk to a node that is the splunk
# server (with node['splunk']['is_server'] true). The recipes can be
# used on their own composed in your own wrapper cookbook or role.
include_recipe 'chef-splunk::user'
include_recipe 'chef-splunk::install_forwarder'

if node.splunk.discovery == 'groupname'
	splunk_servers = search(
	  :node,
		"splunk_is_server:true AND splunk_groupname:#{node.splunk_groupname}"
	).sort! do
	  |a, b| a.name <=> b.name
	end
else
  splunk_servers = search( # ~FC003
    :node,
    "splunk_is_server:true AND chef_environment:#{node.chef_environment}"
  ).sort! do
    |a, b| a.name <=> b.name
  end
end

# ensure that the splunk service resource is available without cloning
# the resource (CHEF-3694). this is so the later notification works,
# especially when using chefspec to run this cookbook's specs.
begin
  resources('service[splunk]')
rescue Chef::Exceptions::ResourceNotFound
  if node['platform_family'] != 'windows'
    service 'splunk'
	else
		service 'SplunkForwarder'
	end
end

directory "#{splunk_dir}/etc/system/local" do
  recursive true
	if node['platform_family'] != 'windows'
    owner node['splunk']['user']['username']
    group node['splunk']['user']['username']
	end
end

template "#{splunk_dir}/etc/system/local/outputs.conf" do
  source 'outputs.conf.erb'
  mode 0644 if node['platform_family'] != 'windows'
  variables :splunk_servers => splunk_servers, :outputs_conf => node['splunk']['outputs_conf']
  notifies :restart, 'service[splunk]', :immediately if node['platform_family'] == 'windows'
  notifies :restart, 'service[splunk]' if node['platform_family'] != 'windows'
end

template "#{splunk_dir}/etc/system/local/inputs.conf" do
  source 'inputs.conf.erb'
  mode 0644
  variables :inputs_conf => node['splunk']['inputs_conf']
  notifies :restart, 'service[splunk]'
  not_if { node['splunk']['inputs_conf'].nil? || node['splunk']['inputs_conf']['host'].empty? }
end
directory "/opt/splunkforwarder/etc/apps"
directory "/opt/splunkforwarder/etc/apps/base_logs_unix"
directory "/opt/splunkforwarder/etc/apps/base_logs_unix/local"
template "#{splunk_dir}/etc/apps/base_logs_unix/local/inputs.conf" do
  source 'base_logs_unix_inputs.conf.erb'
  mode 0644
  notifies :restart, 'service[splunk]'
end

include_recipe 'chef-splunk::service'
include_recipe 'chef-splunk::setup_auth'

svr_conf = "#{splunk_dir}/etc/system/local/server.conf"
ruby_block "tighten SSL options in #{svr_conf}" do
	block do
		newfile = []
		File.readlines(svr_conf).each { |line|
			newfile << line
			if line.match(/^\[sslConfig\]/)
				newfile << "useClientSSLCompression = false\n"
				newfile << "sslVersions = tls1.2\n"
				newfile << "cipherSuite = TLSv1.2:!eNULL:!aNULL\n"
			end
		}
		f = File.new(svr_conf, File::CREAT|File::TRUNC|File::RDWR)
		f.puts newfile
		f.close
	end
	not_if "grep ^sslVersions #{svr_conf}"
  notifies :restart, 'service[splunk]'
end
