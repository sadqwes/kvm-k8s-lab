#!/usr/bin/env bash
# Секреты english-polygon → SealedSecret в gitops/platform/english-polygon/. Запускать один раз, перед первым деплоем.
#
# - english-polygon-auth: пароль для входа — тот же, что у questlog (копируется только bcrypt-хеш из кластера),
#   и новый API-токен для Claude. Токен сохраняется в ~/.zshrc как ENGLISH_TOKEN и нигде не печатается.
# - english-polygon-postgres: случайный пароль базы.
# - ghcr-pull: доступ к приватному образу, копия Secret из namespace jobhunter.
#
# ⚠️ Пароль базы Postgres применяет только при первой инициализации тома. Если база уже создана,
#    перезапуск скрипта с --force сломает вход приложения в базу — сначала удали PVC (и данные).
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=gitops/platform/english-polygon
NS=english-polygon

if [[ -e $DIR/english-polygon-auth-sealed.yaml && ${1:-} != --force ]]; then
  echo "Секреты уже запечатаны ($DIR/*-sealed.yaml). Перевыпустить: $0 --force (см. предупреждение в начале скрипта)"
  exit 1
fi
command -v kubeseal >/dev/null || { echo "нужен kubeseal: brew install kubeseal"; exit 1; }

HASH=$(kubectl -n questlog get secret questlog-auth -o jsonpath='{.data.password-hash}' | base64 -d)
[[ $HASH == \$2* ]] || { echo "не удалось прочитать bcrypt-хеш из questlog-auth"; exit 1; }
TOKEN=$(openssl rand -hex 32)
PGPASS=$(openssl rand -hex 24)
PULL=$(kubectl -n jobhunter get secret ghcr-pull -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
[[ -n $PULL ]] || { echo "не удалось прочитать ghcr-pull из jobhunter"; exit 1; }

kubectl -n "$NS" create secret generic english-polygon-auth \
  --from-literal=password-hash="$HASH" --from-literal=api-token="$TOKEN" \
  --dry-run=client -o yaml | kubeseal --format yaml > "$DIR/english-polygon-auth-sealed.yaml"
kubectl -n "$NS" create secret generic english-polygon-postgres \
  --from-literal=password="$PGPASS" \
  --dry-run=client -o yaml | kubeseal --format yaml > "$DIR/english-polygon-postgres-sealed.yaml"
kubectl -n "$NS" create secret generic ghcr-pull --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$PULL" \
  --dry-run=client -o yaml | kubeseal --format yaml > "$DIR/ghcr-pull-sealed.yaml"
echo "запечатаны english-polygon-auth, english-polygon-postgres и ghcr-pull"

ZSHRC=$HOME/.zshrc
if grep -q '^export ENGLISH_TOKEN=' "$ZSHRC" 2>/dev/null; then
  sed -i '' "s|^export ENGLISH_TOKEN=.*|export ENGLISH_TOKEN=$TOKEN|" "$ZSHRC"
else
  printf '\n# english-polygon (API для Claude)\nexport ENGLISH_TOKEN=%s\n' "$TOKEN" >> "$ZSHRC"
fi
echo "ENGLISH_TOKEN записан в ~/.zshrc (значение не печатается)"
