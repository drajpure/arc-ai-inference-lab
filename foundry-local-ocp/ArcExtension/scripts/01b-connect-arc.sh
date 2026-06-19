#!/usr/bin/env bash
# 01b-connect-arc.sh
# Connect an existing OpenShift cluster to Azure Arc.
# Handles the OCP-specific SCC and Helm ownership prerequisites that block
# the default `az connectedk8s connect` flow on OpenShift.
#
# Skip if your cluster is already Arc-connected (check with 00-prerequisites.sh).
#
# References:
# - https://learn.microsoft.com/azure/azure-arc/kubernetes/quickstart-connect-cluster
# - https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

echo "=== Connecting OpenShift cluster to Azure Arc ==="
echo "  Arc RG:       $ARC_RESOURCE_GROUP"
echo "  Arc Name:     $ARC_CLUSTER_NAME"
echo "  Region:       $AZURE_REGION"
echo "  KUBECONFIG:   ${KUBECONFIG:-<unset>}"
echo ""

# Validate tools
for cmd in az oc kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ '$cmd' not found."
    exit 1
  fi
done

# Validate Azure login + RG
if ! az account show &>/dev/null; then
  echo "❌ Not logged into Azure CLI. Run: az login --tenant $AZURE_TENANT_ID"
  exit 1
fi
if ! az group show --name "$ARC_RESOURCE_GROUP" &>/dev/null; then
  echo "❌ Resource group '$ARC_RESOURCE_GROUP' not found."
  echo "   Run: ./scripts/01a-prep-arc-azure.sh first."
  exit 1
fi

# Validate cluster access
if ! oc whoami &>/dev/null; then
  echo "❌ Not logged into OpenShift cluster."
  echo "   Set KUBECONFIG in env.sh or run 'oc login'."
  exit 1
fi

echo "  Logged in as: $(oc whoami)"
echo "  Cluster:      $(oc whoami --show-server)"
echo ""

# Step 1: Pre-create azure-arc namespace with Helm ownership labels
# This is the OCP-specific workaround for the Arc connect Helm ownership issue.
echo "--- Step 1: Pre-create azure-arc namespace with Helm labels ---"
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
echo "✅ azure-arc namespace + SCC ready"

# Step 2: Connect to Arc (idempotent)
echo ""
echo "--- Step 2: Connect to Azure Arc ---"
if az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" &>/dev/null; then
  EXISTING_STATE=$(az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" \
    --query "connectivityStatus" -o tsv 2>/dev/null || echo "Unknown")
  echo "✅ Arc cluster '$ARC_CLUSTER_NAME' already exists (status=$EXISTING_STATE)"
  echo "   To re-onboard: az connectedk8s delete -n $ARC_CLUSTER_NAME -g $ARC_RESOURCE_GROUP --yes"
else
  echo "Connecting..."
  az connectedk8s connect \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$ARC_RESOURCE_GROUP" \
    --location "$AZURE_REGION" \
    --distribution openshift \
    --infrastructure azure
fi

# Step 3: Verify
echo ""
echo "--- Step 3: Verify Arc connection ---"
az connectedk8s show \
  --name "$ARC_CLUSTER_NAME" \
  --resource-group "$ARC_RESOURCE_GROUP" \
  --query "{name:name, connectivityStatus:connectivityStatus, distribution:distribution, kubernetesVersion:kubernetesVersion}" \
  -o table

echo ""
echo "--- Arc agent pods ---"
kubectl get pods -n azure-arc --no-headers | head -10

echo ""
echo "✅ Cluster connected to Azure Arc."
echo ""
echo "Next: Run ./scripts/01-prep-namespace-scc.sh"
