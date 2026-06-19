#!/usr/bin/env bash
# 01a-connect-arc.sh
# Connects an OpenShift cluster to Azure Arc (end-to-end).
# Handles Azure-side prep (providers, RG, CLI extensions) AND the OCP-specific
# SCC/Helm ownership workarounds that block the default `az connectedk8s connect`.
#
# Skip if your cluster is already Arc-connected (00-prerequisites.sh will detect this).
#
# References:
# - https://learn.microsoft.com/azure/azure-arc/kubernetes/quickstart-connect-cluster
# - https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

echo "=== Connecting OpenShift Cluster to Azure Arc ==="
echo "  Subscription:  $AZURE_SUBSCRIPTION_ID"
echo "  Arc RG:        $ARC_RESOURCE_GROUP"
echo "  Arc Name:      $ARC_CLUSTER_NAME"
echo "  Region:        $AZURE_REGION"
echo "  KUBECONFIG:    ${KUBECONFIG:-<unset>}"
echo ""

# Validate tools
for cmd in az oc kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found."
    exit 1
  fi
done

# Validate Azure login
if ! az account show &>/dev/null; then
  echo "ERROR: Not logged into Azure CLI. Run: az login --tenant $AZURE_TENANT_ID"
  exit 1
fi

# Validate cluster access
if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged into OpenShift cluster."
  echo "   Set KUBECONFIG in env.sh or run 'oc login'."
  exit 1
fi

echo "  Azure identity: $(az account show --query user.name -o tsv)"
echo "  OCP user:       $(oc whoami)"
echo "  OCP server:     $(oc whoami --show-server)"
echo ""

# Step 1: Set subscription
echo "--- Step 1: Set Azure subscription ---"
CURRENT_SUB=$(az account show --query id -o tsv)
if [[ "$CURRENT_SUB" != "$AZURE_SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
  echo "  Switched to $AZURE_SUBSCRIPTION_ID"
else
  echo "  Already on correct subscription"
fi

# Step 2: Install/update Azure CLI extensions
echo ""
echo "--- Step 2: Install Azure CLI extensions ---"
az extension add --name connectedk8s --upgrade --yes 2>/dev/null || true
az extension add --name k8s-extension --upgrade --yes 2>/dev/null || true
echo "  OK CLI extensions ready"

# Step 3: Register resource providers
echo ""
echo "--- Step 3: Register resource providers ---"
PROVIDERS=(
  "Microsoft.Kubernetes"
  "Microsoft.KubernetesConfiguration"
  "Microsoft.ExtendedLocation"
)
for provider in "${PROVIDERS[@]}"; do
  STATE=$(az provider show -n "$provider" --query "registrationState" -o tsv 2>/dev/null)
  if [[ "$STATE" == "Registered" ]]; then
    echo "  OK $provider (already registered)"
  else
    echo "  Registering $provider..."
    az provider register --namespace "$provider" --wait
    echo "  OK $provider"
  fi
done

# Step 4: Create resource group
echo ""
echo "--- Step 4: Create resource group ---"
if az group show --name "$ARC_RESOURCE_GROUP" &>/dev/null; then
  echo "  OK Resource group '$ARC_RESOURCE_GROUP' already exists"
else
  az group create --name "$ARC_RESOURCE_GROUP" --location "$AZURE_REGION" --output none
  echo "  OK Created '$ARC_RESOURCE_GROUP' in $AZURE_REGION"
fi

# Step 5: Pre-create azure-arc namespace with Helm ownership labels (OCP workaround)
echo ""
echo "--- Step 5: Pre-create azure-arc namespace (OCP workaround) ---"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: azure-arc
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: azure-arc
    meta.helm.sh/release-namespace: azure-arc-release
EOF

# Grant privileged SCC to the AAD proxy SA (required for Arc on OCP)
oc create serviceaccount azure-arc-kube-aad-proxy-sa -n azure-arc --dry-run=client -o yaml | kubectl apply -f -
oc adm policy add-scc-to-user privileged -z azure-arc-kube-aad-proxy-sa -n azure-arc
echo "  OK azure-arc namespace + SCC ready"

# Step 6: Connect to Arc (idempotent)
echo ""
echo "--- Step 6: Connect to Azure Arc ---"
if az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" &>/dev/null; then
  EXISTING_STATE=$(az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" \
    --query "connectivityStatus" -o tsv 2>/dev/null || echo "Unknown")
  echo "  OK Arc cluster '$ARC_CLUSTER_NAME' already exists (status=$EXISTING_STATE)"
else
  echo "  Connecting (this may take 2-3 minutes)..."
  az connectedk8s connect \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$ARC_RESOURCE_GROUP" \
    --location "$AZURE_REGION" \
    --distribution openshift \
    --infrastructure azure
fi

# Step 7: Verify
echo ""
echo "--- Step 7: Verify Arc connection ---"
az connectedk8s show \
  --name "$ARC_CLUSTER_NAME" \
  --resource-group "$ARC_RESOURCE_GROUP" \
  --query "{name:name, connectivityStatus:connectivityStatus, distribution:distribution, kubernetesVersion:kubernetesVersion}" \
  -o table

echo ""
echo "--- Arc agent pods ---"
kubectl get pods -n azure-arc --no-headers | head -10

echo ""
echo "=== Cluster connected to Azure Arc ==="
echo ""
echo "Next: Run ./scripts/01-prep-namespace-scc.sh"
