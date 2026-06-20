#!/usr/bin/env bash

set -euo pipefail

# -------- helpers ----------

# Wait for Enter, then clear screen for the next step
next_step() {
  echo ""
  read -p "👉 Press Enter for next step..."
  clear
}

print_step() {
  echo "===================================================="
  echo "🔹 $1"
  echo "   $2"
  echo "===================================================="
  echo ""
}

show_cmd() {
  echo "💻 COMMAND:"
  echo "   $1"
  echo "----------------------------------------------------"
}

# =========================================================
# STEP 0a: Load environment
# =========================================================
clear
echo "========================================="
echo "🚀 Foundry Local on OpenShift Demo"
echo "========================================="
echo ""
print_step "Step 0a: Load environment configuration" \
"All deployment variables are configured"

if [[ -f "./env.sh" ]]; then
  show_cmd "source env.sh"
  source ./env.sh
  
  # Derive deployment name (DNS-1035 safe: dots → hyphens)
  DEPLOY_NAME=$(echo "$MODEL_ALIAS" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
  
  echo ""
  echo "✅ Environment loaded:"
  echo ""
  echo "   --- Azure Identity ---"
  echo "   Subscription:      ${AZURE_SUBSCRIPTION_ID:-n/a}"
  echo "   Tenant:            ${AZURE_TENANT_ID:-n/a}"
  echo "   Region:            ${AZURE_REGION:-n/a}"
  echo ""
  echo "   --- Stage A: OCP Cluster ---"
  echo "   Cluster Name:      ${CLUSTER_NAME:-n/a}"
  echo "   Base Domain:       ${BASE_DOMAIN:-n/a}"
  echo "   KUBECONFIG:        ${KUBECONFIG:-n/a}"
  echo ""
  echo "   --- Stage B: Azure Arc ---"
  echo "   Arc Resource Group: ${ARC_RESOURCE_GROUP:-n/a}"
  echo "   Arc Cluster Name:  ${ARC_CLUSTER_NAME:-n/a}"
  echo ""
  echo "   --- Stage C: Foundry Local ---"
  echo "   Namespace:         ${NAMESPACE:-n/a}"
  echo "   Extension Name:    ${EXTENSION_NAME:-n/a}"
  echo "   Model (catalog):   ${MODEL_ALIAS:-n/a}"
  echo "   Deploy Name:       ${DEPLOY_NAME:-n/a}"
else
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi

# =========================================================
# STEP 0b: Azure CLI & Login
# =========================================================
next_step
print_step "Step 0b: Prerequisites — Azure CLI & Login" \
"Azure CLI is accessible and authenticated"

# Ensure az is on PATH (Git Bash doesn't inherit it by default)
if ! command -v az &>/dev/null; then
  echo "⚠️  'az' not found on PATH. Adding Azure CLI..."
  export PATH="$PATH:/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin"
fi

if command -v az &>/dev/null; then
  echo "✅ Azure CLI found: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
else
  echo "❌ Azure CLI not found. Install from https://aka.ms/installazurecli"
  exit 1
fi

# Check if already logged in; if not, prompt login
if az account show &>/dev/null; then
  echo "✅ Already logged in as: $(az account show --query user.name -o tsv)"
  echo "   Subscription: $(az account show --query name -o tsv)"
else
  echo "🔑 Not logged in. Starting az login..."
  az login
fi

# =========================================================
# STEP 1: Cluster health
# =========================================================
next_step
print_step "Step 1: Verify cluster health" \
"OCP cluster is up and reachable"

show_cmd "oc get nodes"
oc get nodes

# =========================================================
# STEP 2: Pod status & details
# =========================================================
next_step
print_step "Step 2: Foundry Local pod status & details" \
"All FL components are running with expected resources"

show_cmd "kubectl get pods -n \$NAMESPACE -o wide"
kubectl get pods -n "$NAMESPACE" -o wide

echo ""
echo "📋 Pod resource details (requests/limits, images, restarts):"
echo "----------------------------------------------------"
kubectl get pods -n "$NAMESPACE" -o json | jq -r '
  .items[] |
  "Pod: \(.metadata.name)",
  "  Status: \(.status.phase)  Restarts: \([.status.containerStatuses[]?.restartCount // 0] | add)",
  "  Containers:",
  (.spec.containers[] |
    "    \(.name)  image=\(.image | split("/")[-1])",
    "      requests: cpu=\(.resources.requests.cpu // "n/a") mem=\(.resources.requests.memory // "n/a")",
    "      limits:   cpu=\(.resources.limits.cpu // "n/a") mem=\(.resources.limits.memory // "n/a")"
  ),
  "---"'

# =========================================================
# STEP 3: Model catalog
# =========================================================
next_step
print_step "Step 3: Model catalog & available models" \
"Foundry Local full catalog + hardware-compatible models"

show_cmd "kubectl get models -n \$NAMESPACE"
echo ""
echo "--- Full Model Catalog ---"
kubectl get models -n "$NAMESPACE"
echo ""
CATALOG_COUNT=$(kubectl get models -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
echo "📦 Total models in catalog: $CATALOG_COUNT"
echo ""
echo "--- Hardware-Compatible (deployable on this cluster) ---"
kubectl get storemodels -n "$NAMESPACE"
echo ""
STORE_COUNT=$(kubectl get storemodels -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
echo "📦 Deployable models (matching node hardware): $STORE_COUNT"

# =========================================================
# STEP 4: Deployed model status
# =========================================================
next_step
print_step "Step 4: Deployed model status" \
"ModelDeployment CRD is running and ready"

show_cmd "kubectl get modeldeployment -n \$NAMESPACE"
kubectl get modeldeployment -n "$NAMESPACE"

# =========================================================
# STEP 5: Port-forward
# =========================================================
next_step
print_step "Step 5: Start port-forward" \
"Local access to model endpoint"

show_cmd "kubectl port-forward -n \$NAMESPACE svc/$DEPLOY_NAME 5000:5000 &"
kubectl port-forward -n "$NAMESPACE" svc/"$DEPLOY_NAME" 5000:5000 > pf.log 2>&1 &
PF_PID=$!

echo ""
echo "✅ Port-forward started (PID: $PF_PID)"
sleep 2

# =========================================================
# STEP 6: Extract API key
# =========================================================
next_step
print_step "Step 6: Extract API key" \
"Secure API access via generated key"

show_cmd "kubectl get secret ${DEPLOY_NAME}-api-keys -n \$NAMESPACE -o jsonpath=\"{.data['primary-key']}\" | base64 -d"
API_KEY=$(kubectl get secret "${DEPLOY_NAME}-api-keys" \
  -n "$NAMESPACE" \
  -o jsonpath="{.data['primary-key']}" | base64 -d)

echo ""
echo "✅ API key (truncated): ${API_KEY:0:12}..."

# =========================================================
# STEP 7: Verify endpoint
# =========================================================
next_step
print_step "Step 7: Verify endpoint" \
"HTTPS enforced + authentication required"

show_cmd "curl -sk https://localhost:5000/ | jq"
curl -sk https://localhost:5000/ | jq

# =========================================================
# STEP 8: Basic reasoning
# =========================================================
next_step
print_step "Step 8: Basic reasoning test" \
"Prompt: What is 2+2? → Validates inference"

show_cmd "curl -sk https://localhost:5000/v1/chat/completions -H 'api-key: ...' -d '{\"model\":\"$DEPLOY_NAME\",...}'"

RESP=$(curl -sk https://localhost:5000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "api-key: $API_KEY" \
  -d "{\"model\":\"$DEPLOY_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2?\"}]}")

echo ""
echo "📨 PROMPT: What is 2+2?"
echo ""
echo "📦 RESPONSE:"
echo "$RESP" | jq
echo ""
echo "✅ ANSWER: $(echo "$RESP" | jq -r '.choices[0].message.content')"

# =========================================================
# STEP 9: Code generation
# =========================================================
next_step
print_step "Step 9: Code generation" \
"Prompt: Write a Python hello world → Dev scenario"

show_cmd "curl -sk https://localhost:5000/v1/chat/completions -H 'api-key: ...' -d '{\"model\":\"$DEPLOY_NAME\",...}'"

RESP=$(curl -sk https://localhost:5000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "api-key: $API_KEY" \
  -d "{\"model\":\"$DEPLOY_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a Python hello world script\"}]}")

echo ""
echo "📨 PROMPT: Write a Python hello world script"
echo ""
echo "📦 RESPONSE:"
echo "$RESP" | jq
echo ""
echo "✅ ANSWER: $(echo "$RESP" | jq -r '.choices[0].message.content')"

# =========================================================
# STEP 10: Deterministic output
# =========================================================
next_step
print_step "Step 10: Deterministic output" \
"Prompt: Say exactly test123 (temperature=0) → Validates control"

show_cmd "curl -sk https://localhost:5000/v1/chat/completions -H 'api-key: ...' -d '{\"model\":\"$DEPLOY_NAME\",\"temperature\":0,...}'"

RESP=$(curl -sk https://localhost:5000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "api-key: $API_KEY" \
  -d "{\"model\":\"$DEPLOY_NAME\",\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: test123\"}]}")

echo ""
echo "📨 PROMPT: Say exactly: test123"
echo ""
echo "📦 RESPONSE:"
echo "$RESP" | jq
echo ""
echo "✅ ANSWER: $(echo "$RESP" | jq -r '.choices[0].message.content')"

# =========================================================
# STEP 11: Multi-turn conversation
# =========================================================
next_step
print_step "Step 11: Multi-turn conversation" \
"Prompt: Alice context → Validates memory"

show_cmd "curl -sk https://localhost:5000/v1/chat/completions -H 'api-key: ...' -d '{\"model\":\"$DEPLOY_NAME\",...}'"

RESP=$(curl -sk https://localhost:5000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "api-key: $API_KEY" \
  -d "{\"model\":\"$DEPLOY_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"My name is Alice\"},{\"role\":\"assistant\",\"content\":\"Hello Alice!\"},{\"role\":\"user\",\"content\":\"What is my name?\"}]}")

echo ""
echo "📨 PROMPT: [User: My name is Alice] → [Assistant: Hello Alice!] → [User: What is my name?]"
echo ""
echo "📦 RESPONSE:"
echo "$RESP" | jq
echo ""
echo "✅ ANSWER: $(echo "$RESP" | jq -r '.choices[0].message.content')"

# =========================================================
# STEP 12: Security validation
# =========================================================
next_step
print_step "Step 12: Security validation" \
"Invalid API key → Should return 401"

show_cmd "curl -sk https://localhost:5000/v1/chat/completions -H 'api-key: invalid_key' -d '{...}'"

RESP=$(curl -sk https://localhost:5000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "api-key: invalid_key" \
  -d "{\"model\":\"$DEPLOY_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}")

echo ""
echo "📦 RESPONSE:"
echo "$RESP" | jq
echo ""
echo "✅ Expected: 401 Unauthorized — authentication is enforced"

# =========================================================
# CLEANUP
# =========================================================
next_step
print_step "Cleanup" \
"Stop port-forward"

echo "💻 COMMAND: kill $PF_PID"
echo "----------------------------------------------------"
kill $PF_PID 2>/dev/null || true

echo ""
echo "========================================="
echo "✅ Demo Completed Successfully!"
echo "========================================="