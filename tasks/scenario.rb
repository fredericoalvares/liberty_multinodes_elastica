# Scenario dedicated Rake task
#
#

# Override OAR resources (tasks/jobs.rb)
# We uses 2 nodes (1 puppetserver and 1 controller) and a subnet for floating public IPs
#
XP5K::Config[:jobname]    ||= '[openstack] elastica'
XP5K::Config[:site]       ||= 'rennes'
XP5K::Config[:walltime]   ||= '1:00:00'
XP5K::Config[:cluster]    ||= ''
XP5K::Config[:vlantype]   ||= 'kavlan-local'
XP5K::Config[:computes]   ||= 1
#XP5K::Config[:interfaces] ||= 1
#XP5K::Config[:injectors]  ||= 1
XP5K::Config[:elastica_home] ||= "#{ENV['HOME']}/elastica"

XP5K::Config[:elastica_env] = {:PROJECT_PATH=>"/share"}

oar_cluster = ""
oar_cluster = "and cluster='" + XP5K::Config[:cluster] + "'" if !XP5K::Config[:cluster].empty?
# vlan reservation 
# the first interface is put in the production network
# the other ones are put a dedicated vlan thus we need #interfaces - 1 vlans
#oar_vlan = ""
#oar_vlan = "{type='#{XP5K::Config[:vlantype]}'}/vlan=#{XP5K::Config[:interfaces] - 1}" if XP5K::Config[:interfaces] >= 2

nodes = 2 + XP5K::Config[:computes].to_i + XP5K::Config[:computes].to_i - 1


