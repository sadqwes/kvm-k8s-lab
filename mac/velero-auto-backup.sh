#!/bin/bash
# Off-site copy of the Velero bucket on the Mac + report to the cluster.
# Runs from launchd every 4 hours (~/Library/LaunchAgents/com.sadqwes.velero-auto-backup.plist).
# Install: cp mac/velero-auto-backup.sh ~/velero-auto-backup.sh
#
# 1. Cluster off -> skip quietly.
# 2. No Completed backup for 24 h -> create one with the schedule's settings.
# 3. Every run: mirror the whole bucket (backups + kopia) to ~/velero-backups.
# 4. Push the result to Pushgateway -> Grafana dashboard "Backups: Velero, MinIO, Mac".
# macOS /bin/bash is 3.2: no bash 4 features here.

set -u

LOG_FILE="$HOME/velero-auto-backup.log"
exec >> "$LOG_FILE" 2>&1

BACKUP_DIR="$HOME/velero-backups"
SCHEDULE="periodic-backup"
MC_ALIAS="lab-minio"
MINIO_PORT=19000   # not 9000/9091, so a manual port-forward in another terminal doesn't clash
PGW_PORT=19091
MAX_AGE_HOURS=24

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

PF_PIDS=""
cleanup() { for p in $PF_PIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# kubectl port-forward in the background, wait until the local port answers
port_forward() {  # namespace service local_port remote_port
  kubectl -n "$1" port-forward "svc/$2" "$3:$4" >/dev/null 2>&1 &
  PF_PIDS="$PF_PIDS $!"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    nc -z 127.0.0.1 "$3" 2>/dev/null && return 0
    sleep 1
  done
  log "❌ port-forward $1/$2 не поднялся"
  return 1
}

echo "=== $(date) ==="

# 1. Is the cluster there? /readyz with a timeout fails fast when the VMs are off.
if ! kubectl get --raw /readyz --request-timeout=10s >/dev/null 2>&1; then
  log "Кластер недоступен, пропускаем"
  exit 0
fi

# 2. Age of the last Completed backup
if ! BACKUPS_JSON=$(kubectl -n velero get backups.velero.io -o json --request-timeout=30s); then
  log "❌ Не удалось получить список бэкапов"
  exit 1
fi
LAST_TS=$(echo "$BACKUPS_JSON" | jq -r '[.items[] | select(.status.phase == "Completed")]
  | sort_by(.status.startTimestamp) | last | .status.startTimestamp // empty')

if [ -z "$LAST_TS" ]; then
  AGE_HOURS=9999
  log "Completed-бэкапов нет"
else
  LAST_SEC=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS" "+%s" 2>/dev/null || echo 0)
  AGE_HOURS=$(( ($(date +%s) - LAST_SEC) / 3600 ))
  log "Последний Completed-бэкап: $LAST_TS ($AGE_HOURS ч назад)"
fi

if [ "$AGE_HOURS" -ge "$MAX_AGE_HOURS" ]; then
  BACKUP_NAME="auto-$(date +%Y%m%d-%H%M%S)"
  log "Создаём бэкап $BACKUP_NAME (настройки расписания $SCHEDULE)..."
  # Same as `velero backup create --from-schedule`, but with kubectl: a Backup object
  # built from the schedule's template. The velero CLI is not used on purpose — under
  # launchd macOS Local Network privacy blocks it (no route to host), kubectl is allowed.
  if kubectl -n velero get schedules.velero.io "$SCHEDULE" -o json \
      | jq --arg n "$BACKUP_NAME" --arg s "$SCHEDULE" '{
          apiVersion: "velero.io/v1", kind: "Backup",
          metadata: {name: $n, namespace: "velero", labels: {"velero.io/schedule-name": $s}},
          spec: .spec.template}' \
      | kubectl create -f - >/dev/null; then
    PHASE=""
    for _ in $(seq 1 120); do   # up to 30 min
      PHASE=$(kubectl -n velero get backups.velero.io "$BACKUP_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
      case "$PHASE" in Completed|PartiallyFailed|Failed|FailedValidation) break ;; esac
      sleep 15
    done
    if [ "$PHASE" = "Completed" ]; then
      log "✅ Бэкап $BACKUP_NAME: Completed"
    else
      log "❌ Бэкап $BACKUP_NAME: ${PHASE:-нет статуса} — смотри дашборд, таблица Failed volumes"
    fi
  else
    log "❌ Не удалось создать бэкап $BACKUP_NAME"
  fi
fi

# 3. Mirror the WHOLE bucket every run (backups/ holds only metadata, data is in kopia/).
#    --overwrite: kopia.repository/kopia.blobcfg change and must be updated.
#    No --remove on purpose: if the bucket is ever wiped, the Mac copy survives.
MIRROR_OK=0
if port_forward minio-system minio "$MINIO_PORT" 9000; then
  PASS=$(kubectl -n minio-system get secret minio-credentials -o jsonpath='{.data.rootPassword}' | base64 -d)
  mc alias set "$MC_ALIAS" "http://127.0.0.1:$MINIO_PORT" admin "$PASS" >/dev/null
  if mc mirror --overwrite --quiet "$MC_ALIAS/velero-backups/" "$BACKUP_DIR/" >/dev/null; then
    MIRROR_OK=1
    log "✅ Бакет скопирован в $BACKUP_DIR ($(du -sh "$BACKUP_DIR" | cut -f1))"
  else
    log "❌ mc mirror завершился с ошибкой"
  fi
fi

# 4. Report to Pushgateway. PUT replaces the whole group, so backups that
#    disappeared from the Mac copy disappear from the dashboard too.
if ! port_forward monitoring pushgateway "$PGW_PORT" 9091; then
  exit 1
fi
PGW="http://127.0.0.1:$PGW_PORT/metrics/job"
NOW=$(date +%s)

# every run: did it work?
printf 'velero_offsite_last_run_timestamp_seconds %s\nvelero_offsite_last_run_success %s\n' "$NOW" "$MIRROR_OK" \
  | curl -s --fail -X PUT --data-binary @- "$PGW/velero_offsite_run" \
  || log "❌ Не удалось отправить статус в Pushgateway"

# only after a successful mirror: what is in the copy
if [ "$MIRROR_OK" = "1" ]; then
  SIZE=$(( $(du -sk "$BACKUP_DIR" | cut -f1) * 1024 ))
  {
    echo "velero_offsite_last_mirror_timestamp_seconds $NOW"
    echo "velero_offsite_size_bytes $SIZE"
    ls -1 "$BACKUP_DIR/backups" 2>/dev/null | while read -r b; do
      echo "velero_offsite_backup_info{backup=\"$b\"} 1"
    done
  } | curl -s --fail -X PUT --data-binary @- "$PGW/velero_offsite" \
    && log "✅ Отчёт отправлен в Pushgateway" \
    || log "❌ Не удалось отправить отчёт в Pushgateway"
fi
