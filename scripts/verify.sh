#!/usr/bin/env bash
# verify.sh — proves Envoy sidecar RBAC blocks DELETE end-to-end.
# Works against docker-compose locally, or K8s port-forward.
set -u

HOST="${HOST:-http://localhost:8080}"
[[ "${1:-}" == "--k8s" ]] && HOST="http://localhost:8081"
SUBJECT="envoy-poc-$(date +%s)"
SCHEMA='{"schema":"{\"type\":\"record\",\"name\":\"T\",\"fields\":[{\"name\":\"f\",\"type\":\"string\"}]}"}'

pass=0; fail=0
say()  { printf "\n\033[1;36m== %s ==\033[0m\n" "$*"; }
ok()   { printf "  \033[32mPASS\033[0m %s\n" "$*"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$*"; fail=$((fail+1)); }

say "Target: $HOST  |  Subject: $SUBJECT"

say "Test 1: GET /subjects → expect 200"
code=$(curl -s -o /tmp/o -w "%{http_code}" "$HOST/subjects")
[[ "$code" == "200" ]] && ok "GET $code" || bad "GET $code"

say "Test 2: POST schema → expect 200"
code=$(curl -s -o /tmp/o -w "%{http_code}" -X POST \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data "$SCHEMA" "$HOST/subjects/$SUBJECT/versions")
[[ "$code" == "200" ]] && ok "POST $code, body: $(cat /tmp/o)" || bad "POST $code"

say "Test 3: DELETE subject → expect 403 + x-delete-blocked header"
code=$(curl -s -o /tmp/o -w "%{http_code}" -D /tmp/h -X DELETE "$HOST/subjects/$SUBJECT")
hdr=$(grep -i '^x-delete-blocked' /tmp/h | tr -d '\r')
echo "    status: $code, header: $hdr"
echo "    body:   $(cat /tmp/o)"
if [[ "$code" == "403" ]] && [[ -n "$hdr" ]]; then
  ok "DELETE blocked (403 + proof header present)"
else
  bad "DELETE not blocked as expected (code=$code hdr=$hdr)"
fi

say "Test 4: DELETE version → expect 403"
code=$(curl -s -o /tmp/o -w "%{http_code}" -X DELETE "$HOST/subjects/$SUBJECT/versions/1")
[[ "$code" == "403" ]] && ok "DELETE version $code" || bad "DELETE version $code"

say "Test 5: Subject still exists (DELETE didn't leak through) → expect 200"
code=$(curl -s -o /tmp/o -w "%{http_code}" "$HOST/subjects/$SUBJECT/versions")
[[ "$code" == "200" ]] && ok "GET versions $code: $(cat /tmp/o)" || bad "GET versions $code"

say "Test 6: Envoy RBAC metrics (admin :9901)"
if curl -s --max-time 2 "http://localhost:9901/stats?filter=rbac" > /tmp/stats 2>/dev/null; then
  denied=$(grep -oE 'rbac\.denied: [0-9]+' /tmp/stats | awk '{print $2}' | head -1)
  allowed=$(grep -oE 'rbac\.allowed: [0-9]+' /tmp/stats | awk '{print $2}' | head -1)
  echo "    rbac.allowed=$allowed  rbac.denied=$denied"
  [[ -n "$denied" && "$denied" -ge 2 ]] && ok "rbac.denied=$denied (>=2 expected)" \
    || bad "rbac.denied=$denied (expected >=2)"
else
  echo "    (admin endpoint not reachable — skip on K8s unless port-forwarded)"
fi

printf "\n\033[1m== Summary: %d passed, %d failed ==\033[0m\n" "$pass" "$fail"
[[ "$fail" == "0" ]] && exit 0 || exit 1
