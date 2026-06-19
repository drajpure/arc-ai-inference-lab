#!/usr/bin/env bash
# 00-prerequisites.sh
# Verifies all prerequisites for Foundry Local Arc Extension install on OCP.
# Run this first to catch missing tools or configuration early.

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found at: $ENV_FILE"
  echo "   Copy env.sh.example to env.sh and fill in your values:"
  echo "   cp $(dirname "$ENV_FILE")/env.sh.example $(dirname "$ENV_FILE")/env.sh"
  exit 1
fi
source "$ENV_FILE"

echo "=== Checking Prerequisites ==="
echo ""

ERRORS=0

# 1. Required CLI tools
echo "--- CLI Tools ---"
for tool in az kubectl oc jq curl; do
  if command -v "$tool" &>/dev/null; then
    VERSION=$("$tool" --version 2>&1 | head -1 || echo "installed")
    echo "  ✅ $tool: $VERSION"
  else
    echo "  ❌ $tool: NOT FOUND"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""

# 2. Azure CLI login
echo "--- Azure CLI Auth ---"
AZ_ACCOUNT=$(az account show --query "{sub:id, tenant:tenantId, name:name}" -o tsv 2>/dev/null || true)
if [[ -n "$AZ_ACCOUNT" ]]; then
  echo "  ✅ Logged in: $AZ_ACCOUNT"
else
  echo "  ❌ Not logged in. Run: az login --tenant $TENANT_ID"
  ERRORS=$((ERRORS + 1))
fi

echo ""

# 3. Correct subscription
echo "--- Subscription ---"
CURRENT_SUB=$(az account show --query "id" -o tsv 2>/dev/null || true)
if [[ "$CURRENT_SUB" == "$SUBSCRIPTION_ID" ]]; then
  echo "  ✅ Active subscription: $SUBSCRIPTION_ID"
else
  echo "  ⚠️  Active subscription: $CURRENT_SUB"
  echo "     Expected: $SUBSCRIPTION_ID"
  echo "     Run: az account set --subscription $SUBSCRIPTION_ID"
  ERRORS=$((ERRORS + 1))
fi

echo ""

# 4. kubectl connectivity
echo "--- Kubernetes Connectivity ---"
if kubectl cluster-info &>/dev/null; then
  SERVER_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' || echo "unknown")
  echo "  ✅ Connected (K8s $SERVER_VERSION)"
else
  echo "  ❌ Cannot reach cluster. Check KUBECONFIG."
  ERRORS=$((ERRORS + 1))
fi

echo ""

# 5. OCP version
echo "--- OpenShift Version ---"
OCP_VERSION=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$OCP_VERSION" != "unknown" ]]; then
  echo "  ✅ OpenShift $OCP_VERSION"
else
  echo "  ⚠️  Could not determine OCP version (oc may not be connected)"
fi

echo ""

# 6. Arc connection
echo "--- Azure Arc Status ---"
ARC_STATUS=$(az connectedk8s show \
  -n "$ARC_CLUSTER_NAME" \
  -g "$ARC_RESOURCE_GROUP" \
  --query "connectivityStatus" -o tsv 2>/dev/null || echo "NotFound")

if [[ "$ARC_STATUS" == "Connected" ]]; then
  echo "  ✅ Arc cluster '$ARC_CLUSTER_NAME' is Connected"
else
  echo "  ❌ Arc cluster status: $ARC_STATUS"
  echo "     Ensure cluster is Arc-connected."
  ERRORS=$((ERRORS + 1))
fi

echo ""

# 7. Required Azure providers
echo "--- Resource Providers ---"
PROVIDERS=("Microsoft.Kubernetes" "Microsoft.KubernetesConfiguration" "Microsoft.ExtendedLocation")
for provider in "${PROVIDERS[@]}"; do
  STATE=$(az provider show -n "$provider" --query "registrationState" -o tsv 2>/dev/null)
  if [[ "$STATE" == "Registered" ]]; then
    echo "  ✅ $provider"
  else
    echo "  ⚠️  $provider: $STATE (run: az provider register -n $provider)"
  fi
done

echo ""

# 8. Extension type availability
echo "--- Extension Type ---"
echo "  Extension type: $EXTENSION_TYPE"
echo "  (Availability can only be verified by attempting install)"

echo ""

# Summary
if [[ $ERRORS -eq 0 ]]; then
  echo "=== ✅ All prerequisites met ==="
  echo ""
  echo "Next: Run 01-prep-namespace-scc.sh"
else
  echo "=== ❌ $ERRORS issue(s) found — resolve before proceeding ==="
  exit 1
fi
