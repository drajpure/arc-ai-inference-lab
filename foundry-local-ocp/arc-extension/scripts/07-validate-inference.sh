#!/usr/bin/env bash
# 07-validate-inference.sh
# Validates the Foundry Local inference endpoint by:
#   1. Port-forwarding to the operator-api service
#   2. Extracting the API key from the cluster secret
#   3. Sending a chat completion request
#   4. Verifying a valid response is returned

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

echo "=== Validating Inference Endpoint ==="
echo ""

# Derive deployment name (same logic as 05-deploy-model.sh)
DEPLOY_NAME=$(echo "$MODEL_ALIAS" | tr '.' '-' | tr '[:upper:]' '[:lower:]')

# Step 1: Extract API key
echo "--- Extracting API key ---"
API_KEY_SECRET="${DEPLOY_NAME}-api-keys"
API_KEY=$(kubectl get secret "$API_KEY_SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.primary-key}' 2>/dev/null | base64 -d)

if [[ -z "$API_KEY" ]]; then
  echo "ERROR: Could not extract API key from secret '$API_KEY_SECRET'"
  echo "   Available secrets: $(kubectl get secrets -n $NAMESPACE -o name | grep -i key)"
  exit 1
fi
echo "OK API key extracted (${#API_KEY} chars)"
echo ""

# Step 2: Start port-forward to model service (background)
echo "--- Starting port-forward ---"
SVC_NAME="$DEPLOY_NAME"
LOCAL_PORT=5000

# Kill any existing port-forward on this port
pkill -f "port-forward.*$LOCAL_PORT:5000" 2>/dev/null || true
sleep 1

kubectl port-forward "svc/$SVC_NAME" "$LOCAL_PORT:5000" -n "$NAMESPACE" &
PF_PID=$!
sleep 3

# Verify port-forward is running
if ! kill -0 $PF_PID 2>/dev/null; then
  echo "ERROR: Port-forward failed. Is the service running?"
  echo "   Check: kubectl get svc -n $NAMESPACE"
  exit 1
fi
echo "OK Port-forward active on localhost:$LOCAL_PORT (PID: $PF_PID)"
echo ""

# Step 3: Send inference request
echo "--- Sending chat completion request ---"
echo "Model: $DEPLOY_NAME"
echo "Prompt: What is 2+2? Answer with just the number."
echo ""

RESPONSE=$(curl -sk "https://localhost:${LOCAL_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "api-key: $API_KEY" \
  -d "{
    \"model\": \"$DEPLOY_NAME\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"What is 2+2? Answer with just the number.\"}
    ],
    \"max_tokens\": 50
  }")

# Cleanup port-forward
kill $PF_PID 2>/dev/null || true

echo ""
echo "--- Response ---"
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"

# Step 4: Validate response
CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

if [[ -z "$CONTENT" ]]; then
  ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
  echo ""
  echo "❌ Inference failed."
  if [[ -n "$ERROR" ]]; then
    echo "   Error: $ERROR"
  fi
  exit 1
fi

echo ""
echo "=== Inference Validation ==="
echo "✅ Model responded: $CONTENT"
echo ""
echo "🎉 Foundry Local on OCP via Arc Extension is fully operational!"
echo ""
echo "Next: Run ./scripts/08-e2e-tests.sh (optional full E2E test suite)"
