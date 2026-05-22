#!/bin/bash
# 02-prep-namespace-scc.sh
# Prepare the foundry-local-operator namespace with OCP Security Context Constraints.
# This must run BEFORE the Helm install (Phase 1 SCC grants).
set -euo pipefail

NAMESPACE="${NAMESPACE:-foundry-local-operator}"

echo "=== Creating namespace ${NAMESPACE} ==="
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Applying PSS labels (defense in depth) ==="
kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

echo "=== Granting SCC to pre-existing ServiceAccounts (Phase 1) ==="
# These SAs exist before Helm install or are created by namespace controller
for sa in default foundry-config-reader; do
  # Ensure SA exists
  kubectl create serviceaccount "${sa}" -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  oc adm policy add-scc-to-user anyuid -z "${sa}" -n "${NAMESPACE}"
  oc adm policy add-scc-to-user privileged -z "${sa}" -n "${NAMESPACE}"
done

echo ""
echo "Phase 1 SCC grants complete."
echo "Run 03-install-foundry-operator.sh next, then 04-post-install-scc.sh after."
