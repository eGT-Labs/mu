# Copyright:: Copyright (c) 2020 eGlobalTech, Inc., all rights reserved
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
  # Plugins under this namespace serve as interfaces to cloud providers and
  # other provisioning layers.
  class Cloud

    # An exception we can use with transient Net::SSH errors, which require
    # special handling due to obnoxious asynchronous interrupt behaviors.
    class NetSSHFail < MuNonFatal;
    end

    # Net::SSH exceptions seem to have their own behavior vis a vis threads,
    # and our regular call stack gets circumvented when they're thrown. Cheat
    # here to catch them gracefully.
    def self.handleNetSSHExceptions
      Thread.handle_interrupt(Net::SSH::Exception => :never) {
        begin
          Thread.handle_interrupt(Net::SSH::Exception => :immediate) {
            MU.log "(Probably harmless) Caught a Net::SSH Exception in #{Thread.current.inspect}", MU::DEBUG, details: Thread.current.backtrace
          }
        ensure
#          raise NetSSHFail, "Net::SSH had a nutty"
        end
      }
    end

    [:Server, :ServerPool].each { |name|
      Object.const_get("MU").const_get("Cloud").const_get(name).class_eval {

        # Basic setup tasks performed on a new node during its first initial
        # ssh connection. Most of this is terrible Windows glue.
        # @param ssh [Net::SSH::Connection::Session]: The active SSH session to the new node.
        def initialSSHTasks(ssh)
          win_env_fix = %q{echo 'export PATH="$PATH:/cygdrive/c/opscode/chef/embedded/bin"' > "$HOME/chef-client"; echo 'prev_dir="`pwd`"; for __dir in /proc/registry/HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/Control/Session\ Manager/Environment;do cd "$__dir"; for __var in `ls * | grep -v TEMP | grep -v TMP`;do __var=`echo $__var | tr "[a-z]" "[A-Z]"`; test -z "${!__var}" && export $__var="`cat $__var`" >/dev/null 2>&1; done; done; cd "$prev_dir"; /cygdrive/c/opscode/chef/bin/chef-client.bat $@' >> "$HOME/chef-client"; chmod 700 "$HOME/chef-client"; ( grep "^alias chef-client=" "$HOME/.bashrc" || echo 'alias chef-client="$HOME/chef-client"' >> "$HOME/.bashrc" ) ; ( grep "^alias mu-groom=" "$HOME/.bashrc" || echo 'alias mu-groom="powershell -File \"c:/Program Files/Amazon/Ec2ConfigService/Scripts/UserScript.ps1\""' >> "$HOME/.bashrc" )}
          win_installer_check = %q{ls /proc/registry/HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/Windows/CurrentVersion/Installer/}
          lnx_installer_check = %q{ps auxww | awk '{print $11}' | egrep '(/usr/bin/yum|apt-get|dpkg)'}
          lnx_updates_check = %q{( test -f /.mu-installer-ran-updates || ! test -d /var/lib/cloud/instance ) || echo "userdata still running"}
          win_set_pw = nil

          if windows? and !@config['use_cloud_provider_windows_password']
            # This covers both the case where we have a windows password passed from a vault and where we need to use a a random Windows Admin password generated by MU::Cloud::Server.generateWindowsPassword
            pw = @groomer.getSecret(
              vault: @config['mu_name'],
              item: "windows_credentials",
              field: "password"
            )
            win_check_for_pw = %Q{powershell -Command '& {Add-Type -AssemblyName System.DirectoryServices.AccountManagement; $Creds = (New-Object System.Management.Automation.PSCredential("#{@config["windows_admin_username"]}", (ConvertTo-SecureString "#{pw}" -AsPlainText -Force)));$DS = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Machine); $DS.ValidateCredentials($Creds.GetNetworkCredential().UserName, $Creds.GetNetworkCredential().password); echo $Result}'}
            win_set_pw = %Q{powershell -Command "& {(([adsi]('WinNT://./#{@config["windows_admin_username"]}, user')).psbase.invoke('SetPassword', '#{pw}'))}"}
          end

          # There shouldn't be a use case where a domain joined computer goes through initialSSHTasks. Removing Active Directory specific computer rename.
          set_hostname = true
          hostname = nil
          if !@config['active_directory'].nil?
            if @config['active_directory']['node_type'] == "domain_controller" && @config['active_directory']['domain_controller_hostname']
              hostname = @config['active_directory']['domain_controller_hostname']
              @mu_windows_name = hostname
              set_hostname = true
            else
              # Do we have an AD specific hostname?
              hostname = @mu_windows_name
              set_hostname = true
            end
          else
            hostname = @mu_windows_name
          end
          win_check_for_hostname = %Q{powershell -Command '& {hostname}'}
          win_set_hostname = %Q{powershell -Command "& {Rename-Computer -NewName '#{hostname}' -Force -PassThru -Restart; Restart-Computer -Force }"}

          begin
            # Set our admin password first, if we need to
            if windows? and !win_set_pw.nil? and !win_check_for_pw.nil?
              output = ssh.exec!(win_check_for_pw)
              raise MU::Cloud::BootstrapTempFail, "Got nil output from ssh session, waiting and retrying" if output.nil?
              if !output.match(/True/)
                MU.log "Setting Windows password for user #{@config['windows_admin_username']}", details: ssh.exec!(win_set_pw)
              end
            end
            if windows?
              output = ssh.exec!(win_env_fix)
              output += ssh.exec!(win_installer_check)
              raise MU::Cloud::BootstrapTempFail, "Got nil output from ssh session, waiting and retrying" if output.nil?
              if output.match(/InProgress/)
                raise MU::Cloud::BootstrapTempFail, "Windows Installer service is still doing something, need to wait"
              end
              if set_hostname and !@hostname_set and @mu_windows_name
                output = ssh.exec!(win_check_for_hostname)
                raise MU::Cloud::BootstrapTempFail, "Got nil output from ssh session, waiting and retrying" if output.nil?
                if !output.match(/#{@mu_windows_name}/)
                  MU.log "Setting Windows hostname to #{@mu_windows_name}", details: ssh.exec!(win_set_hostname)
                  @hostname_set = true
                  # Reboot from the API too, in case Windows is flailing
                  if !@cloudobj.nil?
                    @cloudobj.reboot
                  else
                    reboot
                  end
                  raise MU::Cloud::BootstrapTempFail, "Set hostname in Windows, waiting for reboot"
                end
              end
            else
              output = ssh.exec!(lnx_installer_check)
              if !output.nil? and !output.empty?
                raise MU::Cloud::BootstrapTempFail, "Linux package manager is still doing something, need to wait (#{output})"
              end
              if !@config['skipinitialupdates'] and
                 !@config['scrub_mu_isms'] and
                 !@config['userdata_script']
                output = ssh.exec!(lnx_updates_check)
                if !output.nil? and output.match(/userdata still running/)
                  raise MU::Cloud::BootstrapTempFail, "Waiting for initial userdata system updates to complete"
                end
              end
            end
          rescue RuntimeError, IOError => e
            raise MU::Cloud::BootstrapTempFail, "Got #{e.inspect} performing initial SSH connect tasks, will try again"
          end

        end

        # @param max_retries [Integer]: Number of connection attempts to make before giving up
        # @param retry_interval [Integer]: Number of seconds to wait between connection attempts
        # @return [Net::SSH::Connection::Session]
        def getSSHSession(max_retries = 12, retry_interval = 30)
          ssh_keydir = Etc.getpwnam(@deploy.mu_user).dir+"/.ssh"
          nat_ssh_key, nat_ssh_user, nat_ssh_host, canonical_ip, ssh_user, _ssh_key_name = getSSHConfig
          session = nil
          retries = 0

          # XXX WHY is this a thing
          Thread.handle_interrupt(Errno::ECONNREFUSED => :never) {
          }

          begin
            MU::Cloud.handleNetSSHExceptions
            if !nat_ssh_host.nil?
              proxy_cmd = "ssh -q -o StrictHostKeyChecking=no -W %h:%p #{nat_ssh_user}@#{nat_ssh_host}"
              MU.log "Attempting SSH to #{canonical_ip} (#{@mu_name}) as #{ssh_user} with key #{@deploy.ssh_key_name} using proxy '#{proxy_cmd}'" if retries == 0
              proxy = Net::SSH::Proxy::Command.new(proxy_cmd)
              session = Net::SSH.start(
                  canonical_ip,
                  ssh_user,
                  :config => false,
                  :keys_only => true,
                  :keys => [ssh_keydir+"/"+nat_ssh_key, ssh_keydir+"/"+@deploy.ssh_key_name],
                  :verify_host_key => false,
                  #           :verbose => :info,
                  :host_key => "ssh-rsa",
                  :port => 22,
                  :auth_methods => ['publickey'],
                  :proxy => proxy
              )
            else

              MU.log "Attempting SSH to #{canonical_ip} (#{@mu_name}) as #{ssh_user} with key #{ssh_keydir}/#{@deploy.ssh_key_name}" if retries == 0
              session = Net::SSH.start(
                  canonical_ip,
                  ssh_user,
                  :config => false,
                  :keys_only => true,
                  :keys => [ssh_keydir+"/"+@deploy.ssh_key_name],
                  :verify_host_key => false,
                  #           :verbose => :info,
                  :host_key => "ssh-rsa",
                  :port => 22,
                  :auth_methods => ['publickey']
              )
            end
            retries = 0
          rescue Net::SSH::HostKeyMismatch => e
            MU.log("Remembering new key: #{e.fingerprint}")
            e.remember_host!
            session.close
            retry
#            rescue SystemCallError, Timeout::Error, Errno::ECONNRESET, Errno::EHOSTUNREACH, Net::SSH::Proxy::ConnectError, SocketError, Net::SSH::Disconnect, Net::SSH::AuthenticationFailed, IOError, Net::SSH::ConnectionTimeout, Net::SSH::Proxy::ConnectError, MU::Cloud::NetSSHFail => e
          rescue SystemExit, Timeout::Error, Net::SSH::AuthenticationFailed, Net::SSH::Disconnect, Net::SSH::ConnectionTimeout, Net::SSH::Proxy::ConnectError, Net::SSH::Exception, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ECONNREFUSED, Errno::EPIPE, SocketError, IOError => e
            begin
              session.close if !session.nil?
            rescue Net::SSH::Disconnect, IOError => e
              if windows?
                MU.log "Windows has probably closed the ssh session before we could. Waiting before trying again", MU::NOTICE
              else
                MU.log "ssh session was closed unexpectedly, waiting before trying again", MU::NOTICE
              end
              sleep 10
            end

            if retries < max_retries
              retries = retries + 1
              msg = "ssh #{ssh_user}@#{@mu_name}: #{e.message}, waiting #{retry_interval}s (attempt #{retries}/#{max_retries})"
              if retries == 1 or (retries/max_retries <= 0.5 and (retries % 3) == 0)
                MU.log msg, MU::NOTICE
                if !MU::Cloud.resourceClass(@cloud, "VPC").haveRouteToInstance?(cloud_desc, credentials: @credentials) and
                   canonical_ip.match(/(^127\.)|(^192\.168\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^::1$)|(^[fF][cCdD])/) and
                   !nat_ssh_host
                  MU.log "Node #{@mu_name} at #{canonical_ip} looks like it's in a private address space, and I don't appear to have a direct route to it. It may not be possible to connect with this routing!", MU::WARN
                end
              elsif retries/max_retries > 0.5
                MU.log msg, MU::WARN, details: e.inspect
              end
              sleep retry_interval
              retry
            else
              raise MuError, "#{@mu_name}: #{e.inspect} trying to connect with SSH, max_retries exceeded", e.backtrace
            end
          end
          return session
        end
      }

    }

  end

end
