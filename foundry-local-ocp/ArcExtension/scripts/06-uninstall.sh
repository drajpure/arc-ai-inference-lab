#!/usr/bin/env bash
# 06-uninstall.sh
# Cleanly removes Foundry Local and restores the cluster to pre-install state.
#
# Order of operations:
#   1. Delete ModelDeployments (stop inference)
#   2. Delete the Arc extension (removes Helm release + most resources)
#   3. Wait for extension deletion to complete
#   4. Clean up leftover resources (SAs, SCC bindings, CRDs, PVCs)
#   5. Restore default StorageClass (if changed)
#   6. Clear PV claimRef (make it Available for reuse)
#
# Does NOT delete:
#   - The namespace (OCP manages it)
#   - The StorageClass or PV (cluster-level, reusable)
#   - Arc connectivity (az connectedk8s)

set -euo pipefail
source "$(dirname "$0")/../env.sh"

echo "=== Uninstalling Foundry Local ==="
echo ""

# Step 1: Delete model deployments
echo "--- Step 1: Delete model deployments ---"
if kubectl get crd modeldeployments.inference.foundry.azure.com &>/dev/null; then
  MODELS=$(kubectl get modeldeployment -n "$NAMESPACE" -o name 2>/dev/null)
  if [[ -n "$MODELS" ]]; then
    echo "$MODELS" | xargs -I {} kubectl delete {} -n "$NAMESPACE" --wait=false
    echo "✅ Model deployments deleted"
  else
    echo "  No model deployments found"
  fi
else
  echo "  CRD not present — skipping"
fi

echo ""
echo "--- Step 2: Delete Arc extension ---"
EXISTING=$(az k8s-extension show \
  --name "$EXTENSION_NAME" \
  --cluster-name "$ARC_CLUSTER_NAME" \
  --resource-group "$ARC_RESOURCE_GROUP" \
  --cluster-type connectedClusters \
  --query "provisioningState" -o tsv 2>/dev/null || echo "NotFound")

if [[ "$EXISTING" == "NotFound" ]]; then
  echo "  Extension already deleted"
else
  echo "  Deleting extension '$EXTENSION_NAME'..."
  az k8s-extension delete \
    --name "$EXTENSION_NAME" \
    --cluster-name "$ARC_CLUSTER_NAME" \
    --resource-group "$ARC_RESOURCE_GROUP" \
    --cluster-type connectedClusters \
    --yes

  # Wait for deletion
  echo "  Waiting for deletion..."
  MAX_WAIT=180
  ELAPSED=0
  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    STATE=$(az k8s-extension show \
      --name "$EXTENSION_NAME" \
      --cluster-name "$ARC_CLUSTER_NAME" \
      --resource-group "$ARC_RESOURCE_GROUP" \
      --cluster-type connectedClusters \
      --query "provisioningState" -o tsv 2>/dev/null || echo "NotFound")
    if [[ "$STATE" == "NotFound" ]]; then
      break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
  done
  echo "✅ Extension deleted"
fi

echo ""
echo "--- Step 3: Clean up SCC rolebindings ---"
SERVICE_ACCOUNTS=(
  "default"
  "foundry-config-reader"
  "${EXTENSION_NAME}-inference-operator"
  "${EXTENSION_NAME}-inference-operator-api"
  "${EXTENSION_NAME}-inference-operator-catalog-sync"
  "inference-operator-crd-update"
)

for sa in "${SERVICE_ACCOUNTS[@]}"; do
  BINDING_NAME="scc-privileged-${sa}"
  if kubectl get rolebinding "$BINDING_NAME" -n "$NAMESPACE" &>/dev/null; then
    kubectl delete rolebinding "$BINDING_NAME" -n "$NAMESPACE"
    echo "  Deleted: $BINDING_NAME"
  fi
done

echo ""
echo "--- Step 4: Clean up leftover ServiceAccounts ---"
for sa in "${SERVICE_ACCOUNTS[@]}"; do
  if [[ "$sa" == "default" || "$sa" == "builder" || "$sa" == "deployer" ]]; then
    continue
  fi
  if kubectl get serviceaccount "$sa" -n "$NAMESPACE" &>/dev/null; then
    kubectl delete serviceaccount "$sa" -n "$NAMESPACE"
    echo "  Deleted SA: $sa"
  fi
done

echo ""
echo "--- Step 5: Clean up CRDs ---"
CRDS=(
  "modeldeployments.inference.foundry.azure.com"
  "models.inference.foundry.azure.com"
)
for crd in "${CRDS[@]}"; do
  if kubectl get crd "$crd" &>/dev/null; then
    kubectl delete crd "$crd"
    echo "  Deleted CRD: $crd"
  fi
done

echo ""
echo "--- Step 6: Clean up PVCs ---"
PVCS=$(kubectl get pvc -n "$NAMESPACE" -o name 2>/dev/null)
if [[ -n "$PVCS" ]]; then
  echo "$PVCS" | xargs -I {} kubectl delete {} -n "$NAMESPACE"
  echo "  ✅ PVCs deleted"
fi

echo ""
echo "--- Step 7: Restore default StorageClass ---"
if [[ "${USE_LOCAL_STORAGE}" == "true" ]]; then
  CURRENT_DEFAULT=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
  if [[ "$CURRENT_DEFAULT" == "local-storage" ]]; then
    echo "  Restoring managed-csi as default..."
    kubectl patch sc local-storage \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    kubectl patch sc managed-csi \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
    echo "  ✅ Default SC restored"
  fi
fi

echo ""
echo "--- Step 8: Clear PV claimRef ---"
PV_NAME="foundry-model-store-pv"
if kubectl get pv "$PV_NAME" &>/dev/null; then
  PV_PHASE=$(kubectl get pv "$PV_NAME" -o jsonpath='{.status.phase}')
  if [[ "$PV_PHASE" == "Released" || "$PV_PHASE" == "Bound" ]]; then
    kubectl patch pv "$PV_NAME" --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]' 2>/dev/null || true
    echo "  ✅ PV claimRef cleared — now Available"
  else
    echo "  PV is already $PV_PHASE"
  fi
fi

echo ""
echo "=== Uninstall Complete ==="
echo ""
echo "Cluster-level resources preserved (for reuse):"
echo "  - StorageClass: local-storage"
echo "  - PersistentVolume: $PV_NAME"
echo "  - Namespace: $NAMESPACE (empty, OCP defaults only)"
echo "  - Arc connection: $ARC_CLUSTER_NAME"
