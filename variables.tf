variable "nodes" {
  description = "Lab nodes: single source of truth"
  type = list(object({
    name   = string
    role   = string
    ip     = string
    mac    = string
    memory = number
    vcpu   = number
  }))
  default = [
    { name = "k8s-control-plane", role = "control-plane", ip = "192.168.31.111", mac = "52:54:00:8a:12:01", memory = 4096, vcpu = 2 },
    { name = "k8s-worker01",      role = "worker",        ip = "192.168.31.112", mac = "52:54:00:8a:12:02", memory = 4096, vcpu = 2 },
    { name = "k8s-worker02",      role = "worker",        ip = "192.168.31.113", mac = "52:54:00:8a:12:03", memory = 4096, vcpu = 2 },
  ]
}

variable "libvirt_uri" {
  description = "URI подключения к libvirtd"
  type        = string
}

variable "ssh_public_key_path" {
  type = string
}

variable "ssh_private_key_path" {
  type = string
}

variable "base_image_url" {
  default = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
}

variable "vm_disk_size" {
  default = 21474836480
}