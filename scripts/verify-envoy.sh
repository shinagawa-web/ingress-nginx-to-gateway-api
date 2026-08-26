#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_URL=http://localhost:8080
source "$SCRIPT_DIR/lib/tests.sh"

if [ -n "${KUBECONFIG:-}" ]; then
  echo "==> Using existing cluster (CI mode)"
else
  LIMA_INSTANCE=${LIMA_INSTANCE:-ingress-test}
  export KUBECONFIG="$HOME/.lima/$LIMA_INSTANCE/copied-from-guest/kubeconfig.yaml"
  if ! limactl list --format '{{.Name}}' | grep -q "^$LIMA_INSTANCE$"; then
    echo "==> Creating Lima k3s instance: $LIMA_INSTANCE"
    limactl start "template:k3s" --name "$LIMA_INSTANCE"
  else
    echo "==> Using existing Lima instance: $LIMA_INSTANCE"
  fi
  echo "==> Cleaning up existing resources"
  kubectl delete ingress --all 2>/dev/null || true
  kubectl delete httproute --all 2>/dev/null || true
  kubectl delete gateway --all 2>/dev/null || true
  kubectl delete securitypolicy --all 2>/dev/null || true
  kubectl delete backendtrafficpolicy --all 2>/dev/null || true
  kubectl delete envoyextensionpolicy --all 2>/dev/null || true
  kubectl delete envoypatchpolicy --all 2>/dev/null || true
  kubectl delete namespace envoy-gateway-system ingress-nginx 2>/dev/null || true
  kubectl wait --for=delete namespace/envoy-gateway-system --timeout=90s 2>/dev/null || true
fi

echo "==> Installing Gateway API CRDs"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

echo "==> Installing Envoy Gateway"
kubectl delete crd backendtlspolicies.gateway.networking.k8s.io tlsroutes.gateway.networking.k8s.io 2>/dev/null || true
kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.3.0/install.yaml \
  --force-conflicts 2>&1 || true
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "==> Enabling EnvoyPatchPolicy"
kubectl patch configmap envoy-gateway-config -n envoy-gateway-system --patch '
{
  "data": {
    "envoy-gateway.yaml": "apiVersion: gateway.envoyproxy.io/v1alpha1\nkind: EnvoyGateway\ngateway:\n  controllerName: gateway.envoyproxy.io/gatewayclass-controller\nlogging:\n  level:\n    default: info\nextensionApis:\n  enableEnvoyPatchPolicy: true\nprovider:\n  kubernetes:\n    rateLimitDeployment:\n      container:\n        image: docker.io/envoyproxy/ratelimit:60d8e81b\n      patch:\n        type: StrategicMerge\n        value:\n          spec:\n            template:\n              spec:\n                containers:\n                - imagePullPolicy: IfNotPresent\n                  name: envoy-ratelimit\n    shutdownManager:\n      image: envoyproxy/gateway:v1.3.0\n  type: Kubernetes\n"
  }
}'
kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system --timeout=2m

echo "==> Deploying sample app and auth-service"
kubectl apply -f "$SCRIPT_DIR/../app/echo.yaml"
kubectl apply -f "$SCRIPT_DIR/../app/auth-service.yaml"
kubectl wait --timeout=2m deployment/echo-v1 deployment/echo-v2 deployment/auth-service --for=condition=Available

echo "==> Applying Gateway"
kubectl apply -f "$SCRIPT_DIR/../after/gateway-envoy.yaml"
kubectl wait --timeout=3m gateway/eg --for=condition=Accepted

echo "==> Waiting for envoy proxy pod to appear and be ready"
for i in $(seq 1 36); do
  READY=$(kubectl get pod -n envoy-gateway-system \
    -l 'gateway.envoyproxy.io/owning-gateway-name=eg' \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  echo "  attempt $i/36: Ready=$READY"
  [ "$READY" = "True" ] && break
  sleep 5
done
if [ "$READY" != "True" ]; then
  echo "ERROR: envoy proxy pod did not become ready"
  kubectl get pod -n envoy-gateway-system -o wide
  exit 1
fi

echo "==> DEBUG: pods in envoy-gateway-system"
kubectl get pod -n envoy-gateway-system -o wide
echo "==> DEBUG: services in envoy-gateway-system"
kubectl get svc -n envoy-gateway-system

echo "==> Starting port-forward for Gateway"
pkill -f "port-forward.*8080" 2>/dev/null || true
sleep 2
SVC=$(kubectl get svc -n envoy-gateway-system -l 'gateway.envoyproxy.io/owning-gateway-name=eg' -o jsonpath='{.items[0].metadata.name}')
echo "==> DEBUG: SVC='$SVC'"
kubectl port-forward -n envoy-gateway-system svc/"$SVC" 8080:80 &>/tmp/pf-envoy.log &
PF_PID=$!
sleep 5
echo "==> DEBUG: port-forward pid=$PF_PID alive=$(kill -0 $PF_PID 2>&1 && echo yes || echo no)"
echo "==> DEBUG: pf-envoy.log:"
cat /tmp/pf-envoy.log || true
echo "==> DEBUG: curl probe localhost:8080"
curl --max-time 5 -v http://localhost:8080/ 2>&1 | head -20 || true

echo "==> [category-a] basic routing"
kubectl apply -f "$SCRIPT_DIR/../after/category-a/01-basic-routing.yaml"
sleep 5
test_basic_routing "$BASE_URL"

echo "==> [category-a] rewrite"
kubectl delete httproute basic-routing 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../after/category-a/02-rewrite.yaml"
sleep 5
test_rewrite "$BASE_URL"

echo "==> [category-a] canary"
kubectl apply -f "$SCRIPT_DIR/../after/category-a/03-canary.yaml"
sleep 5
test_canary "$BASE_URL"

echo "==> [category-b] auth"
kubectl delete httproute rewrite canary 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../after/category-b-envoy-gateway/04-auth.yaml"
sleep 10
test_auth "$BASE_URL" 401

echo "==> [category-b] rate-limit"
kubectl delete httproute protected 2>/dev/null || true
kubectl delete securitypolicy auth 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../after/category-b-envoy-gateway/05-rate-limit.yaml"
sleep 5
test_rate_limit "$BASE_URL"

echo "==> [category-a] response header"
kubectl delete httproute rate-limited 2>/dev/null || true
kubectl delete backendtrafficpolicy rate-limit 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../after/category-a/06-response-header.yaml"
sleep 5
test_configuration_snippet "$BASE_URL"

echo "==> [category-b] request ID"
kubectl delete httproute response-header 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../after/category-b-envoy-gateway/06-request-id.yaml"
sleep 8
test_request_id "$BASE_URL"

pkill -f "port-forward.*8080" 2>/dev/null || true
echo ""
echo "All Envoy Gateway tests passed."
