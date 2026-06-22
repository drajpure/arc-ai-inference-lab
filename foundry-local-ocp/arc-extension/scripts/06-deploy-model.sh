#!/usr/bin/env bash
# 06-deploy-model.sh
# Deploys a model via the ModelDeployment CRD created by the extension.
#
# Prerequisites:
#   - Extension installed and all pods Running (04-install-extension.sh)
#   - The models.inference.foundry.azure.com CRD must exist

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

# Sanitize model name for DNS-1035: replace dots with hyphens, lowercase
DEPLOY_NAME=$(echo "$MODEL_ALIAS" | tr '.' '-' | tr '[:upper:]' '[:lower:]')

echo "=== Deploying Model ==="
echo ""
echo "  Model catalog name: $MODEL_ALIAS"
echo "  Deployment name:    $DEPLOY_NAME"
echo "  Namespace:          $NAMESPACE"
echo ""

# Verify CRD exists
if ! kubectl get crd modeldeployments.foundrylocal.azure.com &>/dev/null; then
  echo "ERROR: ModelDeployment CRD not found. Is the extension installed?"
  exit 1
fi

# Check if deployment already exists
if kubectl get modeldeployment "$DEPLOY_NAME" -n "$NAMESPACE" &>/dev/null; then
  READY=$(kubectl get modeldeployment "$DEPLOY_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  echo "ModelDeployment '$DEPLOY_NAME' already exists (Ready=$READY)"
  if [[ "$READY" == "True" ]]; then
    echo "OK Model is already deployed and ready."
    echo ""
    echo "Next: Run ./scripts/07-validate-inference.sh"
    exit 0
  fi
  echo "   Waiting for it to become ready..."
fi

# Deploy the model
if ! kubectl get modeldeployment "$DEPLOY_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "Applying ModelDeployment manifest..."
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: foundrylocal.azure.com/v1
kind: ModelDeployment
metadata:
  name: $DEPLOY_NAME
spec:
  model:
    catalog:
      name: $MODEL_ALIAS
  compute: cpu
EOF
fi

echo ""
echo "Waiting for model to become Ready..."
echo ""

# Poll until Ready (timeout: 10 min for model download)
MAX_WAIT=600
ELAPSED=0
INTERVAL=15

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  READY=$(kubectl get modeldeployment "$DEPLOY_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)

  if [[ "$READY" == "True" ]]; then
    echo ""
    echo "OK Model '$DEPLOY_NAME' is Ready!"
    echo ""
    kubectl get modeldeployment "$DEPLOY_NAME" -n "$NAMESPACE"
    break
  fi

  MESSAGE=$(kubectl get modeldeployment "$DEPLOY_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null)
  printf "  [%3ds] Ready=%s Message=%s\n" "$ELAPSED" "${READY:-Unknown}" "${MESSAGE:-Pending}"

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  echo ""
  echo "WARNING: Timeout after ${MAX_WAIT}s. Model may still be downloading."
  echo "   Check: kubectl get modeldeployment $DEPLOY_NAME -n $NAMESPACE -o yaml"
  exit 1
fi

echo ""
echo "Next: Run ./scripts/07-validate-inference.sh"
