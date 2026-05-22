#!/bin/bash
# 03-install-foundry-operator.sh
# Install the Foundry Local inference operator via public Helm chart from MCR.
# The Arc extension type (microsoft.foundry) is preview-gated; this chart is public.
set -euo pipefail

NAMESPACE="${NAMESPACE:-foundry-local-operator}"
OPERATOR_VERSION="${OPERATOR_VERSION:-0.260430.8}"
STORAGE_CLASS="${STORAGE_CLASS:-}"  # Empty = cluster default

echo "=== Installing inference-operator v${OPERATOR_VERSION} ==="

HELM_ARGS=(
  oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator
  --version "${OPERATOR_VERSION}"
  --namespace "${NAMESPACE}"
  --set entraAuth.enabled=false
  --timeout 10m
  --wait
)

# If a storage class is specified, override the default
if [[ -n "${STORAGE_CLASS}" ]]; then
  HELM_ARGS+=(--set "global.storage.storageClass=${STORAGE_CLASS}")
  echo "  Using StorageClass: ${STORAGE_CLASS}"
fi

helm install inference-operator "${HELM_ARGS[@]}"

echo ""
echo "=== Verifying ==="
kubectl get pods -n "${NAMESPACE}"
echo ""
kubectl get crd | grep foundry
echo ""
echo "Inference operator installed. Run 04-post-install-scc.sh next."
