# Copyright:: Copyright (c) 2018 eGlobalTech, Inc., all rights reserved
#
# Licensed under the BSD-3 license (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License in the root of the project or at
#
#     http://egt-labs.com/mu/LICENSE.html
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'open-uri'
require 'json'
require 'timeout'

module MU
  class Cloud
    # Support for Microsoft Azure as a provisioning layer.
    class Azure
      @@is_in_azure = nil
      @@metadata = nil
      @@acct_to_profile_map = nil #WHAT EVEN IS THIS? 
      @@myRegion_var = nil
      @@default_subscription = nil
      @@regions = []


# UTILITY METHODS
      # Determine whether we (the Mu master, presumably) are hosted in Azure.
      # @return [Boolean]
      def self.hosted?
        if $MU_CFG and $MU_CFG.has_key?("azure_is_hosted")
          @@is_in_azure = $MU_CFG["azure_is_hosted"]
          return $MU_CFG["azure_is_hosted"]
        end

        if !@@is_in_azure.nil?
          return @@is_in_azure
        end

        begin
          metadata = get_metadata()
          if metadata['compute']['vmId']
            @@is_in_azure = true
            return true
          else
            return false
          end
        rescue
          # MU.log "Failed to get Azure MetaData. I assume I am not hosted in Azure", MU::DEBUG, details: resources
        end

        @@is_in_azure = false
        false
      end

      # Alias for #{MU::Cloud::AWS.hosted?}
      def self.hosted
        return MU::Cloud::Azure.hosted?
      end

      def self.hosted_config
        return nil if !hosted?
        region = get_metadata()['compute']['location']
        subscription = get_metadata()['compute']['subscriptionId']
        {
          "region" => region,
          "subscriptionId" => subscription
        }
      end

      # Any cloud-specific instance methods we require our resource implementations to have, above and beyond the ones specified by {MU::Cloud}
      # @return [Array<Symbol>]
      def self.required_instance_methods
        []
      end

      # Method that returns the default Azure region for this Mu Master
      # @return [string]
      def self.myRegion(credentials = nil)
        if @@myRegion_var
          return @@myRegion_var
        end

        cfg = credConfig(credentials)
        
        if cfg['default_region']
          # MU.log "Found default region in mu.yml. Using that..."
          @@myRegion_var = cfg['default_region']

        elsif MU::Cloud::Azure.hosted?
          # IF WE ARE HOSTED IN AZURE CHECK FOR THE REGION OF THE INSTANCE
          metadata = get_metadata()
          @@myRegion_var = metadata['compute']['location']

          # TODO: PERHAPS I SHOULD DEFAULT TO SOMETHING SENSIBLE?
        else
          #raise MuError, "Default Region was not found. Please run mu-configure to setup a region"
        end

        return @@myRegion_var
      end

      # lookup the default subscription that will be used by methods
      def self.default_subscription(credentials = nil)
        cfg = credConfig(credentials)
        if @@default_subscription.nil?
          if cfg['subscription']
            # MU.log "Found default subscription in mu.yml. Using that..."
            @@default_subscription = cfg['subscription']

          elsif list_subscriptions().length == 1
            #MU.log "Found a single subscription on your account. Using that... (This may be incorrect)", MU::WARN, details: e.message
            @@default_subscription = list_subscriptions()[0]

          elsif MU::Cloud::Azure.hosted?
            #MU.log "Found a subscriptionID in my metadata. Using that... (This may be incorrect)", MU::WARN, details: e.message
            @@default_subscription = get_metadata()['compute']['subscriptionId']

          else
            raise MuError, "Default Subscription was not found. Please run mu-configure to setup a default subscription"
          end
        end

        return @@default_subscription
      end

      # LIST THE REGIONS FROM AZURE
      def self.listRegions(credentials = nil)
        cfg = credConfig(credentials)
        subscription = cfg['subscription']

        if @@regions.length() > 0 && subscription == default_subscription()
          return @@regions
        end
        
        begin
          sdk_response = MU::Cloud::Azure.subs.subscriptions().list_locations(subscription)
        rescue Exception => e
          MU.log e.inspect, MU::ERR, details: e.backtrace
          #pp "Error Getting the list of regions from Azure" #TODO: SWITCH THIS TO MU LOG
          return @@regions if @@regions and @@regions.size > 0
          raise e
        end

        sdk_response.value.each do | region |
          @@regions.push(region.name)
        end

        return @@regions
      end

      def self.list_subscriptions()
        subscriptions = []

        sdk_response = MU::Cloud::Azure.subs.subscriptions().list

        sdk_response.each do |subscription|
          subscriptions.push(subscription.subscription_id)
        end

        return subscriptions
      end

      def self.listAZs(region = nil)
        az_list = ['1', '2', '3']

        # Pulled from this chart: https://docs.microsoft.com/en-us/azure/availability-zones/az-overview#services-support-by-region
        az_enabled_regions = ['centralus', 'eastus', 'eastus2', 'westus2', 'francecentral', 'northeurope', 'uksouth', 'westeurope', 'japaneast', 'southeastasia'] 

        if not az_enabled_regions.include?(region)
          az_list = []
        end

        return az_list
      end

      def self.config_example
        sample = hosted_config
        sample ||= {
          "region" => "eastus",
          "subscriptionId" => "99999999-9999-9999-9999-999999999999",
        }

        sample["credentials_file"] = "~/.azure/credentials"
        sample["log_bucket_name"]  = "my-mu-s3-bucket"
        sample
      end

      def self.writeDeploySecret
        "TODO"
      end

      # Return the name strings of all known sets of credentials for this cloud
      # @return [Array<String>]
      def self.listCredentials
        if !$MU_CFG['azure']
          return hosted? ? ["#default"] : nil
        end

        $MU_CFG['azure'].keys
      end

      def self.habitat
        nil
      end

      # Return the $MU_CFG data associated with a particular profile/name/set of
      # credentials. If no account name is specified, will return one flagged as
      # default. Returns nil if Azure is not configured. Throws an exception if
      # an account name is specified which does not exist.
      # @param name [String]: The name of the key under 'azure' in mu.yaml to return
      # @return [Hash,nil]
      def self.credConfig (name = nil, name_only: false)
        if !$MU_CFG['azure'] or !$MU_CFG['azure'].is_a?(Hash) or $MU_CFG['azure'].size == 0
          return @@my_hosted_cfg if @@my_hosted_cfg

          if hosted?
            @@my_hosted_cfg = hosted_config
            return name_only ? "#default" : @@my_hosted_cfg
          end

          return nil
        end

        if name.nil?
          $MU_CFG['azure'].each_pair { |name, cfg|
            if cfg['default']
              return name_only ? name : cfg
            end
          }
        else
          if $MU_CFG['azure'][name]
            return name_only ? name : $MU_CFG['azure'][name]
          elsif @@acct_to_profile_map[name.to_s]
            return name_only ? name : @@acct_to_profile_map[name.to_s]
          end
