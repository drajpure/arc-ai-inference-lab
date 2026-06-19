#!/usr/bin/env bash
# 01a-prep-arc-azure.sh
# Azure-side preparation for Arc onboarding. Does NOT touch the OCP cluster.
#
# Creates:
#   - The resource group that will hold the Arc connectedCluster resource
#   - Registers the resource providers required for Arc + extensions
#   - Installs/updates the connectedk8s and k8s-extension az CLI extensions
#
# Run this once per Azure subscription / region. Safe to re-run.
# Skip if your cluster is already Arc-connected (check with 00-prerequisites.sh).

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

echo "=== Arc Azure-side Preparation ==="
echo "  Subscription:     $SUBSCRIPTION_ID"
echo "  Arc RG:           $ARC_RESOURCE_GROUP"
echo "  Region:           $AZURE_REGION"
echo ""

# Validate Azure login
if ! az account show &>/dev/null; then
  echo "❌ Not logged into Azure CLI. Run: az login --tenant $TENANT_ID"
  exit 1
fi

# Set subscription
CURRENT_SUB=$(az account show --query id -o tsv)
if [[ "$CURRENT_SUB" != "$SUBSCRIPTION_ID" ]]; then
  echo "Setting subscription to $SUBSCRIPTION_ID..."
  az account set --subscription "$SUBSCRIPTION_ID"
fi

# Step 1: Install/update Azure CLI extensions
echo "--- Step 1: Install Azure CLI extensions ---"
az extension add --name connectedk8s --upgrade --yes 2>/dev/null || true
az extension add --name k8s-extension --upgrade --yes 2>/dev/null || true
echo "✅ CLI extensions ready"

# Step 2: Register resource providers
echo ""
echo "--- Step 2: Register resource providers ---"
PROVIDERS=(
  "Microsoft.Kubernetes"
  "Microsoft.KubernetesConfiguration"
  "Microsoft.ExtendedLocation"
)
for provider in "${PROVIDERS[@]}"; do
  STATE=$(az provider show -n "$provider" --query "registrationState" -o tsv 2>/dev/null)
  if [[ "$STATE" == "Registered" ]]; then
    echo "  ✅ $provider (already registered)"
  else
    echo "  ⏳ Registering $provider..."
    az provider register --namespace "$provider" --wait
    echo "  ✅ $provider"
  fi
done

# Step 3: Create resource group
echo ""
echo "--- Step 3: Create resource group ---"
if az group show --name "$ARC_RESOURCE_GROUP" &>/dev/null; then
  echo "  ✅ Resource group '$ARC_RESOURCE_GROUP' already exists"
else
  az group create --name "$ARC_RESOURCE_GROUP" --location "$AZURE_REGION" --output none
  echo "  ✅ Created '$ARC_RESOURCE_GROUP' in $AZURE_REGION"
fi

echo ""
echo "=== Azure-side prep complete ==="
echo ""
echo "Next: Run 01b-connect-arc.sh (requires KUBECONFIG to your OCP cluster)"
