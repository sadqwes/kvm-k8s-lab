#!/usr/bin/env bash
# Доступ кластера к приватному образу questlog на ghcr.io → SealedSecret ghcr-pull в gitops/platform/questlog/.
#
# Нужен GitHub-токен (classic) только с правом read:packages:
#   GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token,
#   галочка только read:packages, срок — например 1 год (поставь напоминание продлить).
# Скрипт спрашивает токен скрыто, сразу запечатывает и нигде его не сохраняет и не печатает.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v kubeseal >/dev/null || { echo "нужен kubeseal: brew install kubeseal"; exit 1; }

NS=questlog
OUT=gitops/platform/questlog/ghcr-pull-sealed.yaml
read -r -p "GitHub username [sadqwes]: " GH_USER
GH_USER=${GH_USER:-sadqwes}
read -r -s -p "Токен read:packages (ввод скрыт): " GH_TOKEN
echo
[[ -n $GH_TOKEN ]] || { echo "токен пустой"; exit 1; }

# проверяем токен до того, как запечатать: GHCR должен выдать токен на pull
if ! curl -fsS -u "$GH_USER:$GH_TOKEN" "https://ghcr.io/token?scope=repository:$GH_USER/questlog:pull" >/dev/null; then
  echo "GHCR не принял токен: проверь, что у него есть read:packages"; exit 1
fi

kubectl -n "$NS" create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username="$GH_USER" --docker-password="$GH_TOKEN" \
  --dry-run=client -o yaml | kubeseal --format yaml > "$OUT"
unset GH_TOKEN
echo "готово: $OUT — закоммить и запушь, ArgoCD создаст Secret, и под стянет образ"
