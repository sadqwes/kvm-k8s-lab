#!/usr/bin/env bash
# Секреты jobhunter → SealedSecret в gitops/platform/jobhunter/. Запускать один раз, перед первым деплоем.
#
# - jobhunter-auth: пароль для входа — тот же, что у questlog (копируется только bcrypt-хеш из кластера),
#   и новый API-токен для Claude. Токен сохраняется в ~/.zshrc как JOBHUNTER_TOKEN и нигде не печатается.
# - jobhunter-postgres: случайный пароль базы.
#
# ⚠️ Пароль базы Postgres применяет только при первой инициализации тома. Если база уже создана,
#    перезапуск скрипта с --force сломает вход приложения в базу — сначала удали PVC (и данные).
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=gitops/platform/jobhunter
NS=jobhunter

if [[ -e $DIR/jobhunter-auth-sealed.yaml && ${1:-} != --force ]]; then
  echo "Секреты уже запечатаны ($DIR/*-sealed.yaml). Перевыпустить: $0 --force (см. предупреждение в начале скрипта)"
  exit 1
fi
command -v kubeseal >/dev/null || { echo "нужен kubeseal: brew install kubeseal"; exit 1; }

HASH=$(kubectl -n questlog get secret questlog-auth -o jsonpath='{.data.password-hash}' | base64 -d)
[[ $HASH == \$2* ]] || { echo "не удалось прочитать bcrypt-хеш из questlog-auth"; exit 1; }
TOKEN=$(openssl rand -hex 32)
PGPASS=$(openssl rand -hex 24)

kubectl -n "$NS" create secret generic jobhunter-auth \
  --from-literal=password-hash="$HASH" --from-literal=api-token="$TOKEN" \
  --dry-run=client -o yaml | kubeseal --format yaml > "$DIR/jobhunter-auth-sealed.yaml"
kubectl -n "$NS" create secret generic jobhunter-postgres \
  --from-literal=password="$PGPASS" \
  --dry-run=client -o yaml | kubeseal --format yaml > "$DIR/jobhunter-postgres-sealed.yaml"
# Тот же токен — questlog: он читает сводку jobhunter для карточки «Сегодня»
kubectl -n questlog create secret generic questlog-jobhunter --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | kubeseal --format yaml > gitops/platform/questlog/questlog-jobhunter-sealed.yaml
echo "запечатаны jobhunter-auth, jobhunter-postgres и questlog-jobhunter"

# Токен — в ~/.zshrc, как QUESTLOG_TOKEN: Claude читает его через `zsh -ic`, не видя значения
ZSHRC=$HOME/.zshrc
if grep -q '^export JOBHUNTER_TOKEN=' "$ZSHRC" 2>/dev/null; then
  sed -i '' "s|^export JOBHUNTER_TOKEN=.*|export JOBHUNTER_TOKEN=$TOKEN|" "$ZSHRC"
else
  printf '\n# jobhunter (API для Claude)\nexport JOBHUNTER_URL=https://jobhunter.local\nexport JOBHUNTER_TOKEN=%s\n' "$TOKEN" >> "$ZSHRC"
fi
echo "JOBHUNTER_TOKEN записан в ~/.zshrc (значение не печатается)"
echo
echo "Дальше: git add $DIR gitops/platform/questlog && git commit && git push"
