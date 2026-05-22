#!/bin/bash
# 08-e2e-tests.sh
# Run a comprehensive E2E test suite against the deployed Foundry Local model.
# Outputs results in a structured format suitable for CI/CD or report generation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

NAMESPACE="${NAMESPACE:-foundry-local-operator}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-qwen-coder-deploy}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen2.5-coder-0.5b}"

echo "========================================="
echo "  FOUNDRY LOCAL E2E TEST SUITE"
echo "  Namespace: ${NAMESPACE}"
echo "  Deployment: ${DEPLOYMENT_NAME}"
echo "  Model: ${MODEL_ALIAS}"
echo "  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================="
echo ""

# Get API key
API_KEY=$(kubectl get secret "${DEPLOYMENT_NAME}-api-keys" -n "${NAMESPACE}" \
  -o jsonpath='{.data.primary-key}' | base64 -d)

if [[ -z "${API_KEY}" ]]; then
  echo "ERROR: Could not retrieve API key from secret '${DEPLOYMENT_NAME}-api-keys'"
  exit 1
fi

# Start port-forward
kubectl port-forward "svc/${DEPLOYMENT_NAME}" 5000:5000 -n "${NAMESPACE}" &
PF_PID=$!
sleep 3

# Cleanup on exit
cleanup() {
  kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE_URL="https://localhost:5000"
PASSED=0
FAILED=0
RESULTS=""

# Test helper function
run_test() {
  local test_name="$1"
  local endpoint="$2"
  local method="$3"
  local body="$4"
  local validate_pattern="$5"
  local expect_failure="${6:-false}"

  local start_time=$(date +%s%N)
  local http_code
  local response

  if [[ "${method}" == "GET" ]]; then
    response=$(curl -sk -w "\n%{http_code}" "${BASE_URL}${endpoint}" \
      -H "api-key: ${API_KEY}" 2>/dev/null)
  else
    response=$(curl -sk -w "\n%{http_code}" "${BASE_URL}${endpoint}" \
      -H "api-key: ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${body}" 2>/dev/null)
  fi

  http_code=$(echo "${response}" | tail -1)
  response=$(echo "${response}" | sed '$d')
  local end_time=$(date +%s%N)
  local duration=$(echo "scale=2; (${end_time} - ${start_time}) / 1000000000" | bc 2>/dev/null || echo "?")

  local status="PASS"
  if [[ "${expect_failure}" == "true" ]]; then
    # We expect a non-200 response
    if [[ "${http_code}" =~ ^(401|400|422)$ ]]; then
      status="PASS"
    else
      status="FAIL"
    fi
  else
    if echo "${response}" | grep -q "${validate_pattern}"; then
      status="PASS"
    else
      status="FAIL"
    fi
  fi

  if [[ "${status}" == "PASS" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi

  printf "  %-4s | %-40s | %6ss | HTTP %s\n" "${status}" "${test_name}" "${duration}" "${http_code}"
  RESULTS="${RESULTS}\n| ${test_name} | ${status} | ${duration}s | ${http_code} |"

  # Print the actual response so users can see what the model returned.
  # Disable errexit for this block — jq failures, missing tools, or non-JSON
  # responses must NOT abort the test suite.
  set +e
  if [[ "${expect_failure}" == "true" ]]; then
    # For negative tests, print the error body (short — first 200 chars)
    local err_snippet
    err_snippet=$(echo "${response}" | tr -d '\n' | cut -c1-200)
    [[ -n "${err_snippet}" ]] && printf "       error: %s\n" "${err_snippet}"
  elif [[ "${endpoint}" == "/v1/models" ]]; then
    # GET /v1/models — show model count plus first 3 IDs (jq required for parsing)
    if command -v jq &>/dev/null; then
      local model_count first_models
      model_count=$(echo "${response}" | jq -r '.data | length' 2>/dev/null)
      first_models=$(echo "${response}" | jq -r '.data[0:3] | map(.id) | join(", ")' 2>/dev/null)
      [[ -z "${model_count}" ]] && model_count="?"
      printf "       models: %s found — %s\n" "${model_count}" "${first_models}"
    else
      printf "       raw:   %s\n" "$(echo "${response}" | tr -d '\n' | cut -c1-200)"
    fi
  else
    # Chat completion — extract assistant message content + finish_reason
    local content="" finish="?"
    if command -v jq &>/dev/null; then
      content=$(echo "${response}" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
      finish=$(echo "${response}" | jq -r '.choices[0].finish_reason // "?"' 2>/dev/null)
    fi
    if [[ -n "${content}" ]]; then
      local truncated=""
      [[ ${#content} -gt 200 ]] && truncated="..."
      local content_oneline
      content_oneline=$(echo "${content}" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200)
      printf "       reply: %s%s (finish=%s)\n" "${content_oneline}" "${truncated}" "${finish}"
    elif [[ -n "${response}" ]]; then
      # Fallback — show first 200 chars of raw response (e.g., jq missing)
      printf "       raw:   %s\n" "$(echo "${response}" | tr -d '\n' | cut -c1-200)"
    fi
  fi
  set -e
}

echo "Running tests..."
echo "  -----|------------------------------------------|---------|--------"

# Test 1: Basic chat completion
run_test "Basic Chat Completion" "/v1/chat/completions" "POST" \
  '{"model":"'"${MODEL_ALIAS}"'","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":50}' \
  "finish_reason"

# Test 2: System + User prompt
run_test "System + User Prompt" "/v1/chat/completions" "POST" \
  '{"model":"'"${MODEL_ALIAS}"'","messages":[{"role":"system","content":"You are a helpful coding assistant."},{"role":"user","content":"Write a Python hello world"}],"max_tokens":100}' \
  "content"

# Test 3: Temperature 0 (deterministic)
run_test "Temperature 0 (Deterministic)" "/v1/chat/completions" "POST" \
  '{"model":"'"${MODEL_ALIAS}"'","messages":[{"role":"user","content":"Say exactly: test123"}],"max_tokens":20,"temperature":0}' \
  "content"

# Test 4: Multi-turn conversation
run_test "Multi-turn Conversation" "/v1/chat/completions" "POST" \
  '{"model":"'"${MODEL_ALIAS}"'","messages":[{"role":"user","content":"My name is Alice"},{"role":"assistant","content":"Hello Alice!"},{"role":"user","content":"What is my name?"}],"max_tokens":30}' \
  "Alice"

# Test 5: Max tokens limit
run_test "Max Tokens Limit" "/v1/chat/completions" "POST" \
  '{"model":"'"${MODEL_ALIAS}"'","messages":[{"role":"user","content":"Tell me a very long story about dragons"}],"max_tokens":10}' \
  "finish_reason"

# Test 6: List models endpoint
run_test "List Models (GET /v1/models)" "/v1/models" "GET" "" "model\|data\|id"

# Test 7: Invalid API key (expect 401)
API_KEY_BAK="${API_KEY}"
API_KEY="invalid-key-12345"
run_test "Auth — Invalid API Key (401)" "/v1/chat/completions" "POST" \
  '{"model":"'"${MODEL_ALIAS}"'","messages":[{"role":"user","content":"test"}],"max_tokens":10}' \
  "" "true"
API_KEY="${API_KEY_BAK}"

# Test 8: Empty messages (expect 400/422)
run_test "Error — Empty Messages (400)" "/v1/chat/completions" "POST" \
  '{"model":"'"${MODEL_ALIAS}"'","messages":[],"max_tokens":10}' \
  "" "true"

echo ""
echo "========================================="
echo "  RESULTS SUMMARY"
echo "========================================="
TOTAL=$((PASSED + FAILED))
RATE=$(echo "scale=1; ${PASSED} * 100 / ${TOTAL}" | bc 2>/dev/null || echo "?")
echo "  Total: ${TOTAL} | Passed: ${PASSED} | Failed: ${FAILED}"
echo "  Pass Rate: ${RATE}%"
echo "========================================="

# Exit with failure if any test failed
if [[ ${FAILED} -gt 0 ]]; then
  echo ""
  echo "⚠ Some tests failed. Review output above for details."
  exit 1
else
  echo ""
  echo "✓ All tests passed!"
  exit 0
fi
