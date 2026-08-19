#!/bin/bash
set -e

echo "🚀 Installing ArgoCD..."
curl -L -o /tmp/argocd-install.yaml https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side=false -n argocd -f /tmp/argocd-install.yaml \
  || echo "⚠️  Known non-fatal: applicationsets CRD too long"

echo "⏳ Waiting for ArgoCD server..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# ВАЖНО: argocd-server по умолчанию запускается с TLS и редиректит HTTP→HTTPS.
# Для работы с ingress-nginx (HTTP бэкенд) нужен insecure-режим.
echo "🔧 Configuring argocd-server insecure mode (for nginx backend-protocol: HTTP)"
kubectl patch cm argocd-cmd-params-cm -n argocd --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd

ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "✅ ArgoCD ready. Password: $ARGO_PWD"
echo "$ARGO_PWD" > ~/.argocd-password
chmod 600 ~/.argocd-password
