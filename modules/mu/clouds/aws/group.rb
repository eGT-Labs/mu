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
      # A group as configured in {MU::Config::BasketofKittens::groups}
      class Group < MU::Cloud::Group
        @deploy = nil
        @config = nil
        attr_reader :mu_name
        attr_reader :config
        attr_reader :cloud_id

        # @param mommacat [MU::MommaCat]: A {MU::Mommacat} object containing the deploy of which this resource is/will be a member.
        # @param kitten_cfg [Hash]: The fully parsed and resolved {MU::Config} resource descriptor as defined in {MU::Config::BasketofKittens::groups}
        def initialize(mommacat: nil, kitten_cfg: nil, mu_name: nil, cloud_id: nil)
          @deploy = mommacat
          @config = MU::Config.manxify(kitten_cfg)
          @cloud_id ||= cloud_id

          @mu_name ||= if @config['unique_name']
            @deploy.getResourceName(@config["name"])
          else
            @config['name']
          end
        end

        # Called automatically by {MU::Deploy#createResources}
        def create
          begin
            MU::Cloud::AWS.iam.get_group(
              group_name: @mu_name,
              path: @config['path']
            )
            if !@config['use_if_exists']
              raise MuError, "IAM group #{@mu_name} already exists and use_if_exists is false"
            end
          rescue Aws::IAM::Errors::NoSuchEntity => e
            @config['path'] ||= "/"+@deploy.deploy_id+"/"
            MU.log "Creating IAM group #{@config['path']}/#{@mu_name}"
            MU::Cloud::AWS.iam.create_group(
              group_name: @mu_name,
              path: @config['path']
            )
          end
        end

        # Called automatically by {MU::Deploy#createResources}
        def groom
          if @config['members']
            ext = cloud_desc.users.map { |u| u.user_name }
            @config['members'].each { |user|
              next if ext.include?(user)

              userid = user
              userdesc = @deploy.findLitterMate(name: user, type: "users")
              if userdesc
                userid = userdesc.cloud_id
                found = MU::Cloud::AWS::User.find(cloud_id: userid)
                if found.size == 1
                  userdesc = found.values.first
                  MU.log "Adding IAM user #{userdesc.path}#{userdesc.user_name} to group #{@mu_name}", MU::NOTICE
                  MU::Cloud::AWS.iam.add_user_to_group(
                    user_name: userid,
                    group_name: @mu_name
                  )
                else
                  MU.log "IAM user #{userid} doesn't seem to exist, can't add to group #{@mu_name}", MU::ERR
                end
              end
            }
          end
        end

        # Fetch the AWS API description of this group
        # return [Struct]
        def cloud_desc
          MU::Cloud::AWS.iam.get_group(
            group_name: @mu_name
          )
        end

        # Return the metadata for this group configuration
        # @return [Hash]
        def notify
          descriptor = MU.structToHash(cloud_desc)
          descriptor["cloud_id"] = @mu_name
          descriptor
        end

        # Remove all groups associated with the currently loaded deployment.
        # @param noop [Boolean]: If true, will only print what would be done
        # @param ignoremaster [Boolean]: If true, will remove resources not flagged as originating from this Mu server
        # @param region [String]: The cloud provider region
        # @return [void]
        def self.cleanup(noop: false, ignoremaster: false, region: MU.curRegion, flags: {})
        end

        # Locate an existing group group.
        # @param cloud_id [String]: The cloud provider's identifier for this resource.
        # @param region [String]: The cloud provider region.
        # @param flags [Hash]: Optional flags
        # @return [OpenStruct]: The cloud provider's complete descriptions of matching group group.
        def self.find(cloud_id: nil, region: MU.curRegion, flags: {})
          found = nil
          begin
            resp = MU::Cloud::AWS.iam.get_group(
              group_name: cloud_id
            )
            found ||= {}
            found[cloud_id] = resp
          rescue Aws::IAM::Errors::NoSuchEntity
          end
          found
        end

        # Cloud-specific configuration properties.
        # @param config [MU::Config]: The calling MU::Config object
        # @return [Array<Array,Hash>]: List of required fields, and json-schema Hash of cloud-specific configuration parameters for this resource
        def self.schema(config)
          toplevel_required = []
          schema = {
            "unique_name" => {
              "type" => "boolean",
              "description" => "Instead of creating/updating a group with
 the exact name specified in the 'name' field, generate a unique-per-deploy Mu-
style long name, like +IAMTESTS-DEV-2018112815-IS-GROUP-FOO+. This parameter will automatically be set to +true+ if it is left unspecified and +use_if_exists+ is set to +false+."
            },
            "path" => {
              "type" => "string",
              "description" => "AWS IAM groups can be namespaced with a path (ex: +/organization/unit/group+). If not specified, and if we do not see a matching existing group under +/+ with +use_if_exists+ set, we will prepend the deploy identifier to the path of groups we create. Ex: +/IAMTESTS-DEV-2018112910-GR/mygroup+.",
              "pattern" => '^\/(?:[^\/]+(?:\/[^\/]+)*\/$)?'
            },
          }
          [toplevel_required, schema]
        end

        # Cloud-specific pre-processing of {MU::Config::BasketofKittens::groups}, bare and unvalidated.
        # @param group [Hash]: The resource to process and validate
        # @param configurator [MU::Config]: The overall deployment configurator of which this resource is a member
        # @return [Boolean]: True if validation succeeded, False otherwise
        def self.validateConfig(group, configurator)
          ok = true

          if !group['use_if_exists'] and group['unique_name'].nil?
            group['unique_name'] = true
          end

          if group['members']
            group['members'].each { |user|
              if configurator.haveLitterMate?(user, "users")
                group["dependencies"] ||= []
                group["dependencies"] << {
                  "type" => "user",
                  "name" => user
                }
              else
                found = MU::Cloud::AWS::User.find(cloud_id: user)
                if found.nil? or found.empty?
                  MU.log "Error in members for group #{group['name']}: No such user #{user}", MU::ERR
                  ok = false
                end
              end
            }
          end

          ok
        end

      end
    end
  end
end
