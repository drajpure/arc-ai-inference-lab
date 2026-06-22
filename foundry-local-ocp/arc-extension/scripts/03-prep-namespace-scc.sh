#!/usr/bin/env bash
# 03-prep-namespace-scc.sh
# Pre-creates the namespace (if needed) and grants privileged SCC to all
# ServiceAccounts that the Arc extension will create.
#
# MUST run BEFORE the extension install (04-install-extension.sh).
# The extension's Helm install is atomic — if pods can't start due to SCC,
# the entire release rolls back. So SCC grants must be in place first.

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

echo "=== Step 1: Ensure namespace exists ==="
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo "✅ Namespace '$NAMESPACE' already exists"
else
  echo "Creating namespace '$NAMESPACE'..."
  kubectl create namespace "$NAMESPACE"
fi

echo ""
echo "=== Step 2: Grant privileged SCC to extension ServiceAccounts ==="
echo ""
echo "Extension name: $EXTENSION_NAME"
echo "SA naming pattern: <extension-name>-* plus fixed names"
echo ""

# The Arc extension creates these SAs:
#   <EXTENSION_NAME>-inference-operator
#   <EXTENSION_NAME>-inference-operator-api
#   <EXTENSION_NAME>-inference-operator-catalog-sync
#   foundry-config-reader         (fixed name)
#   inference-operator-crd-update (fixed name)
#   default                       (OCP default)
SERVICE_ACCOUNTS=(
  "default"
  "foundry-config-reader"
  "${EXTENSION_NAME}-inference-operator"
  "${EXTENSION_NAME}-inference-operator-api"
  "${EXTENSION_NAME}-inference-operator-catalog-sync"
  "inference-operator-crd-update"
)

# Pre-create SAs that don't exist yet (so rolebinding can reference them)
# IMPORTANT: SAs must have Helm ownership labels so the extension can adopt them.
# Without these, the extension fails with "invalid ownership metadata".
for sa in "${SERVICE_ACCOUNTS[@]}"; do
  if [[ "$sa" == "default" ]]; then
    continue  # default SA always exists
  fi
  if ! kubectl get serviceaccount "$sa" -n "$NAMESPACE" &>/dev/null; then
    echo "  Creating SA: $sa (with Helm labels)"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $sa
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: $EXTENSION_NAME
    meta.helm.sh/release-namespace: $NAMESPACE
EOF
  else
    # SA exists — ensure it has Helm labels (may have been created without them)
    kubectl label serviceaccount "$sa" -n "$NAMESPACE" \
      app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
    kubectl annotate serviceaccount "$sa" -n "$NAMESPACE" \
      meta.helm.sh/release-name="$EXTENSION_NAME" \
      meta.helm.sh/release-namespace="$NAMESPACE" --overwrite 2>/dev/null || true
    echo "  Updated SA: $sa (Helm labels added)"
  fi
done

echo ""
echo "Granting 'privileged' SCC to each SA..."
echo ""

for sa in "${SERVICE_ACCOUNTS[@]}"; do
  BINDING_NAME="scc-privileged-${sa}"
  if kubectl get rolebinding "$BINDING_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "  ✅ $sa — already granted"
  else
    kubectl create rolebinding "$BINDING_NAME" \
      --clusterrole=system:openshift:scc:privileged \
      --serviceaccount="${NAMESPACE}:${sa}" \
      -n "$NAMESPACE"
    echo "  ✅ $sa — granted"
  fi
done

echo ""
echo "=== SCC Grants Complete ==="
echo ""
echo "Why 'privileged' SCC is required:"
echo "  - inference-operator: runAsUser=1000, fsGroup=1000 (outside OCP UID range)"
echo "  - inference-operator-api: msi-adapter init runs as root with NET_ADMIN/NET_RAW"
echo "  - telemetry-collector: msi-adapter init runs as root with NET_ADMIN/NET_RAW"
echo "  - model-store: runAsUser=1000, fsGroup=1000"
echo ""
echo "Next: Run ./scripts/04-prep-storage.sh"
