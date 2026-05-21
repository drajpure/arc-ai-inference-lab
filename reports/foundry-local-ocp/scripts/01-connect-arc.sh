#!/bin/bash
# 01-connect-arc.sh
# Connect an existing OpenShift cluster to Azure Arc.
# Handles the OCP-specific SCC and Helm ownership prerequisites.
#
# References:
# - https://learn.microsoft.com/azure/azure-arc/kubernetes/quickstart-connect-cluster
# - https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ocp-foundry}"
ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:-ocp-foundry-arc}"
AZURE_REGION="${AZURE_REGION:-eastus}"

echo "=== Connecting OpenShift cluster to Azure Arc ==="
echo "  Resource Group: ${RESOURCE_GROUP}"
echo "  Arc Name:       ${ARC_CLUSTER_NAME}"
echo "  Region:         ${AZURE_REGION}"
echo ""

# Validate tools
for cmd in az oc kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '${cmd}' not found." >&2
    exit 1
  fi
done

# Validate cluster access
if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged into OpenShift cluster. Set KUBECONFIG or run 'oc login'." >&2
  exit 1
fi

echo "  Logged in as: $(oc whoami)"
echo "  Cluster: $(oc whoami --show-server)"
echo ""

# Step 1: Install/update Azure CLI extensions
echo "=== Installing Azure CLI extensions ==="
az extension add --name connectedk8s --upgrade --yes 2>/dev/null || true
az extension add --name k8s-extension --upgrade --yes 2>/dev/null || true

# Step 2: Register resource providers
echo "=== Registering resource providers ==="
az provider register --namespace Microsoft.Kubernetes --wait 2>/dev/null || true
az provider register --namespace Microsoft.KubernetesConfiguration --wait 2>/dev/null || true
az provider register --namespace Microsoft.ExtendedLocation --wait 2>/dev/null || true

# Step 3: Pre-create azure-arc namespace with SCC and Helm ownership labels
# This is the OCP-specific workaround for the Arc connect Helm ownership issue.
echo "=== Pre-creating azure-arc namespace with SCC + Helm labels ==="

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

# Grant privileged SCC to the AAD proxy SA (required for Arc on OpenShift)
oc create serviceaccount azure-arc-kube-aad-proxy-sa -n azure-arc --dry-run=client -o yaml | kubectl apply -f -
oc adm policy add-scc-to-user privileged -z azure-arc-kube-aad-proxy-sa -n azure-arc

echo ""
echo "=== Connecting cluster to Azure Arc ==="
az connectedk8s connect \
  --name "${ARC_CLUSTER_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${AZURE_REGION}" \
  --distribution openshift \
  --infrastructure azure

echo ""
echo "=== Verifying Arc connection ==="
az connectedk8s show \
  --name "${ARC_CLUSTER_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query "{name:name, connectivityStatus:connectivityStatus, distribution:distribution, kubernetesVersion:kubernetesVersion}" \
  -o table

echo ""
echo "=== Arc agent pods ==="
kubectl get pods -n azure-arc

echo ""
echo "✓ Cluster connected to Azure Arc successfully."
