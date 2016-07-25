# scenario : liberty_multinodes_elastica

This scenario install Openstack Liberty on multiple nodes using the following topology.

* 1 puppet server
* 1 Controller node --- hosts core services, MySQL database, RabbitMQ, glance service, cloud router and gatling injector
* n compute nodes --- host virtual servers
* n-1 injectors --- hosts gatling load injector

Nodes         | Description         | Puppet recipe
--------------|-------------------- | -------------
Controller    | Core services       | `puppet/modules/scenario/manifests/controller.pp`
Storage       | Glance API + backend| `puppet/modules/scenario/manifests/storage.pp`
Network       | Routing node        | `puppet/modules/scenario/manifests/network.pp`
Compute       | Hypervisor          | `puppet/modules/scenario/manifests/compute.pp`

## Optionnal ```xp.conf``` parameters

The following parameters are optionnal in the ```xp.conf``` file. If some are not set,
default values will bet set for them (see ```tasks/scenario.rb```). Here is an example :

```
site	   'rennes'
cluster    'parasilo'
vlantype   'kavlan'
computes   3
```

__Notes__ :  

* The total number of nodes used by the deployment is ```2*computes + 1```

## Openstack configuration

* By default 1 images are added to Glance :
  * [Ubuntu](https://cloud-images.ubuntu.com/releases/12.04.4/release-20120424/ubuntu-12.04-server-cloudimg-amd64-disk1.img)
* SSH and ICMP are allowed in the default security group.
* Network configuration :
  * Create __private__ and __public__ networks.
  * Create a __public__ subnet for floating IP's using reserved subnet.
  * Create a __private__ subnet for VM's local network.
  * Create a router __main_router__ using the reserved network as gateway and connected to the __private__ subnet.

__Notes__ : See `./tasks/scenario.rb`.
