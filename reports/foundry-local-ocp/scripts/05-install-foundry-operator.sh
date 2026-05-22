#!/bin/bash
# 05-install-foundry-operator.sh
# Install the Foundry Local inference operator via the official OCI Helm chart from MCR.
# Matches exactly the command from the official Foundry Local Helm Installation Guide.
#
# Official chart URI:
#   oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator
#
# The Arc extension type 'microsoft.foundry' is preview-gated, but this Helm chart
# on MCR is publicly accessible without preview approval.
#
# Prereqs (must be completed first):
#   - Cluster is Arc-connected (02-connect-arc.sh)
#   - cert-manager + trust-manager installed (03-install-cert-manager.sh)
#   - Namespace and SCC grants applied (04-prep-namespace-scc.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

NAMESPACE="${NAMESPACE:-foundry-local-operator}"
OPERATOR_VERSION="${OPERATOR_VERSION:-0.260430.8}"
STORAGE_CLASS="${STORAGE_CLASS:-}"  # Empty = cluster default; e.g. "local-storage" if CSI broken

OPERATOR_CHART="oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator"

echo "=== Installing inference-operator v${OPERATOR_VERSION} ==="
echo "  Chart:     ${OPERATOR_CHART}"
echo "  Namespace: ${NAMESPACE}"
echo "  Storage:   ${STORAGE_CLASS:-<cluster default>}"
echo ""

# Base args match the official guide exactly.
HELM_ARGS=(
  "${OPERATOR_CHART}"
  --version "${OPERATOR_VERSION}"
  --namespace "${NAMESPACE}"
  --create-namespace
  --set entraAuth.enabled=false
  --wait
  --timeout 10m
)

# OCP-specific addition: override storage class when default CSI is unusable.
if [[ -n "${STORAGE_CLASS}" ]]; then
  HELM_ARGS+=(--set "global.storage.storageClass=${STORAGE_CLASS}")
fi

helm upgrade --install inference-operator "${HELM_ARGS[@]}"

echo ""
echo "=== Verifying (per official guide Step 3) ==="
kubectl get pods -n "${NAMESPACE}"
echo ""
kubectl get crd | grep foundry || true
echo ""
echo "✓ Inference operator installed. Run 06-post-install-scc.sh next."
