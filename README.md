# kvm-k8s-lab — домашняя KVM + Kubernetes лаборатория как код

Полный жизненный цикл кластера «как в проде», на домашнем железе:

- **Инфраструктура как код** — Terraform + libvirt (3 VM на KVM-хосте)
- **Кластер как код** — Ansible + kubeadm (идемпотентный playbook)
- **Платформа как код** — ArgoCD GitOps (все приложения из Git)
- **Секреты как код** — SealedSecrets (зашифрованные секреты в Git)
- **Защита данных** — Velero + MinIO (S3) + офсайт-копия на Mac
- **Автоматические бэкапы** — schedule в кластере + launchd-агент на Mac
- **Проверенный DR** — полное воссоздание кластера с нуля и восстановление


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

Автоматические бэкапы:
 ├── Внутри кластера: velero schedule каждые 6 часов
 └── На Mac: launchd каждые 4 часа → проверяет возраст последнего бэкапа
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
# ОБЯЗАТЕЛЬНАЯ проверка fs-backup:
kubectl get podvolumebackups -n velero -l velero.io/backup-name=full-backup-1
```

### 6. Офсайт-копия на Mac (вне зоны катастрофы)

```bash
kubectl port-forward -n minio-system svc/minio 9000:9000 &
PASS=$(kubectl get secret minio-credentials -n minio-system -o jsonpath='{.data.rootPassword}' | base64 -d)
mc alias set local http://localhost:9000 admin "$PASS"
mc mirror --overwrite local/velero-backups/ ~/velero-backups/
kill %1
```

### 7. Автоматические бэкапы

```bash
# Schedule внутри кластера (каждые 6 часов)
velero schedule create periodic-backup \
  --schedule="0 */6 * * *" --ttl 720h --default-volumes-to-fs-backup

# Mac launchd-агент (каждые 4 часа)
cat > ~/Library/LaunchAgents/com.sadqwes.velero-auto-backup.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sadqwes.velero-auto-backup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/sadqwes/velero-auto-backup.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.sadqwes.velero-auto-backup.plist
```

## Секреты: что где живёт

| Что | Где | В Git? |
|---|---|---|
| Пароли MinIO/Velero/Postgres/TLS | SealedSecrets в `gitops/platform/` | ✅ (зашифрованные) |
| Публичный сертификат kubeseal | `bootstrap/sealed-secrets.pem` | ✅ |
| Приватный ключ sealed-secrets | только в кластере (kube-system) | ❌ |
| GitHub PAT для ArgoCD | Secret в кластере, создаётся вручную | ❌ |
| tfvars, tfstate, inventory, kubeconfig | локально | ❌ (.gitignore) |

## Бэкапы: схема

Кластер работает нерегулярно (ПК выключается), поэтому одной стратегии недостаточно. Три слоя:

```
┌─────────────────────────────────────────────────────────────┐
│ Кластер (работает нерегулярно)                              │
│                                                             │
│  velero schedule "0 */6 * * *"                              │
│  └── пытается сделать бэкап каждые 6 часов                   │
│      (пропускает, если кластер выключен)                    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Mac (работает почти всегда)                                 │
│                                                             │
│  launchd: каждые 4 часа → ~/velero-auto-backup.sh           │
│  └── Проверяет доступность кластера                         │
│      └── Проверяет возраст последнего Completed-бэкапа      │
│          └── Если > 24 часов → velero backup create          │
│              └── mc mirror --overwrite (весь бакет)         │
│                  └── ~/velero-backups/ (офсайт-копия)       │
└─────────────────────────────────────────────────────────────┘
```

### Скрипт авто-бэкапа (`~/velero-auto-backup.sh`)

```bash
#!/bin/bash
set -e

LOG_FILE="$HOME/velero-auto-backup.log"
exec >> "$LOG_FILE" 2>&1

echo "=== $(date) ==="

# Проверяем доступность кластера
if ! kubectl cluster-info &>/dev/null; then
  echo "Кластер недоступен, пропускаем"
  exit 0
fi

