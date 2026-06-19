#!/usr/bin/env bash
# 00-prerequisites.sh
# Verifies all prerequisites for Foundry Local Arc Extension install on OCP.
# Run this first to catch missing tools or configuration early.
#
# NOTE: This is a diagnostic script — it intentionally does NOT use
# set -e so it can report ALL issues instead of exiting on the first one.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../env.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env.sh not found at: $ENV_FILE"
  echo ""
  echo "  Copy env.sh.example to env.sh and fill in your values:"
  echo "  cp ${SCRIPT_DIR}/../env.sh.example ${SCRIPT_DIR}/../env.sh"
  exit 1
fi

# shellcheck source=../env.sh
source "$ENV_FILE"

echo "=== Checking Prerequisites ==="
echo ""

ERRORS=0

# 1. Required CLI tools
echo "--- CLI Tools ---"
for tool in az kubectl oc jq curl; do
  if command -v "$tool" >/dev/null 2>&1; then
    VERSION=""
    case "$tool" in
      az)      VERSION=$(az version 2>/dev/null | head -1) ;;
      jq)      VERSION=$(jq --version 2>/dev/null) ;;
      *)       VERSION=$("$tool" version --client --short 2>/dev/null || "$tool" --version 2>/dev/null | head -1 || echo "installed") ;;
    esac
    echo "  OK $tool: ${VERSION:-installed}"
  else
    echo "  MISSING $tool: NOT FOUND"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""

# 2. Azure CLI login
echo "--- Azure CLI Auth ---"
if AZ_ACCOUNT=$(az account show --query "name" -o tsv 2>/dev/null); then
  echo "  OK Logged in: $AZ_ACCOUNT"
else
  echo "  FAIL Not logged in. Run: az login --tenant $AZURE_TENANT_ID"
  ERRORS=$((ERRORS + 1))
fi

echo ""

# 3. Correct subscription
echo "--- Subscription ---"
if CURRENT_SUB=$(az account show --query "id" -o tsv 2>/dev/null); then
  if [[ "$CURRENT_SUB" == "$AZURE_SUBSCRIPTION_ID" ]]; then
    echo "  OK Active subscription: $AZURE_SUBSCRIPTION_ID"
  else
    echo "  WARN Active: $CURRENT_SUB (expected: $AZURE_SUBSCRIPTION_ID)"
    echo "       Run: az account set --subscription $AZURE_SUBSCRIPTION_ID"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "  FAIL Cannot check subscription (not logged in)"
  ERRORS=$((ERRORS + 1))
fi

echo ""

# 4. kubectl connectivity
echo "--- Kubernetes Connectivity ---"
echo "  KUBECONFIG=$KUBECONFIG"
if kubectl cluster-info >/dev/null 2>&1; then
  SERVER_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || echo "unknown")
  echo "  OK Connected (K8s $SERVER_VERSION)"
else
  echo "  FAIL Cannot reach cluster. Check KUBECONFIG path."
  ERRORS=$((ERRORS + 1))
fi

echo ""

# 5. OCP version
echo "--- OpenShift Version ---"
if OCP_VERSION=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // empty' 2>/dev/null) && [[ -n "$OCP_VERSION" ]]; then
  echo "  OK OpenShift $OCP_VERSION"
else
  echo "  WARN Could not determine OCP version (oc may not be connected)"
fi

echo ""

# 6. Arc connection
echo "--- Azure Arc Status ---"
ARC_CONNECTED=false
if ARC_STATUS=$(az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" --query "connectivityStatus" -o tsv 2>/dev/null); then
  if [[ "$ARC_STATUS" == "Connected" ]]; then
    echo "  OK Arc cluster '$ARC_CLUSTER_NAME' is Connected"
    ARC_CONNECTED=true
  else
    echo "  WARN Arc cluster status: $ARC_STATUS (run ./scripts/01a-prep-arc-azure.sh then 01b-connect-arc.sh)"
  fi
else
  echo "  WARN Arc cluster '$ARC_CLUSTER_NAME' not found — will need ./scripts/01a-prep-arc-azure.sh + 01b-connect-arc.sh"
fi

echo ""

# 7. Required Azure providers
echo "--- Resource Providers ---"
for provider in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation; do
  if STATE=$(az provider show -n "$provider" --query "registrationState" -o tsv 2>/dev/null); then
    if [[ "$STATE" == "Registered" ]]; then
      echo "  OK $provider"
    else
      echo "  WARN $provider: $STATE (run: az provider register -n $provider)"
    fi
  else
    echo "  WARN $provider: could not check (az CLI issue)"
  fi
done

echo ""

# 8. Extension type
echo "--- Extension Type ---"
echo "  Extension type: $EXTENSION_TYPE"
echo "  (Availability verified during install)"

echo ""

# Summary
echo "==========================================="
if [[ $ERRORS -eq 0 ]]; then
  echo "  All prerequisites met"
  echo ""
  if [[ "$ARC_CONNECTED" == "true" ]]; then
    echo "  Next: Run ./scripts/01-prep-namespace-scc.sh"
  else
    echo "  Next: Run ./scripts/01a-prep-arc-azure.sh  (Arc not connected yet)"
  fi
else
  echo "  $ERRORS issue(s) found -- resolve before proceeding"
  exit 1
fi
echo "==========================================="
