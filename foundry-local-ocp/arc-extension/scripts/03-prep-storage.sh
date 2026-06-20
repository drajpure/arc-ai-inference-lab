#!/usr/bin/env bash
# 02-prep-storage.sh
# Prepares storage for the model-store PVC.
#
# If USE_LOCAL_STORAGE=true:
#   1. Creates a local-storage StorageClass (if not exists)
#   2. Creates a PersistentVolume backed by hostPath on a specific node
#   3. Swaps the cluster default StorageClass to local-storage
#
# If USE_LOCAL_STORAGE=false:
#   Skips all storage prep (assumes managed-csi or equivalent works).
#
# MUST run BEFORE 03-install-extension.sh.

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

if [[ "${USE_LOCAL_STORAGE}" != "true" ]]; then
  echo "⏭️  USE_LOCAL_STORAGE=false — skipping storage prep."
  echo "   Assuming cluster default StorageClass (managed-csi) works."
  exit 0
fi

echo "=== Local Storage Setup ==="
echo ""

# Determine target node
if [[ -z "${LOCAL_PV_NODE:-}" ]]; then
  LOCAL_PV_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  echo "⚠️  LOCAL_PV_NODE not set — using first node: $LOCAL_PV_NODE"
fi

echo "Target node: $LOCAL_PV_NODE"
echo "Host path:   $LOCAL_PV_PATH"
echo ""

# Step 1: Create StorageClass
echo "--- Step 1: StorageClass ---"
if kubectl get sc local-storage &>/dev/null; then
  echo "✅ StorageClass 'local-storage' already exists"
else
  echo "Creating StorageClass 'local-storage'..."
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
  echo "✅ Created"
fi

# Step 2: Create host directory on the node (via debug pod)
echo ""
echo "--- Step 2: Create host directory ---"
echo "Creating $LOCAL_PV_PATH on node $LOCAL_PV_NODE..."

kubectl debug node/"$LOCAL_PV_NODE" -it --image=busybox -- \
  sh -c "mkdir -p /host${LOCAL_PV_PATH} && chmod 777 /host${LOCAL_PV_PATH} && echo done" 2>/dev/null || \
  echo "⚠️  Could not create directory via debug pod. Ensure $LOCAL_PV_PATH exists on $LOCAL_PV_NODE."

# Step 3: Create PersistentVolume
echo ""
echo "--- Step 3: PersistentVolume ---"
PV_NAME="foundry-model-store-pv"
if kubectl get pv "$PV_NAME" &>/dev/null; then
  PV_PHASE=$(kubectl get pv "$PV_NAME" -o jsonpath='{.status.phase}')
  echo "✅ PV '$PV_NAME' already exists (status: $PV_PHASE)"
  if [[ "$PV_PHASE" == "Released" ]]; then
    echo "   Clearing stale claimRef..."
    kubectl patch pv "$PV_NAME" --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
    echo "   ✅ PV is now Available"
  fi
else
  echo "Creating PV '$PV_NAME' (100Gi, hostPath)..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV_NAME
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: $LOCAL_PV_PATH
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - $LOCAL_PV_NODE
EOF
  echo "✅ Created"
fi

# Step 4: Swap default StorageClass
echo ""
echo "--- Step 4: Swap default StorageClass ---"
CURRENT_DEFAULT=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if [[ "$CURRENT_DEFAULT" == "local-storage" ]]; then
  echo "✅ 'local-storage' is already the default"
else
  echo "Current default: $CURRENT_DEFAULT"
  echo "Swapping to local-storage..."
  if [[ -n "$CURRENT_DEFAULT" ]]; then
    kubectl patch sc "$CURRENT_DEFAULT" \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
  fi
  kubectl patch sc local-storage \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  echo "✅ Default is now 'local-storage'"
fi

echo ""
echo "=== Storage Setup Complete ==="
echo ""
echo "Next: Run ./scripts/04-install-extension.sh"
