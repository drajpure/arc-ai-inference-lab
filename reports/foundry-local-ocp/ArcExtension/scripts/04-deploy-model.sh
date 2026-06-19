#!/usr/bin/env bash
# 04-deploy-model.sh
# Deploys a model via the ModelDeployment CRD created by the extension.
#
# Prerequisites:
#   - Extension installed and all pods Running (03-install-extension.sh)
#   - The models.inference.foundry.azure.com CRD must exist

set -euo pipefail
source "$(dirname "$0")/../env.sh"

echo "=== Deploying Model ==="
echo ""
echo "  Model:     $MODEL_NAME"
echo "  Namespace: $NAMESPACE"
echo ""

# Verify CRD exists
if ! kubectl get crd modeldeployments.inference.foundry.azure.com &>/dev/null; then
  echo "❌ ModelDeployment CRD not found. Is the extension installed?"
  exit 1
fi

# Check if deployment already exists
if kubectl get modeldeployment "$MODEL_NAME" -n "$NAMESPACE" &>/dev/null; then
  READY=$(kubectl get modeldeployment "$MODEL_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  echo "ℹ️  ModelDeployment '$MODEL_NAME' already exists (Ready=$READY)"
  if [[ "$READY" == "True" ]]; then
    echo "✅ Model is already deployed and ready."
    exit 0
  fi
  echo "   Waiting for it to become ready..."
fi

# Deploy the model
if ! kubectl get modeldeployment "$MODEL_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "Applying ModelDeployment manifest..."
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: inference.foundry.azure.com/v1alpha1
kind: ModelDeployment
metadata:
  name: $MODEL_NAME
spec:
  model:
    catalog:
      name: $MODEL_NAME
  compute: cpu
EOF
fi

echo ""
echo "⏳ Waiting for model to become Ready..."
echo ""

# Poll until Ready (timeout: 10 min for model download)
MAX_WAIT=600
ELAPSED=0
INTERVAL=15

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  READY=$(kubectl get modeldeployment "$MODEL_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

  if [[ "$READY" == "True" ]]; then
    echo ""
    echo "✅ Model '$MODEL_NAME' is Ready!"
    echo ""
    kubectl get modeldeployment "$MODEL_NAME" -n "$NAMESPACE"
    break
  fi

  MESSAGE=$(kubectl get modeldeployment "$MODEL_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
  printf "  [%3ds] Ready=%s Message=%s\n" "$ELAPSED" "${READY:-Unknown}" "${MESSAGE:-Pending}"

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  echo ""
  echo "⚠️  Timeout after ${MAX_WAIT}s. Model may still be downloading."
  echo "   Check: kubectl get modeldeployment $MODEL_NAME -n $NAMESPACE -o yaml"
  exit 1
fi

echo ""
echo "Next: Run 05-validate-inference.sh"
