#cloud-config
hostname: ${hostname}
manage_etc_hosts: true

packages:
  - curl
  - ca-certificates
  - gnupg

write_files:
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
  - path: /etc/sysctl.d/99-kubernetes.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1

runcmd:
  - modprobe overlay
  - modprobe br_netfilter
  - sysctl --system
  - swapoff -a
  - sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_public_key}
ssh_pwauth: false