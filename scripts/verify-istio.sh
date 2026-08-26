#!/usr/bin/env bash
set -euo pipefail

LIMA_INSTANCE=${LIMA_INSTANCE:-ingress-test}
BASE_URL=http://localhost:8081

export KUBECONFIG="$HOME/.lima/$LIMA_INSTANCE/copied-from-guest/kubeconfig.yaml"
source "$(dirname "$0")/lib/tests.sh"

if ! limactl list --format '{{.Name}}' | grep -q "^$LIMA_INSTANCE$"; then
  echo "==> Creating Lima k3s instance: $LIMA_INSTANCE"
  limactl start "template:k3s" --name "$LIMA_INSTANCE"
fi

echo "==> Cleaning up existing resources"
kubectl delete ingress --all 2>/dev/null || true
kubectl delete httproute --all 2>/dev/null || true
kubectl delete gateway --all 2>/dev/null || true
kubectl delete authorizationpolicy --all -A 2>/dev/null || true
kubectl delete envoyfilter --all -A 2>/dev/null || true
kubectl delete securitypolicy --all 2>/dev/null || true
kubectl delete backendtrafficpolicy --all 2>/dev/null || true
kubectl delete envoyextensionpolicy --all 2>/dev/null || true
kubectl delete envoypatchpolicy --all 2>/dev/null || true
kubectl delete namespace envoy-gateway-system ingress-nginx 2>/dev/null || true
kubectl wait --for=delete namespace/envoy-gateway-system --timeout=90s 2>/dev/null || true
kubectl wait --for=delete namespace/ingress-nginx --timeout=60s 2>/dev/null || true

echo "==> Installing Gateway API CRDs"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

if kubectl get namespace istio-system &>/dev/null; then
  echo "==> Istio already installed"
else
  echo "==> Installing Istio (minimal profile)"
  if ! command -v istioctl &>/dev/null; then
    if [ ! -d "$HOME/istio-1.24.0" ]; then
      (cd "$HOME" && curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=1.24.0 sh -)
    fi
    export PATH="$HOME/istio-1.24.0/bin:$PATH"
  fi
  istioctl install --set profile=minimal -y
  kubectl wait --timeout=5m -n istio-system deployment/istiod --for=condition=Available
fi

echo "==> Deploying sample app and auth-service (with sidecar injection)"
kubectl label namespace default istio-injection=enabled --overwrite
kubectl rollout restart deployment/echo-v1 deployment/echo-v2 deployment/auth-service 2>/dev/null || true
kubectl apply -f "$(dirname "$0")/../app/echo.yaml"
kubectl apply -f "$(dirname "$0")/../app/auth-service.yaml"
kubectl wait --timeout=3m deployment/echo-v1 deployment/echo-v2 deployment/auth-service --for=condition=Available

echo "==> Applying Istio Gateway"
kubectl apply -f "$(dirname "$0")/../after/gateway-istio.yaml"
kubectl wait --timeout=3m gateway/istio-gw --for=condition=Accepted

echo "==> Starting port-forward for Istio Gateway"
pkill -f "port-forward.*8081" 2>/dev/null || true
pkill -f "port-forward.*8080" 2>/dev/null || true
pkill -f "port-forward.*8082" 2>/dev/null || true
sleep 2
GW_SVC=$(kubectl get svc -n default -l "gateway.networking.k8s.io/gateway-name=istio-gw" -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward svc/"$GW_SVC" 8081:80 &>/tmp/pf-istio.log &
sleep 5

echo "==> [category-a] canary"
CANARY=$(sed 's/name: eg/name: istio-gw/' "$(dirname "$0")/../after/category-a/03-canary.yaml")
echo "$CANARY" | kubectl apply -f -
sleep 5
test_canary "$BASE_URL"

echo "==> [category-b] auth"
kubectl delete httproute canary 2>/dev/null || true
kubectl apply -f "$(dirname "$0")/../after/category-b-istio/04-auth.yaml"
sleep 20
test_auth "$BASE_URL" 403

echo "==> [category-a] response header"
kubectl delete httproute protected 2>/dev/null || true
kubectl delete authorizationpolicy auth 2>/dev/null || true
MANIFEST=$(sed 's/name: eg/name: istio-gw/' "$(dirname "$0")/../after/category-a/06-response-header.yaml")
echo "$MANIFEST" | kubectl apply -f -
sleep 5
test_configuration_snippet "$BASE_URL"

echo "==> [category-b] request ID"
kubectl delete httproute response-header 2>/dev/null || true
kubectl apply -f "$(dirname "$0")/../after/category-b-istio/06-request-id.yaml"
sleep 8
test_request_id "$BASE_URL"

pkill -f "port-forward.*8081" 2>/dev/null || true

echo ""
echo "All Istio tests passed."
echo ""
echo "Lima instance '$LIMA_INSTANCE' is still running. To clean up:"
echo "  limactl stop $LIMA_INSTANCE && limactl delete $LIMA_INSTANCE"