# Возраст последнего Completed-бэкапа.
# ВАЖНО: берём через kubectl — velero CLI -o json отдаёт массив без .items
LAST_BACKUP_TS=$(kubectl get backups.velero.io -n velero -o json 2>/dev/null | \
  jq -r '[.items[] | select(.status.phase == "Completed")] |
         sort_by(.status.startTimestamp) | reverse |
         .[0].status.startTimestamp // empty')

if [ -z "$LAST_BACKUP_TS" ]; then
  echo "Завершённых бэкапов нет, делаем первый"
  AGE_HOURS=9999
else
  LAST_SEC=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_BACKUP_TS" "+%s" 2>/dev/null || echo "0")
  NOW_SEC=$(date "+%s")
  AGE_HOURS=$(( (NOW_SEC - LAST_SEC) / 3600 ))
  echo "Последний бэкап: $LAST_BACKUP_TS ($AGE_HOURS ч назад)"
fi

if [ "$AGE_HOURS" -lt 24 ]; then
  echo "Свежий бэкап есть, пропускаем"
  exit 0
fi

BACKUP_NAME="auto-$(date +%Y%m%d-%H%M%S)"
echo "Создаём бэкап $BACKUP_NAME..."

if velero backup create "$BACKUP_NAME" --default-volumes-to-fs-backup --wait; then
  echo "✅ Бэкап $BACKUP_NAME создан, синхронизируем ВЕСЬ бакет на Mac..."

  kubectl port-forward -n minio-system svc/minio 9000:9000 &
  PF_PID=$!
  sleep 3

  PASS=$(kubectl get secret minio-credentials -n minio-system -o jsonpath='{.data.rootPassword}' | base64 -d)
  mc alias set local http://localhost:9000 admin "$PASS" 2>/dev/null || true

  # ВАЖНО: копируем ВЕСЬ бакет (backups + kopia), с --overwrite для обновления метаданных репозитория
  mc mirror --overwrite local/velero-backups/ "$HOME/velero-backups/"

  kill $PF_PID 2>/dev/null || true
  echo "✅ Готово"
else
  echo "❌ Ошибка создания бэкапа"
  exit 1
fi
```

### Локальная копия: только весь бакет

Папка `backups/<name>/` содержит **только метаданные**. Данные томов лежат в общем kopia-репозитории (префикс `kopia/`). Поэтому офсайт-копия = mirror **всего бакета** с `--overwrite`:

```bash
mc mirror --overwrite local/velero-backups/ ~/velero-backups/
```

Без `--overwrite` не обновляются изменяемые метаданные репозитория (`kopia.repository`, `kopia.blobcfg`), и новые снапшоты из локальной копии не видны.

### Аудит

```bash
cat ~/velero-auto-backup.log
launchctl list | grep velero
```

## Disaster Recovery Runbook

Проверен сценарий: `terraform destroy` → воссоздание VM → кластер с нуля → восстановление.

```bash
# 1. Новые VM
cd terraform && terraform apply -auto-approve

# 2. Свежие host keys SSH (VM пересозданы — новые fingerprint)
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
mc mirror --overwrite ~/velero-backups/ local/velero-backups/
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
| 18 | jq: `Cannot iterate over null` при парсинге бэкапов | `velero backup get -o json` отдаёт массив без `.items` | брать через `kubectl get backups.velero.io -n velero -o json` |
| 19 | `mc mirror`: `Overwrite not allowed (mm-source-mtime)` | локальная копия новее источника | для kopia-блобов безвредно, но `kopia.repository` и `kopia.blobcfg` должны обновляться — использовать `--overwrite` |
| 20 | MinIO PVC 5Gi заполнился до 100% — Velero backups Failed, Deleting застряли, ArgoCD OutOfSync после live-патча | `df -h /export` в поде minio = 100%; `velero backup get` = Failed/Deleting; diff live 10Gi vs desired 5Gi | `mc rm --recursive` по бакету → рестарт пода minio (освободил file descriptors) → PVC 5Gi→10Gi + reconcile манифеста в gitops → пересоздание BackupRepository после wipe → TTL schedules 720h→168h | 21.09.2026 |

## Уроки

### Архитектурные

1. **Бэкапы живут вне зоны катастрофы.** MinIO на тех же дисках, что и кластер, — не защита от потери железа; копия на Mac обязательна.
2. **Локальная копия = весь бакет, не папка бэкапа.** В `backups/<name>/` только метаданные; данные томов в kopia-репозитории.
3. **Порядок операций критичен.** Restore данных — до того, как GitOps создаст PVC.
4. **DR-ранбук существует только тогда, когда он пройден руками.** Каждый пункт таблицы выше — реальная починка, а не теория.
5. **Fs-backup не гарантирует снимок БД.** После бэкапа проверять `podvolumebackups`; для СУБД добавлять application-level бэкапы (pg_dump).

### Для непостоянного кластера

6. **Одной стратегии бэкапов недостаточно.** Schedule в кластере + launchd-агент на Mac, который компенсирует пропуски.
7. **Возраст последнего бэкапа — главный триггер.** Агент смотрит не на часы работы, а на дату последнего Completed.
8. **`--overwrite` обязателен.** kopia-репозиторий содержит изменяемые метаданные, без перезаписи новые снапшоты из локальной копии не видны.

### Операционные

9. **Публично всё, кроме приватного ключа.** Сертификат kubeseal — в Git; PAT и tfvars — никогда.
10. **SealedSecrets ключ** — после пересоздания кластера генерируется новый; старый возвращается через Velero restore.
11. **Credentials репозитория** — не в Git, создаются вручную после bootstrap.
12. **Конфликты владения** — после restore удалять plain secrets, которые конфликтуют с SealedSecrets.
13. **Гонка при старте** — pod может стартовать раньше, чем SealedSecret расшифруется → рестарт пода после появления secret.
14. **RWO volume конфликты** — при rollout restart использовать `rollout undo` или удалять старый pod первым.

## TODO

- [ ] CronJob pg_dump в MinIO (application-level бэкап postgres — дополнение к fs-backup)
- [ ] cert-manager вместо ручного wildcard TLS
- [ ] Регулярный backup-drill: restore в отдельный namespace/кластер
- [ ] Dashboard «DR readiness» в Grafana (возраст последнего бэкапа, статус BSL, статус schedule)
- [ ] Telegram-уведомления о статусе авто-бэкапов (alertmanager → bot)

## Лицензия

MIT

---

**Автор:** sadqwes
**Дата:** 2026-08-31
**Статус:** Production-ready (DR tested ✅, auto-backup working ✅)

## Что дальше

- [ ] Акт 2 до конца: ужесточить гейты SAST/SCA (убрать `continue-on-error`) после зелёных фиксов
- [ ] gitleaks в pre-commit и CI — слой secret scanning
- [ ] Контрольный прогон OWASP ZAP baseline после фикса actuator: сравнить отчёты до/после
- [ ] Prometheus-алерт на заполнение MinIO >80% — профилактика рецидива пункта 20
- [ ] Dependabot/Renovate для авто-мониторинга CVE в зависимостях
- [ ] Pin GitHub Actions to commit SHA (supply-chain hardening по находкам Semgrep)
- [ ] DR-учение: полный restore namespace knowledge из backup на чистый контур
