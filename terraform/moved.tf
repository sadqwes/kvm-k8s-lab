moved {
  from = libvirt_volume.vm_disk[0]
  to   = libvirt_volume.vm_disk["k8s-control-plane"]
}

moved {
  from = libvirt_volume.vm_disk[1]
  to   = libvirt_volume.vm_disk["k8s-worker01"]
}

moved {
  from = libvirt_volume.vm_disk[2]
  to   = libvirt_volume.vm_disk["k8s-worker02"]
}

moved {
  from = libvirt_cloudinit_disk.init[0]
  to   = libvirt_cloudinit_disk.init["k8s-control-plane"]
}

moved {
  from = libvirt_cloudinit_disk.init[1]
  to   = libvirt_cloudinit_disk.init["k8s-worker01"]
}

moved {
  from = libvirt_cloudinit_disk.init[2]
  to   = libvirt_cloudinit_disk.init["k8s-worker02"]
}

moved {
  from = libvirt_domain.vm[0]
  to   = libvirt_domain.vm["k8s-control-plane"]
}

moved {
  from = libvirt_domain.vm[1]
  to   = libvirt_domain.vm["k8s-worker01"]
}

moved {
  from = libvirt_domain.vm[2]
  to   = libvirt_domain.vm["k8s-worker02"]
}
