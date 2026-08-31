# kvm-k8s-lab — домашняя KVM + Kubernetes лаборатория как код

Полный жизненный цикл кластера «как в проде», на домашнем железе:

- **Инфраструктура как код** — Terraform + libvirt (3 VM на KVM-хосте)
- **Кластер как код** — Ansible + kubeadm (идемпотентный playbook)
- **Платформа как код** — ArgoCD GitOps (все приложения из Git)
- **Секреты как код** — SealedSecrets (зашифрованные секреты в Git)
- **Защита данных** — Velero + MinIO (S3) + офсайт-копия на Mac
- **Проверенный DR** — полное воссоздание кластера с нуля и восстановление

Схема сети: `local_lab.drawio` (192.168.31.0/24)

## Архитектура

```
Mac (terraform / ansible / kubectl / mc, копия бэкапов ~/velero-backups)
 │  qemu+ssh (ivan@192.168.31.110)
 ▼
KVM-хост, bridge br0
 ├── k8s-control-plane  192.168.31.111   (40 GiB, 8 GiB RAM, 2 vCPU, host-passthrough)
 ├── k8s-worker01       192.168.31.112
 └── k8s-worker02       192.168.31.113

Кластер (Ubuntu 22.04, kubeadm 1.31, containerd, flannel):
 ├── Longhorn        — распределённое хранилище (PVC)
 ├── MetalLB (L2)    — LoadBalancer для bare-metal
 ├── ingress-nginx   — ingress + wildcard TLS
 ├── ArgoCD          — GitOps (App-of-Apps из gitops/root)
 ├── SealedSecrets   — секреты, зашифрованные в Git
 ├── MinIO           — S3-хранилище для бэкапов
 ├── Velero          — бэкапы кластера + kopia fs-backup томов
 ├── Monitoring      — Prometheus / Grafana / Loki / Promtail
 └── Демо-нагрузка   — task-api + PostgreSQL (Bitnami chart)
```

## Структура проекта

```
kvm-k8s-lab/
├── terraform/
│   ├── main.tf                # VM, диски, cloud-init, генерация inventory для Ansible
│   ├── variables.tf           # список нод (ip/mac/ram/vcpu), vm_disk_size = 40 GiB
│   ├── terraform.tfvars       # ⚠️ в gitignore: libvirt_uri, пути к ключам
│   ├── cloud_init.cfg.tpl     # user ubuntu, ssh-ключ, sysctl/modprobe для k8s
│   └── network_config.tpl     # статические IP
├── ansible/
│   ├── inventory.ini          # генерируется Terraform — руками не править!
│   └── cluster.yml            # containerd + kubeadm init/join + flannel (идемпотентный)
├── bootstrap/
│   ├── bootstrap.sh           # ArgoCD → MetalLB → ingress-nginx → SealedSecrets → root-app
│   ├── install-argocd.sh      # ArgoCD v3.5.1 + ApplicationSet CRD (server-side apply)
│   ├── root-app.yaml          # корневое Application (App-of-Apps)
│   └── sealed-secrets.pem     # ПУБЛИЧНЫЙ сертификат kubeseal (секретом не является)
├── gitops/
│   ├── root/                  # ArgoCD Applications: longhorn, minio, velero, postgresql,
│   │                          #   monitoring, loki, promtail, grafana-*, task-api,
│   │                          #   metallb-config, lab-ingresses, tls-wildcard, ...
│   └── platform/              # SealedSecrets (minio-credentials, velero-credentials, ...)
└── README.md
```

## Быстрый старт

### 1. Инфраструктура

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # заполнить libvirt_uri, пути к ключам
terraform init && terraform apply -auto-approve
```

### 2. Кластер

```bash
cd ..
ansible-playbook -i ansible/inventory.ini ansible/cluster.yml
ssh ubuntu@192.168.31.111 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config
kubectl get nodes
```

### 3. Платформа (GitOps)

```bash
./bootstrap.sh
```

### 4. Credentials приватного репозитория для ArgoCD (вручную, НЕ в Git!)

```bash
read -s GITHUB_PAT
kubectl apply -f - << SECRETEOF
apiVersion: v1
kind: Secret
metadata:
  name: kvm-k8s-lab-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/sadqwes/kvm-k8s-lab.git
  username: sadqwes
  password: $GITHUB_PAT
