# kvm-lab — домашняя KVM + Kubernetes лаборатория как код

Схема: local_lab.drawio (сеть 192.168.31.0/24)
- **Terraform (libvirt)**: 3 ВМ (control-plane + 2 worker), bridge br0, статика через cloud-init
- **Ansible**: bootstrap kubeadm-кластера (containerd, kubeadm, init, join, kubeconfig)
- **k8s/**: MetalLB, Ingress-манифесты (argocd/grafana/app .local)

## Быстрый старт
1. `cp terraform.tfvars.example terraform.tfvars` и заполнить своими значениями
2. `terraform init && terraform apply`
3. `cd ansible && ansible-playbook -i inventory.ini site.yml`
4. `export KUBECONFIG=$PWD/.kube/lab-config && kubectl get nodes`

## Секреты
В Git НЕ попадают: terraform.tfvars, tfstate, inventory.ini, kubeconfig (см. .gitignore).