# XXX whatever process might lead us to populate @@acct_to_profile_map with some mappings, like projectname -> account profile, goes here
          return nil
        end

      end

      def self.listInstanceTypes
        return @@instance_types if @@instance_types and @@instance_types[region]
        if !MU::Cloud::Azure.default_subscription()
          return {}
        end

        @@instance_types ||= {}
        @@instance_types[region] ||= {}
        result = MU::Cloud::Google.compute.list_machine_types(MU::Cloud::Google.defaultProject, listAZs(region).first)
        result.items.each { |type|
          @@instance_types[region][type.name] ||= {}
          @@instance_types[region][type.name]["memory"] = sprintf("%.1f", type.memory_mb/1024.0).to_f
          @@instance_types[region][type.name]["vcpu"] = type.guest_cpus.to_f
          if type.is_shared_cpu
            @@instance_types[region][type.name]["ecu"] = "Variable"
          else
            @@instance_types[region][type.name]["ecu"] = type.guest_cpus
          end
        }
        @@instance_types
      end
      
      def self.adminBucketName(credentials = nil)
        "TODO"
      end

      def self.adminBucketUrl(credentials = nil)
        "TODO"
      end
      
      #END REQUIRED METHODS


      # Fetch (ALL) Azure instance metadata
      # @return [Hash, nil]
      def self.get_metadata()
        base_url = "http://169.254.169.254/metadata/instance"
        api_version = '2017-08-01'

        begin
          Timeout.timeout(2) do
            @@metadata ||= JSON.parse(open("#{base_url}/?api-version=#{ api_version }","Metadata"=>"true").read)
          end
          return @@metadata

        rescue Timeout::Error => e
          # MU.log "Timeout querying Azure Metadata"
          return nil
        rescue
          # MU.log "Failed to get Azure MetaData."
          return nil
        end
      end

      # Map our SDK authorization options from MU configuration into an options
      # hash that Azure understands. Raises an exception if any fields aren't
      # available.
      # @param credentials [String]
      # @return [Hash]
      def self.getSDKOptions(credentials = nil)
        cfg = credConfig(credentials)
        map = { #... from mu.yaml-ese to Azure SDK-ese
          "directory_id" => :tenant_id,
          "client_id" => :client_id,
          "client_secret" => :client_secret,
          "subscription" => :subscription_id
        }

        options = {}

        map.each_pair { |k, v|
          options[v] = cfg[k] if cfg[k]
        }
        
        if cfg['credentials_file']
          file = File.open cfg['credentials_file']
          credfile = JSON.load file
          map.each_pair { |k, v|
            options[v] = credfile[k] if credfile[k]
          }
        end

        missing = []
        map.values.each { |v|
          missing << v if !options[v]
        }

        if missing.size > 0
          raise MuError, "Missing fields while trying to load Azure SDK options for credential set #{credentials ? credentials : "<default>" }: #{missing.map { |m| m.to_s }.join(", ")}"
        end

        MU.log "Loaded credential set #{credentials ? credentials : "<default>" }", MU::DEBUG, details: options

        return options
      end

