resource "libvirt_network" "lab" {
  name      = "lab-net"
  mode      = "bridge"
  bridge    = "br0"
  autostart = true
}

resource "libvirt_volume" "base_image" {
  name   = "ubuntu-jammy-base.qcow2"
  pool   = "default"
  source = var.base_image_url
}

resource "libvirt_volume" "vm_disk" {
  count          = length(var.nodes)
  name           = "${var.nodes[count.index].name}.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base_image.id
  size           = var.vm_disk_size
}

resource "libvirt_cloudinit_disk" "init" {
  count = length(var.nodes)
  name  = "${var.nodes[count.index].name}-init.iso"
  pool  = "default"

  user_data = templatefile("${path.module}/cloud_init.cfg.tpl", {
    hostname       = var.nodes[count.index].name
    ssh_public_key = file(var.ssh_public_key_path)
  })

  network_config = templatefile("${path.module}/network_config.tpl", {
    ip_address = var.nodes[count.index].ip
  })
}

resource "libvirt_domain" "vm" {
  count  = length(var.nodes)
  name   = var.nodes[count.index].name
  memory = var.nodes[count.index].memory
  vcpu   = var.nodes[count.index].vcpu

  cloudinit = libvirt_cloudinit_disk.init[count.index].id

  network_interface {
    network_id     = libvirt_network.lab.id
    mac            = var.nodes[count.index].mac
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.vm_disk[count.index].id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}

# >>> Terraform сам пишет inventory для Ansible <<<
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/ansible/inventory.ini"
  content = templatefile("${path.module}/ansible/inventory.ini.tpl", {
    nodes           = var.nodes
    ssh_private_key = var.ssh_private_key_path
  })
}