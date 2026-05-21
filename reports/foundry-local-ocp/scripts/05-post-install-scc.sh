#!/bin/bash
# 04-post-install-scc.sh
# Grant SCC to ServiceAccounts created by the Helm chart (Phase 2).
# Must run AFTER 03-install-foundry-operator.sh completes.
set -euo pipefail

NAMESPACE="${NAMESPACE:-foundry-local-operator}"

echo "=== Granting SCC to chart-created ServiceAccounts (Phase 2) ==="

# These SAs are created by the Helm chart during install
CHART_SAS=(
  inference-operator
  inference-operator-catalog-sync
)

for sa in "${CHART_SAS[@]}"; do
  if kubectl get sa "${sa}" -n "${NAMESPACE}" &>/dev/null; then
    oc adm policy add-scc-to-user anyuid -z "${sa}" -n "${NAMESPACE}"
    oc adm policy add-scc-to-user privileged -z "${sa}" -n "${NAMESPACE}"
    echo "  ✓ ${sa}"
  else
    echo "  ⚠ ${sa} not found (may not exist in this chart version)"
  fi
done

echo ""
echo "=== Restarting deployments to pick up SCC changes ==="
kubectl rollout restart deployment -n "${NAMESPACE}" 2>/dev/null || true

echo ""
echo "Phase 2 SCC grants complete. All operator pods should now be Running."
echo "Verify with: kubectl get pods -n ${NAMESPACE}"
