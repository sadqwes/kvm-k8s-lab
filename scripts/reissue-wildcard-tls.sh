#!/usr/bin/env bash
# Перевыпуск mkcert-сертификата для *.local сервисов лабы и перезапечатывание его
# в SealedSecret tls-wildcard во всех namespace, где он нужен.
#
# Когда запускать: добавился новый сервис на *.local или сертификат скоро истечёт.
# Приватный ключ живёт только во временной папке и удаляется при выходе.
# После запуска: git add gitops/platform/tls && git commit && git push — дальше ArgoCD.
set -euo pipefail
cd "$(dirname "$0")/.."

HOSTS=(
  argocd.local grafana.local longhorn.local
  questlog.local
  localhost 127.0.0.1 ::1
)
# ingress-nginx — сертификат по умолчанию (--default-ssl-certificate), остальные — для ingress с secretName
NAMESPACES=(ingress-nginx argocd monitoring longhorn-system)

command -v mkcert >/dev/null || { echo "нужен mkcert: brew install mkcert"; exit 1; }
command -v kubeseal >/dev/null || { echo "нужен kubeseal: brew install kubeseal"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkcert -cert-file "$TMP/tls.crt" -key-file "$TMP/tls.key" "${HOSTS[@]}"

for ns in "${NAMESPACES[@]}"; do
  kubectl -n "$ns" create secret tls tls-wildcard \
    --cert="$TMP/tls.crt" --key="$TMP/tls.key" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > "gitops/platform/tls/tls-$ns-sealed.yaml"
  echo "запечатан tls-wildcard для $ns"
done

echo
echo "Имена в новом сертификате:"
openssl x509 -in "$TMP/tls.crt" -noout -ext subjectAltName | tail -n +2
echo
echo "Дальше: git add gitops/platform/tls && git commit -m 'chore(tls): reissue wildcard cert' && git push"
