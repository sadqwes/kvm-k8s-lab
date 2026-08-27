output "vm_ips" {
  value = { for n in var.nodes : n.name => n.ip }
}