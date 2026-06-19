#!/usr/bin/env bash
# 07-e2e-tests.sh
# Comprehensive E2E test suite for Foundry Local inference endpoint.
# Tests: basic completion, system prompts, multi-turn, temperature, max tokens,
#        model listing, auth validation, error handling.
#
# Prerequisites:
#   - Model deployed and Ready (04-deploy-model.sh)
#   - OR: run after 05-validate-inference.sh confirms basic connectivity

set -euo pipefail
source "$(dirname "$0")/../env.sh"

echo "========================================="
echo "  FOUNDRY LOCAL E2E TEST SUITE"
echo "  Namespace:  ${NAMESPACE}"
echo "  Model:      ${MODEL_NAME}"
echo "  Date:       $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================="
echo ""

# Extract API key
API_KEY=$(kubectl get secret "inference-operator-api-key" -n "$NAMESPACE" \
  -o jsonpath='{.data.apiKey}' 2>/dev/null | base64 -d)

if [[ -z "$API_KEY" ]]; then
  echo "❌ Could not extract API key"
  exit 1
fi

# Start port-forward
SVC_NAME="${EXTENSION_NAME}-inference-operator-api"
LOCAL_PORT=8080

pkill -f "port-forward.*${LOCAL_PORT}:8080" 2>/dev/null || true
sleep 1

kubectl port-forward "svc/$SVC_NAME" "$LOCAL_PORT:8080" -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() { kill $PF_PID 2>/dev/null || true; }
trap cleanup EXIT

if ! kill -0 $PF_PID 2>/dev/null; then
  echo "❌ Port-forward failed"
  exit 1
fi

BASE_URL="http://localhost:${LOCAL_PORT}"
PASSED=0
FAILED=0

# Test helper
run_test() {
  local test_name="$1"
  local endpoint="$2"
  local method="$3"
  local body="$4"
  local validate_pattern="$5"
  local expect_failure="${6:-false}"

  local response http_code
  local start_time=$(date +%s%N)

  if [[ "$method" == "GET" ]]; then
    response=$(curl -s -w "\n%{http_code}" "${BASE_URL}${endpoint}" \
      -H "Authorization: Bearer ${API_KEY}" 2>/dev/null)
  else
    response=$(curl -s -w "\n%{http_code}" "${BASE_URL}${endpoint}" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$body" 2>/dev/null)
  fi

  http_code=$(echo "$response" | tail -1)
  response=$(echo "$response" | sed '$d')
  local end_time=$(date +%s%N)
  local duration_ms=$(( (end_time - start_time) / 1000000 ))
  local duration
  duration=$(printf "%d.%02d" $((duration_ms / 1000)) $(((duration_ms % 1000) / 10)))

  local status="PASS"
  if [[ "$expect_failure" == "true" ]]; then
    if [[ "$http_code" =~ ^(401|400|422|403)$ ]]; then
      status="PASS"
    else
      status="FAIL"
    fi
  else
    if [[ "$http_code" == "200" ]] && echo "$response" | grep -q "$validate_pattern"; then
      status="PASS"
    else
      status="FAIL"
    fi
  fi

  if [[ "$status" == "PASS" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi

  printf "  %-4s | %-45s | %6ss | HTTP %s\n" "$status" "$test_name" "$duration" "$http_code"

  # Show response content for chat tests
  if [[ "$status" == "PASS" && "$expect_failure" != "true" && "$endpoint" == *"chat/completions"* ]]; then
    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null | head -1 | cut -c1-120)
    [[ -n "$content" ]] && printf "         → %s\n" "$content"
  elif [[ "$status" == "FAIL" ]]; then
    local err
    err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null | cut -c1-120)
    [[ -n "$err" ]] && printf "         ✗ %s\n" "$err"
    [[ -z "$err" ]] && printf "         ✗ %s\n" "$(echo "$response" | cut -c1-120)"
  fi
}

echo "Running tests..."
echo "  -----|-----------------------------------------------|---------|--------"

# Test 1: Basic chat completion
run_test "Basic Chat Completion" "/v1/chat/completions" "POST" \
  "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2? Answer with just the number.\"}],\"max_tokens\":50}" \
  "finish_reason"

# Test 2: System + User prompt
run_test "System + User Prompt" "/v1/chat/completions" "POST" \
  "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"system\",\"content\":\"You are a helpful coding assistant.\"},{\"role\":\"user\",\"content\":\"Write a Python hello world\"}],\"max_tokens\":100}" \
  "content"

# Test 3: Temperature 0 (deterministic)
run_test "Temperature 0 (Deterministic)" "/v1/chat/completions" "POST" \
  "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: test123\"}],\"max_tokens\":20,\"temperature\":0}" \
  "content"

# Test 4: Multi-turn conversation
run_test "Multi-turn Conversation" "/v1/chat/completions" "POST" \
  "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"My name is Alice\"},{\"role\":\"assistant\",\"content\":\"Hello Alice! Nice to meet you.\"},{\"role\":\"user\",\"content\":\"What is my name?\"}],\"max_tokens\":30}" \
  "Alice"

# Test 5: Max tokens limit (should truncate)
run_test "Max Tokens Limit (truncation)" "/v1/chat/completions" "POST" \
  "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Tell me a very long story about dragons\"}],\"max_tokens\":10}" \
  "finish_reason"

# Test 6: List models endpoint
run_test "List Models (GET /v1/models)" "/v1/models" "GET" "" "data"

# Test 7: Invalid API key (expect 401)
SAVED_KEY="$API_KEY"
API_KEY="invalid-key-12345"
run_test "Auth — Invalid API Key (expect 401)" "/v1/chat/completions" "POST" \
  "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"max_tokens\":10}" \
  "" "true"
API_KEY="$SAVED_KEY"

# Test 8: Empty messages (expect 400/422)
run_test "Error — Empty Messages (expect 400)" "/v1/chat/completions" "POST" \
  "{\"model\":\"$MODEL_NAME\",\"messages\":[],\"max_tokens\":10}" \
  "" "true"

# Test 9: Streaming response
run_test "Streaming Response" "/v1/chat/completions" "POST" \
  "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 5\"}],\"max_tokens\":50,\"stream\":true}" \
  "data:"

# Test 10: Model catalog check
echo ""
echo "--- Model Catalog ---"
CATALOG_COUNT=$(kubectl get models -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if [[ $CATALOG_COUNT -gt 0 ]]; then
  printf "  PASS | %-45s | %d models available\n" "Model Catalog Count" "$CATALOG_COUNT"
  PASSED=$((PASSED + 1))
else
  printf "  FAIL | %-45s | 0 models\n" "Model Catalog Count"
  FAILED=$((FAILED + 1))
fi

# Summary
echo ""
echo "========================================="
echo "  RESULTS SUMMARY"
echo "========================================="
TOTAL=$((PASSED + FAILED))
if [[ $TOTAL -gt 0 ]]; then
  RATE=$((PASSED * 100 / TOTAL))
else
  RATE=0
fi
echo "  Total: $TOTAL | Passed: $PASSED | Failed: $FAILED"
echo "  Pass Rate: ${RATE}%"
echo "========================================="

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "⚠️  Some tests failed. Review output above."
  exit 1
else
  echo ""
  echo "✅ All tests passed!"
fi
