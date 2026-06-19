#!/usr/bin/env bash
# 03-install-extension.sh
# Installs Foundry Local via the Azure Arc extension mechanism.
#
# Prerequisites (must be completed before running this):
#   1. 01-prep-namespace-scc.sh — SCC grants in place
#   2. 02-prep-storage.sh — storage ready (if USE_LOCAL_STORAGE=true)
#   3. Cluster connected to Azure Arc (az connectedk8s show should work)
#
# The extension's Helm install is ATOMIC — if any pod can't start within
# the timeout, the entire release is rolled back. That's why SCC and
# storage must be ready before this step.

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

echo "=== Installing Foundry Local via Arc Extension ==="
echo ""
echo "  Extension name: $EXTENSION_NAME"
echo "  Extension type: $EXTENSION_TYPE"
echo "  Arc cluster:    $ARC_CLUSTER_NAME"
echo "  Resource group: $ARC_RESOURCE_GROUP"
echo "  Namespace:      $NAMESPACE"
echo ""

# Verify Arc connectivity
echo "--- Verifying Arc connection ---"
ARC_STATUS=$(az connectedk8s show \
  -n "$ARC_CLUSTER_NAME" \
  -g "$ARC_RESOURCE_GROUP" \
  --query "connectivityStatus" -o tsv 2>/dev/null || echo "Failed")

if [[ "$ARC_STATUS" != "Connected" ]]; then
  echo "FAIL: Arc cluster is not Connected (status: ${ARC_STATUS:-unknown})"
  echo "   Run: az connectedk8s show -n $ARC_CLUSTER_NAME -g $ARC_RESOURCE_GROUP"
  exit 1
fi
echo "OK: Arc cluster is Connected"
echo ""

# Check if extension already exists
EXISTING=$(az k8s-extension show \
  --name "$EXTENSION_NAME" \
  --cluster-name "$ARC_CLUSTER_NAME" \
  --resource-group "$ARC_RESOURCE_GROUP" \
  --cluster-type connectedClusters \
  --query "provisioningState" -o tsv 2>/dev/null || echo "NotFound")

if [[ "$EXISTING" == "Succeeded" ]]; then
  echo "✅ Extension '$EXTENSION_NAME' already installed and Succeeded."
  echo "   To reinstall, first run: 06-uninstall.sh"
  exit 0
elif [[ "$EXISTING" != "NotFound" && "$EXISTING" != "" ]]; then
  echo "⚠️  Extension exists in state: $EXISTING"
  echo "   Delete it first: az k8s-extension delete --name $EXTENSION_NAME ..."
  exit 1
fi

# Install the extension
echo "--- Installing extension ---"
echo "Config: global.telemetry.enabled=false"
echo ""

az k8s-extension create \
  --name "$EXTENSION_NAME" \
  --extension-type "$EXTENSION_TYPE" \
  --cluster-name "$ARC_CLUSTER_NAME" \
  --resource-group "$ARC_RESOURCE_GROUP" \
  --cluster-type connectedClusters \
  --configuration-settings "global.telemetry.enabled=false" \
  --no-wait

echo ""
echo "⏳ Extension install submitted (--no-wait). Monitoring..."
echo ""

# Poll until provisioned or failed (timeout: 10 min)
MAX_WAIT=600
ELAPSED=0
INTERVAL=15

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATE=$(az k8s-extension show \
    --name "$EXTENSION_NAME" \
    --cluster-name "$ARC_CLUSTER_NAME" \
    --resource-group "$ARC_RESOURCE_GROUP" \
    --cluster-type connectedClusters \
    --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")

  if [[ "$STATE" == "Succeeded" ]]; then
    echo ""
    echo "✅ Extension provisioned successfully!"
    break
  elif [[ "$STATE" == "Failed" ]]; then
    echo ""
    echo "❌ Extension installation failed!"
    az k8s-extension show \
      --name "$EXTENSION_NAME" \
      --cluster-name "$ARC_CLUSTER_NAME" \
      --resource-group "$ARC_RESOURCE_GROUP" \
      --cluster-type connectedClusters \
      --query "statuses[0].message" -o tsv 2>/dev/null
    echo ""
    echo "Common causes:"
    echo "  - PVC couldn't bind (storage not ready) → run 02-prep-storage.sh"
    echo "  - SCC rejection (pods can't start) → run 01-prep-namespace-scc.sh"
    echo "  - Delete failed extension and retry:"
    echo "    az k8s-extension delete --name $EXTENSION_NAME \\"
    echo "      --cluster-name $ARC_CLUSTER_NAME --resource-group $ARC_RESOURCE_GROUP \\"
    echo "      --cluster-type connectedClusters --yes"
    exit 1
  fi

  printf "  [%3ds] State: %s\r" "$ELAPSED" "$STATE"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  echo ""
  echo "⚠️  Timeout after ${MAX_WAIT}s. Current state: $STATE"
  echo "   The install may still be in progress. Check with:"
  echo "   az k8s-extension show --name $EXTENSION_NAME ..."
  exit 1
fi

# Post-install: fix PV if it's in Released state (race condition workaround)
PV_PHASE=$(kubectl get pv foundry-model-store-pv -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$PV_PHASE" == "Released" ]]; then
  echo ""
  echo "⚠️  PV in Released state — clearing stale claimRef..."
  kubectl patch pv foundry-model-store-pv --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
fi

echo ""
echo "=== Post-Install Verification ==="
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Next: Run 04-deploy-model.sh"