SECRETEOF
```

### 5. Дождаться синка и сделать первый бэкап

```bash
kubectl get applications -n argocd          # все Synced/Healthy
velero backup create full-backup-1 --default-volumes-to-fs-backup --wait
kubectl get podvolumebackups -n velero -l velero.io/backup-name=full-backup-1  # ОБЯЗАТЕЛЬНАЯ проверка fs-backup!
```

### 6. Офсайт-копия на Mac (вне зоны катастрофы)

```bash
kubectl port-forward -n minio-system svc/minio 9000:9000 &
PASS=$(kubectl get secret minio-credentials -n minio-system -o jsonpath='{.data.rootPassword}' | base64 -d)
mc alias set local http://localhost:9000 admin "$PASS"
mc mirror local/velero-backups/ ~/velero-backups/
kill %1
```

## Секреты: что где живёт

| Что | Где | В Git? |
|---|---|---|
| Пароли MinIO/Velero/Postgres/TLS | SealedSecrets в `gitops/platform/` | ✅ (зашифрованные) |
| Публичный сертификат kubeseal | `bootstrap/sealed-secrets.pem` | ✅ |
| Приватный ключ sealed-secrets | только в кластере (kube-system) | ❌ |
| GitHub PAT для ArgoCD | Secret в кластере, создаётся вручную | ❌ |
| tfvars, tfstate, inventory, kubeconfig | локально | ❌ (.gitignore) |

## Disaster Recovery Runbook

Проверен сценарий: `terraform destroy` → воссоздание VM → кластер с нуля → восстановление.

```bash
# 1. Новые VM
cd terraform && terraform apply -auto-approve

# 2. Свежие host keys SSH
ssh-keygen -R 192.168.31.111; ssh-keygen -R 192.168.31.112; ssh-keygen -R 192.168.31.113

# 3. Кластер
cd .. && ansible-playbook -i ansible/inventory.ini ansible/cluster.yml
ssh ubuntu@192.168.31.111 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config

# 4. Платформа
./bootstrap.sh

# 5. Repo-credentials для ArgoCD (см. «Быстрый старт», шаг 4) → дождаться Synced приложений

# 6. Вернуть бэкапы с Mac в MinIO
kubectl port-forward -n minio-system svc/minio 9000:9000 &
PASS=$(kubectl get secret minio-credentials -n minio-system -o jsonpath='{.data.rootPassword}' | base64 -d)
mc alias set local http://localhost:9000 admin "$PASS"
mc mb --ignore-existing local/velero-backups
mc mirror ~/velero-backups/ local/velero-backups/
kill %1

# 7. Restore
velero backup-location get    # ждём Available
velero restore create --from-backup full-backup-1 --wait

# 8. Разрешить конфликты владения SealedSecrets (restore вернул plain-секреты без ownerReference)
for ns in default ingress-nginx longhorn-system monitoring argocd; do
  kubectl delete secret tls-wildcard -n $ns --ignore-not-found
done
kubectl delete secret task-api-postgres -n default --ignore-not-found
kubectl delete secret grafana-admin-password slack-webhook -n monitoring --ignore-not-found
kubectl delete pod -n kube-system -l name=sealed-secrets-controller

