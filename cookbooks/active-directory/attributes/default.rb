default.ad.netbios_name = "cloudamatic"
default.ad.dns_name = "ad.cloudamatic.com"
default.ad.site_name = "AZ1"
default.ad.dn_dc_ou = "Domain Controllers"
default.ad.dn_domain_cmpnt = "dc=ad,dc=cloudamatic,dc=com"
default.ad.computer_ou = nil
default.ad.domain_controller_names = []

# Need to rewrite this to use ad node name instead of windows node name
# This is only for domain controllers. We may want to set domain controller names to a none mu name to make fail over easier.
node.deployment.servers.each_pair { |node_class, nodes|
	nodes.each_pair { |name, data|
		if name == Chef::Config[:node_name]
			my_subnet_id = data['subnet_id']
			if node.ad.domain_controller_names.empty?
				if data['mu_windows_name']
					default.ad.computer_name = data['mu_windows_name']
					default.ad.node_class = node_class
				end
			end
		end
	} rescue NoMethodError
} rescue NoMethodError

default.ad.sites = []
if !node.deployment.vpcs.empty?
	vpc = node.deployment.vpcs[node.deployment.vpcs.keys.first]
	vpc.subnets.each_pair { |name, data|
		default.ad.sites << {
			:name => data['name'],
			:ip_block => data['ip_block']
		}
		if my_subnet_id && my_subnet_id == data['subnet_id']
			default.ad.site_name = "#{data['name']}_#{data['ip_block']}"
		end
	}
end rescue NoMethodError

default.ad.ntds_static_port = 50152
default.ad.ntfrs_static_port = 50154
default.ad.dfsr_static_port = 50156
default.ad.netlogon_static_port = 50158

default.windows_admin_username = "Administrator"
# Credentials for joining an Active Directory domain should be stored in a Chef
# Vault structured like so:
# {
#   "username": "join_domain_user",
#   "password": "join_domain_password"
# }
default.ad.auth = {
	:data_bag => "active_directory",
	:data_bag_item => "join_domain"
}

default.ad.dc_ips = []
if node.ad.dc_ips.empty?
	resolver = Resolv::DNS.new
	node.ad.dcs.each { |dc|
		if dc.match(/^\d+\.\d+\.\d+\.\d+$/)
			default.ad.dc_ips << dc
		else
			begin
				default.ad.dc_ips << resolver.getaddress(dc)
			rescue Resolv::ResolvError => e
				Chef::Log.warn ("Couldn't resolve domain controller #{dc}!")
			end
		end
	} rescue NoMethodError
end
