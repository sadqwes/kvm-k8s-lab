#!/bin/bash
set -e
cd "$(dirname "$0")/.."

echo "🔧 1/5 ArgoCD"
./bootstrap/install-argocd.sh

echo "🔧 2/5 MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
kubectl wait --for=condition=available --timeout=300s deployment/controller -n metallb-system

echo "🔧 3/5 ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/baremetal/deploy.yaml
kubectl wait --for=condition=available --timeout=300s deployment/ingress-nginx-controller -n ingress-nginx
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"LoadBalancer"}}'

echo "🔧 4/5 SealedSecrets"
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml
kubectl wait --for=condition=available --timeout=300s deployment/sealed-secrets-controller -n kube-system

kubectl patch deploy ingress-nginx-controller -n ingress-nginx --type json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-ssl-certificate=ingress-nginx/tls-wildcard"}]' || true

echo "🔧 5/5 Root Application"
kubectl apply -f bootstrap/root-app.yaml

echo ""
echo "✅ Bootstrap done! Дальше работает GitOps:"
echo "   kubectl get applications -n argocd"
