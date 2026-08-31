#!/bin/bash
set -e

echo "🚀 Installing ArgoCD..."

# Фиксируем версию ArgoCD (избегаем нестабильности с "stable" тегом)
ARGOCD_VERSION="v3.5.1"

# Создаём namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# ApplicationSet CRD отдельно (server-side apply обходит лимит 256 KiB аннотаций)
echo "📦 Installing ApplicationSet CRD..."
kubectl apply --server-side -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/crds/applicationset-crd.yaml"
kubectl wait --for=condition=established --timeout=60s crd/applicationsets.argoproj.io

# ArgoCD install (без CRD, они уже установлены)
echo "📦 Installing ArgoCD components..."
curl -L -o /tmp/argocd-install.yaml "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl apply -n argocd -f /tmp/argocd-install.yaml

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
