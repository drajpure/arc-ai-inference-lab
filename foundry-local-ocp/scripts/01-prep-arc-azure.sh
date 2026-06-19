#!/bin/bash
# 01-prep-arc-azure.sh
# Azure-side preparation for Arc onboarding. Does NOT touch the OCP cluster.
#
# Creates:
#   - The resource group that will hold the Arc connectedCluster resource
#   - Registers the resource providers required for Arc + extensions
#   - Installs/updates the connectedk8s and k8s-extension az CLI extensions
#
# Run this once per Azure subscription / region. Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

ARC_RESOURCE_GROUP="${ARC_RESOURCE_GROUP:-rg-ocp-foundry-arc}"
AZURE_REGION="${AZURE_REGION:-eastus}"

echo "=== Arc Azure-side preparation ==="
echo "  Arc Resource Group: ${ARC_RESOURCE_GROUP}"
echo "  Region:             ${AZURE_REGION}"
echo ""

# Validate tools
if ! command -v az &>/dev/null; then
  echo "ERROR: 'az' CLI not found." >&2
  exit 1
fi

# Validate Azure login
if ! az account show &>/dev/null; then
  echo "ERROR: Not logged into Azure CLI. Run 'az login' first." >&2
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo "  Subscription: ${SUBSCRIPTION_ID}"
echo ""

# Step 1: Install/update Azure CLI extensions
echo "=== Installing Azure CLI extensions ==="
az extension add --name connectedk8s --upgrade --yes 2>/dev/null || true
az extension add --name k8s-extension --upgrade --yes 2>/dev/null || true

# Step 2: Register resource providers (idempotent; --wait blocks until Registered)
echo "=== Registering resource providers ==="
for ns in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation; do
  echo "  Registering ${ns}..."
  az provider register --namespace "${ns}" --wait 2>/dev/null || true
done

# Step 3: Create the Arc resource group (idempotent)
echo "=== Creating Arc resource group ==="
az group create \
  --name "${ARC_RESOURCE_GROUP}" \
  --location "${AZURE_REGION}" \
  --output none

echo ""
echo "✓ Azure-side Arc prep complete."
echo ""
echo "Next step: ./scripts/02-connect-arc.sh (requires KUBECONFIG to your OCP cluster)"
