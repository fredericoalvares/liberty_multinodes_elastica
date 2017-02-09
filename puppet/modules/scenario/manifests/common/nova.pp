# Module:: scenario
# Manifest:: common/nova.pp
#

class scenario::common::nova (
  String $admin_password = $scenario::openstack::params::admin_password,
  String $controller_public_address = $scenario::openstack::params::controller_public_address,
  String $storage_public_address = $scenario::openstack::params::storage_public_address,
) {

  class {
    '::nova':
      database_connection      => "mysql://nova:nova@${controller_public_address}/nova?charset=utf8",
#      api_database_connection  => "mysql+pymysql://nova:nova@${controller_public_address}/nova_api?charset=utf8",
      rabbit_host              => $controller_public_address,
      rabbit_userid            => 'nova',
      rabbit_password          => 'an_even_bigger_secret',
      glance_api_servers       => "${storage_public_address}:9292",
      verbose                  => true,
      debug                    => true,
  } 

  class { '::nova::network::neutron':
    neutron_admin_password => $admin_password,
    neutron_admin_auth_url => "http://${controller_public_address}:35357/v2.0",
    neutron_url => "http://${controller_public_address}:9696",
#    vif_plugging_is_fatal => false,
#    vif_plugging_timeout  => '10',
  }


  nova_config { 
    'DEFAULT/cpu_allocation_ratio' : value => 1.0;
    'DEFAULT/ram_allocation_ratio' : value => 1.0;
#    'DEFAULT/scheduler_weight_classes' : value => nova.scheduler.weights.all_weighers;
    'DEFAULT/ram_weight_multiplier' : value => -1.0;
  } 

}

