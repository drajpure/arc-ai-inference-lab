# Provision Self-Hosted OpenShift (OCP) on Azure

Automated provisioning of a self-hosted OpenShift cluster on Azure using IPI (Installer-Provisioned Infrastructure). This is a **shared prerequisite** — provision once, then install Foundry Local via either [Arc Extension](../arc-extension/) or [Helm Standalone](../helm-standalone/).

> **Already have an OCP cluster?** Skip this entirely and go to your chosen install method.

## Quick Check

```bash
# If any of these succeed, you already have a cluster:
oc whoami --show-server                              # Returns your OCP API URL
oc get nodes                                         # Returns 3+ nodes
```

## Prerequisites

| Requirement | How to obtain |
|-------------|---------------|
| Subscription with **Contributor + User Access Administrator** (or Owner) | Existing Azure subscription |
| Azure quota: ≥ **24 vCPU** of `Standard_D8s_v3` in your region | `az vm list-usage -l <region> -o table` |
| **Azure DNS zone** matching `${BASE_DOMAIN}` (e.g., `example.com`) | `az network dns zone create -g <rg> -n example.com` |
| **Red Hat pull secret** | Download from https://console.redhat.com/openshift/install/azure/installer-provisioned |
| **Azure service principal** with VM/network/DNS create permissions | `az ad sp create-for-rbac --role Contributor --scopes /subscriptions/<sub-id>` |
| `openshift-install` binary on `PATH` | https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/ |
| `az`, `oc`, `jq` on `PATH` | See tools links below |

**Tool downloads:**
- `oc` + `openshift-install`: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/
- `az` CLI: https://learn.microsoft.com/cli/azure/install-azure-cli

## Usage

```bash
cd provision-ocp

# Configure environment (set CLUSTER_NAME, BASE_DOMAIN, etc.)
# Use the env.sh from your chosen install method, or set vars directly:
export CLUSTER_NAME="ocp-foundry-test"
export BASE_DOMAIN="example.com"
export OCP_RESOURCE_GROUP="rg-ocp-dns"
export PULL_SECRET_FILE=".pull-secret.txt"
export INSTALL_DIR="./install-dir"
export AZURE_REGION="eastus"

# Provision (~45 min)
./scripts/00-provision-ocp.sh
```

## What It Does

1. Creates the **DNS resource group** (`${OCP_RESOURCE_GROUP}`, default `rg-ocp-dns`)
2. Generates `install-config.yaml` from your env vars + pull secret
3. Runs `openshift-install create cluster` — takes ~45 minutes

## On Completion

Capture the kubeconfig, then proceed to your chosen install method:

```bash
export KUBECONFIG="$(pwd)/install-dir/auth/kubeconfig"
oc get nodes
oc get clusterversion
```

**Next steps:**
- [Arc Extension install →](../arc-extension/) (recommended)
- [Helm Standalone install →](../helm-standalone/)

## Idempotency

The script detects existing install state (`${INSTALL_DIR}/metadata.json` + `auth/kubeconfig`) and **skips** `openshift-install create cluster` if a cluster already exists. To force a fresh install:

```bash
openshift-install destroy cluster --dir=./install-dir
rm -rf ./install-dir
./scripts/00-provision-ocp.sh
```

## Resource Groups Created

| RG | Created by | Purpose |
|----|------------|---------|
| `${OCP_RESOURCE_GROUP}` (default: `rg-ocp-dns`) | This script | Azure DNS zone for `${BASE_DOMAIN}` |
| `${CLUSTER_NAME}-<infraID>-rg` | `openshift-install` | VMs, networking, load balancers |