resources = [] << %{{type='#{XP5K::Config[:vlantype]}'}/vlan=1+{virtual != 'none' #{oar_cluster}}/nodes=#{nodes}+slash_22=1,walltime=#{XP5K::Config[:walltime]}}

#resources = [] << 
#[ 
#  "#{oar_vlan}",
#  "{eth_count >= #{XP5K::Config[:interfaces]} and virtual != 'none' #{oar_cluster}}/nodes=#{nodes}",
#  "slash_22=1, walltime=#{XP5K::Config[:walltime]}"
#].join("+")

@job_def[:resources] = resources
@job_def[:roles] << XP5K::Role.new({
  name: 'controller',
  size: 1
})

#@job_def[:roles] << XP5K::Role.new({
#  name: 'storage',
#  size: 1
#})
#
#@job_def[:roles] << XP5K::Role.new({
#  name: 'network',
#  size: 1
#})

@job_def[:roles] << XP5K::Role.new({
  name: 'compute',
  size: XP5K::Config[:computes].to_i
})

@job_def[:roles] << XP5K::Role.new({
  name: 'injector',
  size: XP5K::Config[:computes].to_i - 1 # XP5K::Config[:injectors].to_i
})

G5K_NETWORKS = YAML.load_file("scenarios/#{XP5K::Config[:scenario]}/g5k_networks.yml")

# Override role 'all' (tasks/roles.rb)
#
role 'all' do
  roles 'puppetserver', 'controller', 'compute', 'injector'
end

# Define OAR job (required)
#
xp.define_job(@job_def)


# Define Kadeploy deployment (required)
#
xp.define_deployment(@deployment_def)


namespace :scenario do

  desc 'Main task called at the end of `run` task'
  task :main do
    # install vlan (force cache regeneration before)
    Rake::Task['interfaces:cache'].execute
    Rake::Task['interfaces:vlan'].execute
    Rake::Task['scenario:hiera:update'].execute
    
    # patch 
    Rake::Task['scenario:os:patch'].execute
    Rake::Task['puppet:modules:upload'].execute

    # run controller recipes 
    # do not call rake task (due to chaining)
    puppetserver = roles('puppetserver').first



    on roles('controller', 'compute','injector') do
        cmd = "/opt/puppetlabs/bin/puppet agent -t --server #{puppetserver}"
        cmd += " --debug" if ENV['debug']
        cmd += " --trace" if ENV['trace']
        cmd
    end
    
#    on roles('network', 'storage', 'compute') do
#        cmd = "/opt/puppetlabs/bin/puppet agent -t --server #{puppetserver}"
#        cmd += " --debug" if ENV['debug']
#        cmd += " --trace" if ENV['trace']
#        cmd
#    end
    
#    on roles('injector') do
#      cmd = "/opt/puppetlabs/bin/puppet agent -t --server #{puppetserver}"
#      cmd += " --debug" if ENV['debug']
#      cmd += " --trace" if ENV['trace']
#      cmd
#    end

    Rake::Task['scenario:bootstrap'].execute
  end
  
  desc 'Bootstrap the installation' 
  task :bootstrap do
    workflow = [
      'scenario:os:fix_proxy',
      'scenario:os:rules',
      'scenario:os:public_bridge',
      'scenario:os:network',
 #     'scenario:os:horizon',
      'scenario:os:flavors',
      'scenario:os:images'
    ]
    workflow.each do |task|
      Rake::Task[task].execute
    end
 end
 namespace :hiera do
    desc 'update common.yaml with network information (controller/storage ips, networks adresses)'
    task :update do
      update_common_with_networks()
      # upload the new common.yaml
      puppetserver_fqdn = roles('puppetserver').first
      sh %{cd scenarios/#{XP5K::Config[:scenario]}/hiera/generated && tar -cf - . | ssh#{SSH_CONFIGFILE_OPT} root@#{puppetserver_fqdn} 'cd /etc/puppetlabs/code/environments/production/hieradata && tar xf -'}
    end
  end
 namespace :os do

    desc 'Update default security group rules'
    task :fix_proxy do
      on(roles('controller'), user: 'root') do
        cmd = 'rm -f /etc/environment'
      end
    end

    desc 'Update default security group rules'
    task :rules do
      on(roles('controller'), user: 'root', environment: XP5K::Config[:openstack_env]) do
        # Add SSH rule
        cmd = [] << 'nova secgroup-add-rule default tcp 22 22 0.0.0.0/0'
        # Add http rule
        cmd << 'nova secgroup-add-rule default tcp 80 80 0.0.0.0/0'
        # Add ICMP rule
        cmd << 'nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0'
	cmd << 'nova secgroup-create sec_group \' default security goup\''
        cmd << 'nova secgroup-add-rule sec_group tcp 1 65535 0.0.0.0/0'
        cmd << 'nova secgroup-add-rule sec_group icmp -1 -1 0.0.0.0/0'
        cmd
      end
    end

    desc 'Configure public bridge'
    task :public_bridge do
      controllerHostname = roles('controller').first.split('.').first
      clusterName = controllerHostname.split('-').first
      restfullyDatas = xp.connection.root
      .sites[XP5K::Config[:site].to_sym]
      .clusters[clusterName.to_sym]
      .nodes.select { |i| i['uid'] == controllerHostname }.first
      device = restfullyDatas['network_adapters'].select { |interface|
        interface['mounted'] == true
      }.first['device']
      on(roles('controller'), user: 'root') do
        %{ ovs-vsctl add-port br-ex #{device} && ip addr flush #{device} && dhclient -nw br-ex }
      end
    end

#    desc 'Configure public bridge'
#    task :public_bridge do
##      on(roles('network'), user: 'root') do
#       on(roles('controller'), user: 'root') do
#        interfaces = get_node_interfaces
#        network = roles('controller').first
#        device = interfaces[network]["public"]["device"]
#        %{ ovs-vsctl add-port br-ex #{device} && ip addr flush #{device} && dhclient -nw br-ex }
#      end
#
#    end

    desc 'Configure Openstack network'
    task :network do
      publicSubnet = G5K_NETWORKS[XP5K::Config[:site]]["subnet"]
      reservedSubnet = xp.job_with_name(XP5K::Config[:jobname])['resources_by_type']['subnets'].first
      publicPool = IPAddr.new(reservedSubnet).to_range.to_a[10..100]
      publicPoolStart,publicPoolStop = publicPool.first.to_s,publicPool.last.to_s
      privateCIDR = '192.168.1.0/24'
      privatePool = IPAddr.new(privateCIDR).to_range.to_a[10..100]
      privatePoolStart,privatePoolStop = privatePool.first.to_s,privatePool.last.to_s

      on(roles('controller'), user: 'root', environment: XP5K::Config[:openstack_env]) do
        cmd = []
        cmd << %{neutron net-create public --shared --provider:physical_network external --provider:network_type flat --router:external True}
        cmd << %{neutron net-create private}
        cmd << %{neutron subnet-create public #{publicSubnet["cidr"]} --name public-subnet --allocation-pool start=#{publicPoolStart},end=#{publicPoolStop} --dns-nameserver 131.254.203.235 --gateway #{publicSubnet["gateway"]}  --disable-dhcp}
        cmd << %{neutron subnet-create private #{privateCIDR} --name private-subnet --allocation-pool start=#{privatePoolStart},end=#{privatePoolStop} --dns-nameserver 131.254.203.235} 
        cmd << %{neutron router-create main_router}
        cmd << %{neutron router-gateway-set main_router public}
        cmd << %{neutron router-interface-add main_router private-subnet}
        cmd
      end
    end

    desc 'Init horizon theme'
    task :horizon do
      on(roles('controller'), user: 'root') do
        %{/usr/share/openstack-dashboard/manage.py collectstatic --noinput && /usr/share/openstack-dashboard/manage.py compress --force}
      end
    end

    desc 'Get images'
    task :images do
      on(roles('controller'), user: 'root', environment: XP5K::Config[:openstack_env]) do
        [
#           %{/usr/bin/wget -q -O /tmp/cirros.img http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img},
#           %{glance image-create --name="Cirros" --disk-format=qcow2 --container-format=bare --property architecture=x86_64 --progress --file /tmp/cirros.img},
 #          %{/usr/bin/wget -q -O /tmp/debian.img http://cdimage.debian.org/cdimage/openstack/8.3.0/debian-8.3.0-openstack-amd64.qcow2},
 #          %{glance image-create --name="Debian Jessie 64-bit" --disk-format=qcow2 --container-format=bare --property architecture=x86_64 --progress --file /tmp/debian.img}
            %{/usr/bin/wget -q -O /tmp/ubuntu.img https://cloud-images.ubuntu.com/releases/12.04.4/release-20120424/ubuntu-12.04-server-cloudimg-amd64-disk1.img},
           %{glance image-create --name="Ubuntu 12.04" --disk-format=qcow2 --container-format=bare --property architecture=x86_64 --progress --file /tmp/ubuntu.img}
        ]
      end
    end

    desc 'Add flavors'
    task :flavors do
      on(roles('controller'), user: 'root', environment: XP5K::Config[:openstack_env]) do
      [ ]
       # %{nova flavor-create m1.tiny 1 512 0 1 --is-public True},
       # %{nova flavor-create m1.small 2 2048 10 1 --is-public True},
       # %{nova flavor-create m1.medium 3 4096 10 2 --is-public True},
       # %{nova flavor-create m1.large 4 8096 10 4 --is-public True},
       # %{nova flavor-create m1.xlarge 5 16384 10 8 --is-public True} ]
      #  %{nova flavor-create m1.xs auto 2048 6 2 --is-public True}
      end
    end

    desc 'Patch horizon Puppet module'
    task :patch do
      os = %x[uname].chomp
      case os
      when 'Linux'
        sh %{sed -i '24s/apache2/httpd/' scenarios/#{XP5K::Config[:scenario]}/puppet/modules-openstack/horizon/manifests/params.pp}
        sh %{sed -i 's/F78372A06FF50C80464FC1B4F7B8CEA6056E8E56/0A9AF2115F4687BD29803A206B73A36E6026DFCA/' scenarios/#{XP5K::Config[:scenario]}/puppet/modules-openstack/rabbitmq/manifests/repo/apt.pp}
      when 'Darwin'
        sh %{sed -i '' '24s/apache2/httpd/' scenarios/#{XP5K::Config[:scenario]}/puppet/modules-openstack/horizon/manifests/params.pp}
        sh %{sed -i '' 's/F78372A06FF50C80464FC1B4F7B8CEA6056E8E56/0A9AF2115F4687BD29803A206B73A36E6026DFCA/' scenarios/#{XP5K::Config[:scenario]}/puppet/modules-openstack/rabbitmq/manifests/repo/apt.pp}
      else
        puts "Patch not applied."
      end
    end
 end

 # desc 'Show SSH configuration to access Horizon'
 # task :horizon_access do
 #   puts '** Launch this script on your local computer and open http://localhost:8080 on your navigator'
 #   puts '---'
 #   script = %{cat > /tmp/openstack_ssh_config <<EOF\n}
 #   script += %{Host *.grid5000.fr\n}
 #   script += %{  User #{ENV['USER']}\n}
 #   script += %{  ProxyCommand ssh -q #{ENV['USER']}@194.254.60.4 nc -w1 %h %p # Access South\n}
 #   script += %{EOF\n}
 #   script += %{ssh -F /tmp/openstack_ssh_config -N -L 8080:#{roles('controller').first}:8080 #{ENV['USER']}@frontend.#{XP5K::Config[:site]}.grid5000.fr &\n}
 #   script += %{HTTP_PID=$!\n}
 #   script += %{ssh -F /tmp/openstack_ssh_config -N -L 6080:#{roles('controller').first}:6080 #{ENV['USER']}@frontend.#{XP5K::Config[:site]}.grid5000.fr &\n}
 #   script += %{CONSOLE_PID=$!\n}
 #   script += %{trap 'kill -9 $HTTP_PID && kill -9 $CONSOLE_PID' 2\n}
 #   script += %{echo 'http://localhost:8080'\n}
 #   script += %{wait\n}
 #   puts script
 #   puts '---'
 # end

 namespace :elastica do
  desc 'Elastica Setup'
  task :setup do
    puts '** BEGIN ELASTICA SETUP '
    puts '---'
    on(roles('controller','injector'), user: 'root', environment: XP5K::Config[:openstack_env]) do
        cmd = []
        cmd << %{echo 'ulimit -n 65535' >> /root/.bashrc}
        cmd << %{echo 'fs.file-max =  100000' >> /etc/sysctl.conf}
        cmd << %{echo 'net.ipv4.ip_local_port_range=\"1025 65535\"' >> /etc/sysctl.conf}
        cmd << %{echo '*    soft     nofile   65536' >> /etc/security/limits.conf}
        cmd << %{echo '*    hard     nofile   65536' >> /etc/security/limits.conf}
        cmd << %{echo 'session    required   pam_limits.so' >> /etc/pam.d/common-session}
        cmd << %{echo 'session    required   pam_limits.so' >> /etc/pam.d/common-session-noninteractive}
        cmd << %{echo 300000 | sudo tee /proc/sys/fs/nr_open}
        cmd << %{echo 300000 | sudo tee /proc/sys/fs/file-max}
        cmd << %{sysctl -p}
        cmd << %{apt-get -y install openjdk-7-jre-headless}
        cmd
    end

    sh %{cat /dev/null > #{XP5K::Config[:elastica_home]}/tmp/injectors.txt}
    roles('injector').each do |inj|
        sh %{scp -r #{XP5K::Config[:elastica_home]}/gatling root@#{inj}:~/}
        sh %{echo #{inj} >> #{XP5K::Config[:elastica_home]}/tmp/injectors.txt}
    end
    on(roles('controller'), user: 'root', environment: XP5K::Config[:openstack_env]) do
        cmd = []
#        cmd << %{echo 'export OS_USERNAME=admin' > ~/adminrc.sh}
#        cmd << %{echo 'export OS_PASSWORD=admin' >> ~/adminrc.sh}
#        cmd << %{echo 'OS_TENANT_NAME=openstack' >> ~/adminrc.sh}
#        cmd << %{echo 'OS_AUTH_URL=http://127.0.0.1:5000/v2.0' >> ~/adminrc.sh}
        cmd << %{cp  ~/adminrc ~/openrc}
        cmd << %{echo 'source ~/adminrc' >> ~/.bashrc}
        cmd << %{echo 'export PROJECT_PATH=/share' >> /root/.bashrc}
#        cmd << %{apt-get -y install portmap nfs-common nfs-kernel-server}
        cmd << %{mkdir /share}
        cmd << %{chmod 777 /share}
#        cmd << %{echo '/share *(ro)' >> /etc/exports}
#        cmd << %{service nfs-kernel-server restart}
        cmd
    end

    controllerserver = roles('controller').first
    sh %{scp -r #{XP5K::Config[:elastica_home]}/* root@#{controllerserver}:/share/}
    logstash = "logstash-1.4.2"
    directory = "/share/software_resources/logstash"

    on(roles('controller'), user: 'root', environment: XP5K::Config[:openstack_env]) do
        cmd = []
        cmd << %{nova quota-class-update --instances 50 default}
        cmd << %{nova quota-class-update --cores 50 default}
        cmd << %{nova quota-class-update --ram -1 default}
        cmd << %{nova quota-class-update --floating_ips -1 default}
        cmd << %{nova quota-class-update --metadata_items -1 default}
        cmd << %{nova quota-class-update --injected_files -1 default}
        cmd << %{nova quota-class-update --injected_file_content_bytes -1 default}
        cmd << %{nova quota-class-update --injected_file_path_bytes -1 default}
        cmd << %{sed -i 's/^\\(export ADRESSE_IP_SERVER_REDIS\\)=.*$/\\1='$(ifconfig br-ex | grep "inet addr" | cut -d ':' -f2 | cut -d ' ' -f1)'/g' /share/common/util.sh}
        cmd << %{ssh-keygen -f /tmp/id_rsa -t rsa -N ''}
        cmd << %{nova keypair-add --pub_key /tmp/id_rsa.pub key}
        cmd << %{chmod +x /share/software_resources/redis/install.sh}
        cmd << %{PROJECT_PATH=/share /share/software_resources/redis/install.sh}
        cmd << %{cp #{directory}/#{logstash}.tar.gz /root/}
        cmd << %{cp #{directory}/indexer_logstash.conf /root/}
        cmd << %{tar xvzf /root/#{logstash}.tar.gz} #&& cp -r #{logstash} /root/}
        cmd
    end
    id_rsa_ctrl=`ssh root@#{controllerserver} "cat /tmp/id_rsa.pub"`
#    puts "#{id_rsa_ctrl}"
    on(roles('injector'), user: 'root', environment: XP5K::Config[:openstack_env]) do
       ["echo '#{id_rsa_ctrl}' >> /root/.ssh/authorized_keys"]
    end

    puts '--- END ELASTICA SETUP'
  end
 end


 namespace :experiment do
  desc 'Experiment Initialization'
  task :init do
     puts "Running Experiment"
puts "#{XP5K::Config[:openstack_env].class}"
     tmp_env = XP5K::Config[:openstack_env].merge(XP5K::Config[:elastica_env])
     on(roles('controller'), user: 'root', environment: tmp_env) do
	 cmd = []
         (1..XP5K::Config[:computes].to_i).each do |i|
                compute = roles('compute').at(i-1)

		puts "#{XP5K::Config[:openstack_env]}"

		puts "Launching DB on host #{compute}"
   		cmd << %{/share/apicloud/new_vm.sh 4 db-rubis#{i} db dbtier#{i} #{compute}}
		
		cmd << %{nova list | grep db-rubis#{i} | tr "|" " " |tr -s " " | cut -d ' ' -f8 > /tmp/dbinfo}	
	
		puts "Scaling tier#{i} on host #{compute}"
		cmd << %{/share/apicloud/scale-iaas.sh out tier#{i} #{compute}}
         end   
         cmd
     end
  end
  
  desc 'Experiment Infrastructure Destruction'
  task :destroy do
     puts "Experiment Destroy"
     
     tmp_env = XP5K::Config[:openstack_env].merge(XP5K::Config[:elastica_env])
     
     on(roles('controller'), user: 'root', environment: tmp_env) do
	cmd = []
        cmd << %{nova list | awk '$2 && $2 != "ID" {print $2}' | xargs -n1 sh -c 'nova delete'}
	cmd << %{rm -rf /tier}
	cmd << %{echo '#!/bin/bash' > /root/action.sh}
        cmd << %{echo "echo \$0 \$1" >> /root/action.sh}
        cmd << %{echo "source $PROJECT_PATH/common/util.sh" >> /root/action.sh}
        cmd << %{chmod +x /root/action.sh}
        cmd
     end
  end
  
  desc 'Experiment Infrastructure Destruction'
  task :run do
     puts "Experiment Run"
     on(roles('controller'), user: 'root', environment: XP5K::Config[:openstack_env]) do
	cmd = []
        cmd << %{unset http_proxy}
	cmd << %{unset https_proxy}
	cmd << %{echo "log_cloud_state b_\$1" >> /root/action.sh}
        cmd << %{echo "$PROJECT_PATH/apicloud/strategies/$strategy.sh \$1 tier" >> /root/action.sh}
        cmd << %{echo "log_cloud_state e_\$1" >> /root/action.sh}
        cmd << %{chmod +x /root/action.sh}
        cmd
     end
  end


 end
end


  
def update_common_with_networks
  interfaces = get_node_interfaces
  common = YAML.load_file("scenarios/#{XP5K::Config[:scenario]}/hiera/generated/common.yaml")
  common['scenario::openstack::admin_password'] = XP5K::Config[:openstack_env][:OS_PASSWORD]

#  common = YAML.load_file("scenarios/#{XP5K::Config[:scenario]}/hiera/generated/common.yaml")
#  vlanids = xp.job_with_name("#{XP5K::Config[:jobname]}")['resources_by_type']['vlans']

  controller = roles('controller').first
  common['scenario::openstack::controller_public_address'] = interfaces[controller]["public"]["ip"]
  storage = controller #roles('storage').first
  common['scenario::openstack::storage_public_address'] = interfaces[storage]["public"]["ip"]

  # each specific OpenStack network is picked in the reserved vlan
  # if the number of interfaces is sufficient
  # TODO handle more than 1 vlan 
  # 1 for management (in this implementation management is the same as public)
  # 1 for data 
#  ['data_network'].each_with_index do |network, i| 
   # if (XP5K::Config[:interfaces] > 1)
   #  common["scenario::openstack::#{network}"] = G5K_NETWORKS[XP5K::Config[:site]]["vlans"][vlanids[i % vlanids.size].to_i]
   # else
#     common["scenario::openstack::#{network}"] = G5K_NETWORKS[XP5K::Config[:site]]["production"]
   # end
#  end

  common['scenario::openstack::network'] = G5K_NETWORKS[XP5K::Config[:site]]['production']
 # common['scenario::openstack::network'] = G5K_NETWORKS[XP5K::Config[:site]]['production']
 # common['scenario::openstack::public_network'] = G5K_NETWORKS[XP5K::Config[:site]]["production"]

  File.open("scenarios/#{XP5K::Config[:scenario]}/hiera/generated/common.yaml", 'w') do |file|
    file.puts common.to_yaml
  end
end
