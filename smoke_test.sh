#!/usr/bin/env bash
set -uo pipefail  # NOT -e: individual test failures must not abort the script

# ---------------------------------------------------------------------------
# AGH LLM-Setup Smoke Test
# Usage: bash smoke_test.sh <PUBLIC_URL> <API_KEY> [ADMIN_TOKEN]
#   or:  PUBLIC_URL=... API_KEY=... [ADMIN_TOKEN=...] bash smoke_test.sh
# ---------------------------------------------------------------------------

PUBLIC_URL="${1:-${PUBLIC_URL:-}}"
API_KEY="${2:-${API_KEY:-}}"
ADMIN_TOKEN="${3:-${ADMIN_TOKEN:-}}"

if [ -z "$PUBLIC_URL" ] || [ -z "$API_KEY" ]; then
  echo "Usage: bash smoke_test.sh <PUBLIC_URL> <API_KEY> [ADMIN_TOKEN]" >&2
  echo "  or:  PUBLIC_URL=... API_KEY=... [ADMIN_TOKEN=...] bash smoke_test.sh" >&2
  exit 1
fi

# Strip trailing slash
PUBLIC_URL="${PUBLIC_URL%/}"

PASS=0
FAIL=0
SKIP=0

# Shared state for admin tests
MINTED_ID=""
MINTED_SECRET=""

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

run_test() {
  local name="$1"; shift
  local start end elapsed
  start=$(date +%s%3N)
  if "$@"; then
    end=$(date +%s%3N)
    elapsed=$((end - start))
    echo "  PASS [$name] ${elapsed}ms"
    PASS=$((PASS + 1))
  else
    end=$(date +%s%3N)
    elapsed=$((end - start))
    echo "  FAIL [$name] ${elapsed}ms"
    FAIL=$((FAIL + 1))
  fi
}

skip_test() {
  echo "  SKIP [$1] (no ADMIN_TOKEN)"
  SKIP=$((SKIP + 1))
}

