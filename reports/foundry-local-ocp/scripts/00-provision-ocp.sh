#!/bin/bash
# 00-provision-ocp.sh
# Provision a self-hosted OpenShift cluster on Azure using IPI (Installer-Provisioned Infrastructure).
# Requires: openshift-install, az CLI, Red Hat pull secret, service principal.
#
# This creates a 3-node cluster (master+worker combo) suitable for Foundry Local testing.
# For production, separate master and worker nodes are recommended.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

# Defaults
CLUSTER_NAME="${CLUSTER_NAME:-ocp-foundry-test}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
AZURE_REGION="${AZURE_REGION:-eastus}"
OCP_RESOURCE_GROUP="${OCP_RESOURCE_GROUP:-rg-ocp-dns}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-.pull-secret.txt}"
INSTALL_DIR="${INSTALL_DIR:-./install-dir}"

echo "=== OpenShift IPI Install on Azure ==="
echo "  Cluster:        ${CLUSTER_NAME}"
echo "  Base Domain:    ${BASE_DOMAIN}"
echo "  Region:         ${AZURE_REGION}"
echo "  OCP DNS RG:     ${OCP_RESOURCE_GROUP}  (holds the DNS zone for ${BASE_DOMAIN})"
echo ""
echo "  NOTE: openshift-install will create a SEPARATE infra RG named"
echo "        '${CLUSTER_NAME}-<infraID>-rg' that holds the actual VMs/networking."
echo "        Arc onboarding is a separate step — see 01-prep-arc-azure.sh."
echo ""

# Validate tools
for cmd in openshift-install az jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '${cmd}' not found. Please install it first." >&2
    exit 1
  fi
done

# Validate pull secret
if [[ ! -f "${PULL_SECRET_FILE}" ]]; then
  echo "ERROR: Pull secret not found at ${PULL_SECRET_FILE}" >&2
  echo "Download from: https://console.redhat.com/openshift/install/azure/installer-provisioned" >&2
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

# Create the DNS base-domain resource group (IPI requirement).
# This RG must contain an Azure DNS zone matching ${BASE_DOMAIN} for the installer
# to register cluster DNS records. The cluster's compute/network resources go into
# a separate infra RG created by openshift-install.
echo "=== Creating DNS resource group ==="
az group create --name "${OCP_RESOURCE_GROUP}" --location "${AZURE_REGION}" --output none

# Create install-config.yaml
echo "=== Generating install-config.yaml ==="
mkdir -p "${INSTALL_DIR}"

PULL_SECRET=$(cat "${PULL_SECRET_FILE}")

cat > "${INSTALL_DIR}/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  azure:
    baseDomainResourceGroupName: ${OCP_RESOURCE_GROUP}
    region: ${AZURE_REGION}
    cloudName: AzurePublicCloud
compute:
  - name: worker
    replicas: 0
controlPlane:
  name: master
  replicas: 3
  platform:
    azure:
      type: Standard_D8s_v3
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
pullSecret: '${PULL_SECRET}'
EOF

echo "  install-config.yaml written to ${INSTALL_DIR}/"
echo ""
echo "=== Starting cluster creation ==="
echo "  This will take approximately 30-45 minutes..."
echo ""

# Run the installer
openshift-install create cluster --dir="${INSTALL_DIR}" --log-level=info

echo ""
echo "=== Cluster creation complete ==="
echo ""
echo "Kubeconfig: ${INSTALL_DIR}/auth/kubeconfig"
echo "kubeadmin password: $(cat ${INSTALL_DIR}/auth/kubeadmin-password)"
echo ""
echo "Copy kubeconfig:"
echo "  cp ${INSTALL_DIR}/auth/kubeconfig ./kubeconfig"
echo "  export KUBECONFIG=./kubeconfig"
echo ""
echo "Verify:"
echo "  oc get nodes"
echo "  oc get clusterversion"
echo ""
echo "Next steps:"
echo "  1. ./scripts/01-prep-arc-azure.sh   # Create Arc RG, register providers (Azure-side)"
echo "  2. ./scripts/02-connect-arc.sh      # Onboard this cluster to Arc"