# BEGIN SDK STUBS
      def self.subs(subclass = nil, credentials: nil)
        require 'azure_mgmt_subscriptions'

        @@subscriptions_api[credentials] ||= MU::Cloud::Azure::SDKClient.new(api: "Subscriptions", credentials: credentials)

        return @@subscriptions_api[credentials]
      end

      def self.subfactory(subclass = nil, credentials: nil)
        require 'azure_mgmt_subscriptions'

        @@subscriptions_factory_api[credentials] ||= MU::Cloud::Azure::SDKClient.new(api: "Subscriptions", credentials: credentials, version: "V2018_03_01_preview")

        return @@subscriptions_factory_api[credentials]
      end

      def self.compute(subclass = nil, credentials: nil)
        require 'azure_mgmt_compute'

        @@compute_api[credentials] ||= MU::Cloud::Azure::SDKClient.new(api: "Compute", credentials: credentials)

        return @@compute_api[credentials]
      end

      def self.network(subclass = nil, credentials: nil)
        require 'azure_mgmt_network'

        @@network_api[credentials] ||= MU::Cloud::Azure::SDKClient.new(api: "Network", credentials: credentials)

        return @@network_api[credentials]
      end

      def self.storage(subclass = nil, credentials: nil)
        require 'azure_mgmt_storage'

        @@storage_api[credentials] ||= MU::Cloud::Azure::SDKClient.new(api: "Storage", credentials: credentials)

        return @@storage_api[credentials]
      end

      def self.apis(subclass = nil, credentials: nil)
        require 'azure_mgmt_api_management'

        @@apis_api[credentials] ||= MU::Cloud::Azure::SDKClient.new(api: "ApiManagement", credentials: credentials)

        return @@apis_api[credentials]
      end

      def self.resources(subclass = nil, credentials: nil)
        require 'azure_mgmt_resources_management'

        @@resources_api[credentials] ||= MU::Cloud::Azure::SDKClient.new(api: "ResourcesManagement", credentials: credentials, subclass: subclass)

        return @@resources_api[credentials]
      end

      def self.billing(subclass = nil, credentials: nil)
        require 'azure_mgmt_billing'

        @@billing_api[credentials] ||= MU::Cloud::Azure::SDKClient.new(api: "Billing", credentials: credentials, subclass: subclass)

        return @@billing_api[credentials]
      end

# END SDK STUBS

# BEGIN SDK CLIENT
      private

      @@subscriptions_api = {}
      @@subscriptions_factory_api = {}
      @@compute_api = {}
      @@billing_api = {}
      @@apis_api = {}
      @@network_api = {}
      @@storage_api = {}
      @@resources_api = {}

      class SDKClient
        @api = nil
        @credentials = nil
        @cred_hash = nil

        attr_reader :issuer
        attr_reader :api

        def initialize(api: "Compute", credentials: nil, version: "Latest", subclass: nil)
          @credentials = MU::Cloud::Azure.credConfig(credentials, name_only: true)
          @cred_hash = MU::Cloud::Azure.getSDKOptions(credentials)

          # There seem to be multiple ways to get at clients, and different 
          # versions available depending which way you do it, so... try that?
          stdpath = "::Azure::#{api}::Profiles::#{version}::Mgmt::Client"
          begin
            # Standard approach: get a client from a canned, approved profile
            @api = Object.const_get(stdpath).new(@cred_hash)
          rescue NameError => e
            # Weird approach: generate our own credentials object and invoke a
            # client directly from a particular model version
            token_provider = MsRestAzure::ApplicationTokenProvider.new(
              @cred_hash[:tenant_id],
              @cred_hash[:client_id],
              @cred_hash[:client_secret]
            )
            @cred_obj = MsRest::TokenCredentials.new(token_provider)
            subclass ||= api.sub(/s$/, '')+"Client"
            begin
              modelpath = "::Azure::#{api}::Mgmt::#{version}::#{subclass}"
              @api = Object.const_get(modelpath).new(@cred_obj)
            rescue NameError => e
              raise MuError, "Unable to locate a version #{version} of Azure API #{api}. I tried:\n#{stdpath}\n#{modelpath}"
            end
          end

        end

        def method_missing(method_sym, *arguments)

          begin
            if !arguments.nil? and arguments.size == 1
              retval = @api.method(method_sym).call(arguments[0])
            elsif !arguments.nil? and arguments.size > 0
              retval = @api.method(method_sym).call(*arguments)
            else
              retval = @api.method(method_sym).call
            end
          rescue ::MsRestAzure::AzureOperationError => e
            MU.log e.message, MU::ERR, details: e.inspect
            raise e
          end

          return retval
        end
      end
# END SDK CLIENT
    end
  end
end