# ---------------------------------------------------------------------------
# Helper: extract a JSON field value via python3 (no jq dependency)
# Usage: json_field <json_string> <field_name>
# ---------------------------------------------------------------------------
json_field() {
  python3 -c "
import sys, json
data = json.loads(sys.argv[1])
keys = sys.argv[2].split('.')
val = data
for k in keys:
    if isinstance(val, dict):
        val = val.get(k)
    else:
        val = None
        break
if val is None:
    sys.exit(1)
print(val)
" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Test 1: GET /health — expect 200 + body contains "status":"ok"
# ---------------------------------------------------------------------------
test_health() {
  local body
  body=$(curl -sf --max-time 15 "${PUBLIC_URL}/health") || return 1
  echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('status') == 'ok', f'status={d.get(\"status\")}'
" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# Test 2: POST /query with bearer key — expect 200 + non-empty answer field
# ---------------------------------------------------------------------------
test_query() {
  local body
  body=$(curl -sf --max-time 60 \
    -X POST "${PUBLIC_URL}/query" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"Say hi"}') || return 1
  python3 -c "
import sys, json
d = json.loads(sys.argv[1])
answer = d.get('answer', '')
assert isinstance(answer, str) and len(answer) > 0, f'answer={answer!r}'
" "$body" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# Test 3: POST /query without auth — expect 401
# ---------------------------------------------------------------------------
test_query_no_auth() {
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -X POST "${PUBLIC_URL}/query" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"Say hi"}')
  [ "$http_code" = "401" ]
}

# ---------------------------------------------------------------------------
# Test 4: GET /v1/models with bearer key — expect 200
# ---------------------------------------------------------------------------
test_v1_models() {
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    "${PUBLIC_URL}/v1/models" \
    -H "Authorization: Bearer ${API_KEY}")
  [ "$http_code" = "200" ]
}

# ---------------------------------------------------------------------------
# Test 5: POST /v1/chat/completions — expect 200 + choices array
# ---------------------------------------------------------------------------
test_v1_chat() {
  # Detect model from /health to keep the request valid
  local model body
  model=$(curl -sf --max-time 15 "${PUBLIC_URL}/health" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model','gemma-4-31B-it-GGUF'))") \
    || model="gemma-4-31B-it-GGUF"

  body=$(curl -sf --max-time 60 \
    -X POST "${PUBLIC_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}],\"stream\":false}") \
    || return 1

  python3 -c "
import sys, json
d = json.loads(sys.argv[1])
choices = d.get('choices')
assert isinstance(choices, list) and len(choices) > 0, f'choices={choices!r}'
" "$body" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# Test 6: POST /admin/keys — mint a new key (requires ADMIN_TOKEN)
# ---------------------------------------------------------------------------
test_admin_mint() {
  local body
  body=$(curl -sf --max-time 15 \
    -X POST "${PUBLIC_URL}/admin/keys" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"label":"smoke-test-key"}') || return 1

  MINTED_ID=$(python3 -c "
import sys, json
d = json.loads(sys.argv[1])
assert 'id' in d and 'secret' in d, f'missing id/secret in {d}'
print(d['id'])
" "$body" 2>/dev/null) || return 1

  MINTED_SECRET=$(python3 -c "
import sys, json
d = json.loads(sys.argv[1])
print(d['secret'])
" "$body" 2>/dev/null) || return 1

  [ -n "$MINTED_ID" ] && [ -n "$MINTED_SECRET" ]
}

# ---------------------------------------------------------------------------
# Test 7: Use the newly minted key for a /query call — expect 200
# ---------------------------------------------------------------------------
test_admin_use_new_key() {
  if [ -z "$MINTED_SECRET" ]; then
    echo "    (skipping: no minted secret available)" >&2
    return 1
  fi
  local body
  body=$(curl -sf --max-time 60 \
    -X POST "${PUBLIC_URL}/query" \
    -H "Authorization: Bearer ${MINTED_SECRET}" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"Say hi"}') || return 1
  python3 -c "
import sys, json
d = json.loads(sys.argv[1])
assert isinstance(d.get('answer'), str) and len(d['answer']) > 0
" "$body" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# Test 8: DELETE /admin/keys/{id} + verify revoked key returns 401
# ---------------------------------------------------------------------------
test_admin_revoke() {
  if [ -z "$MINTED_ID" ] || [ -z "$MINTED_SECRET" ]; then
    echo "    (skipping: no minted key to revoke)" >&2
    return 1
  fi

  # Revoke — expect 204
  local revoke_code
  revoke_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -X DELETE "${PUBLIC_URL}/admin/keys/${MINTED_ID}" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}")
  [ "$revoke_code" = "204" ] || return 1

  # Attempt to use revoked key — expect 401
  local use_code
  use_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    -X POST "${PUBLIC_URL}/query" \
    -H "Authorization: Bearer ${MINTED_SECRET}" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"Say hi"}')
  [ "$use_code" = "401" ]
}

# ---------------------------------------------------------------------------
# Test 9: Rate limit probe — 5 rapid requests; log result, never fail
# ---------------------------------------------------------------------------
test_rate_limit_probe() {
  local i hit429=0
  for i in 1 2 3 4 5; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
      -X POST "${PUBLIC_URL}/query" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"prompt":"ping"}')
    if [ "$code" = "429" ]; then
      hit429=$((hit429 + 1))
    fi
  done
  if [ "$hit429" -gt 0 ]; then
    echo "    (rate limit triggered on $hit429/5 requests — expected at low RPM tiers)"
  else
    echo "    (no rate limit triggered on 5 requests — expected at high RPM tiers)"
  fi
  return 0  # always pass
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "================================================"
echo "AGH LLM-Setup Smoke Test"
echo "URL: $PUBLIC_URL"
echo "================================================"

run_test "health"             test_health
run_test "query"              test_query
run_test "query_no_auth"      test_query_no_auth
run_test "v1_models"          test_v1_models
run_test "v1_chat"            test_v1_chat

if [ -n "$ADMIN_TOKEN" ]; then
  run_test "admin_mint"         test_admin_mint
  run_test "admin_use_new_key"  test_admin_use_new_key
  run_test "admin_revoke"       test_admin_revoke
else
  skip_test "admin_mint"
  skip_test "admin_use_new_key"
  skip_test "admin_revoke"
fi

run_test "rate_limit_probe"   test_rate_limit_probe

echo "================================================"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -eq 0 ]; then
  echo "STATUS: ALL PASS"
  exit 0
fi
echo "STATUS: FAILURES DETECTED"
exit 1
