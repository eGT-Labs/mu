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

module MU
  class Cloud
    class AWS
      # A function as configured in {MU::Config::BasketofKittens::functions}
      class Function < MU::Cloud::Function
        @deploy = nil
        @config = nil
        attr_reader :mu_name
        attr_reader :config
        attr_reader :cloud_id

        @cloudformation_data = {}
        attr_reader :cloudformation_data

        # @param mommacat [MU::MommaCat]: A {MU::Mommacat} object containing the deploy of which this resource is/will be a member.
        # @param kitten_cfg [Hash]: The fully parsed and resolved {MU::Config} resource descriptor as defined in {MU::Config::BasketofKittens::functions}
        def initialize(mommacat: nil, kitten_cfg: nil, mu_name: nil, cloud_id: nil)
          @deploy = mommacat
          @config = MU::Config.manxify(kitten_cfg)
          @cloud_id ||= cloud_id
          @mu_name ||= @deploy.getResourceName(@config["name"])
        end

        
        def get_role_arn(name)
          begin
            role = MU::Cloud::AWS.iam(@config['region']).get_role({
              role_name: name.to_s
            })
            return role['role']['arn']
          rescue Exception => e
            Mu.log "#{e}", MU::ERR
          end
        end



        # Called automatically by {MU::Deploy#createResources}
        def create
          begin
            aws_lambda = create_lambda
          rescue Exception => e
            MU.log "#{e}", MU::ERR
          end
        end



        def get_vpc_config(vpc_name, subnet_name, sg_name,region=@config['region'])
          if !subnet_name.nil? and !sg_name.nil? and !vpc_name.nil?
            ## get vpc_id
            ## get sub_id and verify its in the same vpc 
            ## get sg_id and verify its in the same vpc
            ec2_client = MU::Cloud::AWS.ec2(region)
            
            vpc_filter = ec2_client.describe_vpcs({
              filters: [{ name: 'tag-value', values: [vpc_name] }]
            })
            bok_vpc_id = vpc_filter.vpcs[0].vpc_id
            
            sub_filter = ec2_client.describe_subnets({
              filters: [{ name: 'tag-value', values: [subnet_name] }]
            })
            if sub_filter.subnets[0].vpc_id.to_s != bok_vpc_id
              MU.log "Subnet: #{subnet_name} is not part of the VPC: #{vpc_name}", MU::ERR
              raise MuError, "Please provide subnet name that exists in the vpc"
            end
            
            sg_filter = ec2_client.describe_security_groups({
              filters: [{ name: 'group-name', values: [sg_name] }]
            })
            
            if sg_filter.security_groups[0].vpc_id.to_s != bok_vpc_id
              MU.log "Security Group: #{sg_name} is not part of the VPC: #{vpc_name}", MU::ERR
              raise MuError, "Please provide security group name that exists in the vpc"
            end

            sub_id = sub_filter.subnets[0].subnet_id
            sg_id = sg_filter.security_groups[0].group_id
            
            return {subnet_ids: [sub_id], security_group_ids: [sg_id]}
          else
            raise MuError, "Insufficient parameters for locating resource_ids"
          end
        end




        def assign_tag(resource_arn, tag_list, region=@config['region'])
          begin
            tag_list.each do |each_pair|
              tag_resp = MU::Cloud::AWS.lambda(region).tag_resource({
                resource: resource_arn,
                tags: each_pair
              })
            end
          rescue Exception => e
            MU.log e, MU::ERR
          end
        end




        def create_lambda
          role_arn = get_role_arn(@config['iam_role'].to_s)
          func_name = "#{@config['name'].upcase}-#{MU.deploy_id}"
          
          lambda_properties = {
            code:{
              s3_bucket: @config['code'][0]['s3_bucket'],
              s3_key: @config['code'][0]['s3_key']
            },
            function_name:func_name,
            handler:@config['handler'],
            publish:true,
            role:role_arn,
            runtime:@config['run_time'],
          }
           
          if @config.has_key?('timeout')
            lambda_properties[:timeout] = @config['timeout'].to_i ## secs
          end           
          
          if @config.has_key?('memory')
            lambda_properties[:memory_size] = @config['memory'].to_i
          end
          
          if @config.has_key?('environment_variables') 
              lambda_properties[:environment] = { 
                variables: {@config['environment_variables'][0]['key'] => @config['environment_variables'][0]['value']}
              }
          end

          if @config.has_key?('vpc')
             ### get vpc and subnet_name
             ### find the subnet_id
             sub_name = @config['vpc']['subnet_name']
             vpc_name = @config['vpc']['vpc_name']
             sg_name =  @config['vpc']['security_group_name']
             vpc_conf = get_vpc_config(vpc_name,sub_name,sg_name)
             lambda_properties[:vpc_config] = vpc_conf
          end

          #p lambda_properties 


          @config['tags'].push({'deploy_id' => MU.deploy_id})
          lambda_func = MU::Cloud::AWS.lambda(@config['region']).create_function(lambda_properties)
          tag_function = assign_tag(lambda_func.function_arn, @config['tags']) 


          ### to add or to not add triggers
          ### triggers must exist prior
          if  @config.has_key?('trigger') and !@config['trigger']['type'].nil? and !@config['trigger']['name'].nil?
            
            trigger_arn = "arn:aws:#{@config['trigger']['type'].downcase}:#{@config['region']}:#{MU.account_number}:#{@config['trigger']['name']}"
            trigger_properties = {
              action: "lambda:*", 
              function_name: func_name, 
              principal: "#{@config['trigger']['type'].downcase}.amazonaws.com", 
              source_arn: trigger_arn, 
              statement_id: "ID-1",
            }
            

            ### add source_account only if type is s3 or ses
            if @config['trigger']['type'].downcase == 's3' or @config['trigger']['type'].downcase == 'ses'
              trigger_properties[:source_account] = MU.account_number
            end


            MU.log trigger_properties, MU::DEBUG

            add_trigger = MU::Cloud::AWS.lambda(@config['region']).add_permission(trigger_properties)
            
          end 
          
          return lambda_func
        end
        





        # Return the metadata for this Function rule
        # @return [Hash]
        def notify
          deploy_struct = {
          }
          return deploy_struct
        end




        # Remove all functions associated with the currently loaded deployment.
        # @param noop [Boolean]: If true, will only print what would be done
        # @param ignoremaster [Boolean]: If true, will remove resources not flagged as originating from this Mu server
        # @param region [String]: The cloud provider region
        # @return [void]
        def self.cleanup(noop: false, ignoremaster: false, region: MU.curRegion, flags: {})
            
        end




        # Locate an existing function.
        # @param cloud_id [String]: The cloud provider's identifier for this resource.
        # @param region [String]: The cloud provider region.
        # @param flags [Hash]: Optional flags
        # @return [OpenStruct]: The cloud provider's complete descriptions of matching function.
        def self.find(cloud_id: nil, region: MU.curRegion, flags: {})
          all_functions = MU::Cloud::AWS.lambda(region).list_functions
          return all_functions
        end




        # Cloud-specific configuration properties.
        # @param config [MU::Config]: The calling MU::Config object
        # @return [Array<Array,Hash>]: List of required fields, and json-schema Hash of cloud-specific configuration parameters for this resource
        def self.schema(config)
          toplevel_required = []
          schema = {}
          [toplevel_required, schema]
        end



        # Cloud-specific pre-processing of {MU::Config::BasketofKittens::functions}, bare and unvalidated.
        # @param function [Hash]: The resource to process and validate
        # @param configurator [MU::Config]: The overall deployment configurator of which this resource is a member
        # @return [Boolean]: True if validation succeeded, False otherwise
        def self.validateConfig(function, configurator)
          ok = true
#          if something_bad
#            ok = false
#          end

          ok
        end

      end
    end
  end
end
