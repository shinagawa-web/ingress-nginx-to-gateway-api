#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_URL=http://localhost:8082
source "$SCRIPT_DIR/lib/tests.sh"

if [ -n "${KUBECONFIG:-}" ]; then
  echo "==> Using existing cluster (CI mode)"
  NGINX_DEPLOY_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml"
else
  LIMA_INSTANCE=${LIMA_INSTANCE:-ingress-test}
  export KUBECONFIG="$HOME/.lima/$LIMA_INSTANCE/copied-from-guest/kubeconfig.yaml"
  if ! limactl list --format '{{.Name}}' | grep -q "^$LIMA_INSTANCE$"; then
    echo "==> Creating Lima k3s instance: $LIMA_INSTANCE"
    limactl start "template:k3s" --name "$LIMA_INSTANCE"
  else
    echo "==> Using existing Lima instance: $LIMA_INSTANCE"
  fi
  NGINX_DEPLOY_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml"
fi

echo "==> Installing ingress-nginx"
kubectl apply -f "$NGINX_DEPLOY_URL"
kubectl wait --timeout=5m -n ingress-nginx deployment/ingress-nginx-controller --for=condition=Available
kubectl wait --timeout=60s -n ingress-nginx job/ingress-nginx-admission-create job/ingress-nginx-admission-patch --for=condition=Complete
kubectl wait --timeout=60s -n ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller
kubectl patch configmap ingress-nginx-controller -n ingress-nginx \
  --patch '{"data": {"limit-req-status-code": "429", "annotations-risk-level": "Critical", "allow-snippet-annotations": "true"}}'
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type json \
  -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--enable-annotation-validation=false"}]'
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=3m

echo "==> DEBUG: controller args"
kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
echo ""
echo "==> DEBUG: ConfigMap data"
kubectl get configmap ingress-nginx-controller -n ingress-nginx -o jsonpath='{.data}' | python3 -m json.tool 2>/dev/null || kubectl get configmap ingress-nginx-controller -n ingress-nginx -o jsonpath='{.data}'
echo ""
echo "==> DEBUG: ValidatingWebhookConfiguration"
kubectl get validatingwebhookconfiguration ingress-nginx-admission -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null || true
echo ""

if [ -z "${KUBECONFIG:-}" ]; then
  echo "==> Starting port-forward"
  pkill -f "port-forward.*8082" 2>/dev/null || true
  sleep 1
  kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8082:80 &>/tmp/pf-ingress.log &
  PF_PID=$!
  sleep 5
else
  echo "==> Skipping port-forward (kind extraPortMapping handles 8082)"
  PF_PID=""
  sleep 2
fi

echo "==> Deploying sample app and auth-service"
kubectl apply -f "$SCRIPT_DIR/../app/echo.yaml"
kubectl apply -f "$SCRIPT_DIR/../app/auth-service.yaml"
kubectl wait --timeout=2m deployment/echo-v1 deployment/echo-v2 deployment/auth-service --for=condition=Available

echo "==> [before] basic routing"
kubectl apply -f "$SCRIPT_DIR/../before/01-basic-routing.yaml"
sleep 5
test_basic_routing "$BASE_URL"

echo "==> [before] rewrite"
kubectl delete ingress basic-routing 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../before/02-rewrite.yaml"
sleep 5
test_rewrite "$BASE_URL"

echo "==> [before] canary"
kubectl apply -f "$SCRIPT_DIR/../before/03-canary.yaml"
sleep 5
test_canary "$BASE_URL"

echo "==> [before] auth"
kubectl delete ingress canary-primary canary 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../before/04-auth.yaml"
sleep 5
test_auth "$BASE_URL" 401

echo "==> [before] rate-limit"
kubectl delete ingress auth 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../before/05-rate-limit.yaml"
sleep 5
test_rate_limit "$BASE_URL"

echo "==> [before] configuration-snippet"
kubectl delete ingress rate-limit 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/../before/06-configuration-snippet.yaml"
sleep 5
test_configuration_snippet "$BASE_URL"
test_request_id "$BASE_URL"

[ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
echo ""
echo "All ingress-nginx tests passed."
