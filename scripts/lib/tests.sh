#!/usr/bin/env bash

# 引数: BASE_URL (例: http://localhost:8080)
#       AUTH_DENY_CODE (認証なしで弾かれるときの期待ステータス: 401 or 403)

test_basic_routing() {
  local base_url=$1
  echo "==> Testing basic routing: GET / -> v1"
  RESP=$(curl -sf -H "Host: app.example.com" "$base_url/")
  echo "Response: $RESP"
  [[ "$RESP" == *"v1"* ]] || { echo "FAIL: basic routing"; return 1; }
  echo "PASS: basic routing"
}

test_rewrite() {
  local base_url=$1
  echo "==> Testing rewrite: GET /api/hello -> v1"
  RESP=$(curl -sf -H "Host: app.example.com" "$base_url/api/hello")
  echo "Response: $RESP"
  [[ "$RESP" == *"v1"* ]] || { echo "FAIL: rewrite"; return 1; }
  echo "PASS: rewrite"
}

test_canary() {
  local base_url=$1
  echo "==> Testing canary: 20 requests, expect v2 to appear"
  local got_v1=0 got_v2=0
  for i in $(seq 1 20); do
    R=$(curl -sf -H "Host: app.example.com" "$base_url/")
    [[ "$R" == *"v1"* ]] && got_v1=$((got_v1+1))
    [[ "$R" == *"v2"* ]] && got_v2=$((got_v2+1))
  done
  echo "v1: $got_v1, v2: $got_v2"
  [[ $got_v2 -gt 0 ]] || { echo "FAIL: canary never hit v2"; return 1; }
  echo "PASS: canary"
}

test_auth() {
  local base_url=$1
  local deny_code=${2:-401}
  echo "==> Testing auth: no token -> $deny_code"
  CODE=$(curl -so /dev/null -w "%{http_code}" -H "Host: app.example.com" "$base_url/protected")
  echo "HTTP status: $CODE"
  [[ "$CODE" == "$deny_code" ]] || { echo "FAIL: expected $deny_code without token, got $CODE"; return 1; }
  echo "PASS: auth (no token blocked)"

  echo "==> Testing auth: valid token -> v1"
  RESP=$(curl -sf -H "Host: app.example.com" -H "Authorization: Bearer valid-token" "$base_url/protected")
  echo "Response: $RESP"
  [[ "$RESP" == *"v1"* ]] || { echo "FAIL: expected v1 with valid token"; return 1; }
  echo "PASS: auth (valid token reached echo-v1)"
}

test_rate_limit() {
  local base_url=$1
  echo "==> Testing rate-limit: 10 parallel requests, expect 429"
  local tmpdir
  tmpdir=$(mktemp -d)
  for i in $(seq 1 10); do
    curl -so /dev/null -w "%{http_code}" -H "Host: app.example.com" "$base_url/" > "$tmpdir/$i" &
  done
  wait
  local got_429=0
  for f in "$tmpdir"/*; do
    [[ "$(cat "$f")" == "429" ]] && got_429=$((got_429+1))
  done
  rm -rf "$tmpdir"
  echo "429 responses: $got_429"
  [[ $got_429 -gt 0 ]] || { echo "FAIL: rate-limit not triggered"; return 1; }
  echo "PASS: rate-limit"
}

test_request_id() {
  local base_url=$1
  echo "==> Testing request ID: X-Request-ID present in response"
  HEADERS=$(curl -sI -H "Host: app.example.com" "$base_url/")
  echo "$HEADERS"
  echo "$HEADERS" | grep -i "X-Request-ID:" || { echo "FAIL: X-Request-ID not found"; return 1; }
  echo "PASS: request ID header present"
}

test_configuration_snippet() {
  local base_url=$1
  echo "==> Testing configuration-snippet: X-Custom-Header present"
  HEADERS=$(curl -sI -H "Host: app.example.com" "$base_url/")
  echo "$HEADERS"
  echo "$HEADERS" | grep -i "X-Custom-Header: my-value" || { echo "FAIL: X-Custom-Header not found"; return 1; }
  echo "PASS: configuration-snippet"
}