# 9. Проверка
kubectl get applications -n argocd
kubectl get pods -A | grep -vE 'Running|Completed'
```

Старый приватный ключ sealed-secrets возвращается из бэкапа (secret `sealed-secrets-key*` в kube-system) — после шага 8 все SealedSecrets расшифровываются сами.

## Известные проблемы и решения (выстрадано)

| # | Симптом | Причина | Решение |
|---|---|---|---|
| 1 | `mc`: signature mismatch | пароль ротирован, реальный — в секрете | брать из `minio-credentials.rootPassword` |
| 2 | MinIO post-job: exit 127 / ImagePullBackOff | свежие образы MinIO/mc требуют x86-64-v2, CPU VM — qemu64 | пин старого образа + `users: [] buckets: [] svcaccts: []` (иначе чарт рендерит post-job) или `cpu.mode = "host-passthrough"` |
| 3 | Velero BSL Unavailable, `no EC2 IMDS role found` | без явного credential плагин идёт в EC2 metadata | `backupStorageLocation[].credential: {name, key}` в values чарта |
| 4 | Secret от SealedSecret пересоздан пустым (DATA 0) | `credentials.useSecret: true` — Helm создаёт свой Secret поверх | убрать блок, ссылаться на секрет только через BSL credential |
| 5 | `backups.longhorn.io not found` | kubectl берёт первый CRD с тем же kind | полные имена: `backup.velero.io`, `backup.longhorn.io` |
| 6 | `REMOTE HOST IDENTIFICATION HAS CHANGED` | VM пересозданы — новые host keys | `ssh-keygen -R <ip>` |
| 7 | `Permission denied (publickey)` | пользователь VM ≠ пользователь гипервизора | `ubuntu` + ключ `id_terraform_libvirt` (истина — в inventory.ini) |
| 8 | `git mv: not under version control` | tfvars/state в gitignore | tracked — `git mv`, игнорируемые — `mv` |
| 9 | ArgoCD: `Repository not found` после DR | repo-credentials жили только в старом кластере | ручной Secret с label `argocd.argoproj.io/secret-type: repository` |
| 10 | ApplicationSet CRD: `annotations: Too long` | CRD > 256 KiB в last-applied | `kubectl apply --server-side` (уже в install-argocd.sh) |
| 11 | SealedSecrets не расшифровываются на новом кластере | контроллер сгенерировал новый ключ | вернуть старый ключ из бэкапа или перепечатать новым cert |
| 12 | `Resource already exists and is not managed by SealedSecret` | restore вернул plain-секреты без ownerReference | удалить plain-секреты — контроллер пересоздаст сам |
| 13 | Данные postgres не восстановились | ArgoCD создал PVC раньше restore; Velero пропускает существующие PVC | restore ДО GitOps-sync / удалить PVC / прицельный restore; для БД — pg_dump |
| 14 | `Multi-Attach error` при rollout restart | RWO-том держит старый pod | `rollout undo` или удалить новый pod |
| 15 | velero CLI: `no such host` в warnings/errors | Mac не резолвит кластерный DNS `*.svc` | диагностика через `kubectl exec` в velero pod |
| 16 | Longhorn Setting вечно OutOfSync | оператор нормализует value в `{"v1":"2","v2":"2"}` | писать value в live-формате или ignoreDifferences |
| 17 | FailedMount: secret not found при старте | pod стартовал раньше unseal | `rollout restart` после появления секрета |

## Уроки

1. **Бэкапы живут вне зоны катастрофы.** MinIO на тех же дисках, что и кластер, — не защита от потери железа; копия на Mac обязательна.
2. **Порядок операций критичен.** Restore данных — до того, как GitOps создаст PVC.
3. **DR-ранбук существует только тогда, когда он пройден руками.** Каждый пункт таблицы выше — реальная починка, а не теория.
4. **Fs-backup не гарантирует снимок БД.** После бэкапа проверять `podvolumebackups`; для СУБД добавлять application-level бэкапы (pg_dump).
5. **Публично всё, кроме приватного ключа.** Сертификат kubeseal — в Git; PAT и tfvars — никогда.

## TODO

- [ ] `velero schedule create daily-backup --schedule="0 2 * * *"` + автоматический mirror на Mac (cron)
- [ ] CronJob pg_dump в MinIO (application-level бэкап postgres)
- [ ] cert-manager вместо ручного wildcard TLS
- [ ] Регулярный backup-drill: restore в отдельный namespace/кластер
- [ ] Dashboard «DR readiness» в Grafana (возраст последнего бэкапа, статус BSL)
