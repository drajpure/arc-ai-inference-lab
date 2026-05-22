# Foundry Local on Self-Hosted OpenShift (UPI) — Step-by-Step Guide

This directory contains everything needed to deploy an OpenShift cluster on Azure, connect it to Azure Arc, install Foundry Local, and validate end-to-end inference.

## Prerequisites

### Tools Required

| Tool | Version | Purpose |
|------|---------|---------|
| `az` | ≥ 2.64 | Azure CLI for resource management |
| `oc` | ≥ 4.14 | OpenShift CLI (SCC management, cluster admin) |
| `kubectl` | ≥ 1.29 | Kubernetes operations |
| `helm` | ≥ 3.14 | Chart installations |
| `openshift-install` | ≥ 4.14 | OCP cluster provisioning (UPI/IPI) |
| `jq` | any | JSON processing |
| `curl` | any | API testing |

### Downloads

- **oc + openshift-install**: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/
- **helm**: https://github.com/helm/helm/releases
- **az CLI**: https://learn.microsoft.com/cli/azure/install-azure-cli

### Azure Requirements

| Requirement | Details |
|-------------|---------|
| Subscription | With Contributor + User Access Administrator (or Owner) |
| Quota | ≥ 24 vCPU of Standard_D8s_v3 (3 master/worker nodes) |
| Region | A [Foundry Local supported region](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/what-is-foundry-local-on-azure-local#supported-regions) |
| DNS Zone | Azure DNS zone for cluster base domain (or manual DNS) |
| Red Hat Pull Secret | Download from https://console.redhat.com/openshift/install/azure/installer-provisioned |
| Service Principal | With permissions to create VMs, networking, DNS records |

### Foundry Local Access

- Submit access request: https://aka.ms/FoundryLocalAzure_PreviewRequest
- Note: The Helm chart on MCR is publicly accessible even without preview approval

---

## Before You Start: Authenticate & Configure

Run these steps **once** before invoking any script. All scripts assume `az`, `oc`, and `helm` can already talk to Azure and your cluster.

### 1. Verify tools are on `PATH`

```bash
which az oc kubectl helm jq curl       # all must resolve
az version
oc version --client
helm version --short
```

If a tool isn't on `PATH`, prepend it (Git Bash example for tools at `Q:\tmp\...`):

```bash
export PATH="/q/tmp/helm/windows-amd64:/q/tmp/oc:$PATH"
```

### 2. Authenticate to Azure

```bash
az login                                          # browser/device-code flow
az account set --subscription "<SUBSCRIPTION_ID>" # pick your target subscription
az account show -o table                          # confirm the active subscription
```

If you have multiple tenants, force-pick the right one:

```bash
az login --tenant <TENANT_ID>
```

> Trouble? See the [Azure CLI extension permissions issue](#azure-cli-extension-permissions-on-windows) in Troubleshooting.

### 3. Authenticate to your OpenShift cluster

**Option A — you already have a kubeconfig file** (e.g., from someone else, or from a prior `openshift-install` run):

```bash
export KUBECONFIG=/path/to/kubeconfig.yaml
oc whoami                                         # should print 'system:admin' or your user
oc get nodes
```

**Option B — log in interactively** with an OpenShift API URL + token:

```bash
oc login --server=https://api.<cluster-domain>:6443 --token=<bearer-token>
# Or username/password:
oc login --server=https://api.<cluster-domain>:6443 -u <user> -p <password>
```

The token can be copied from `Copy login command` in the OpenShift web console.

### 4. Configure environment variables

```bash
cd reports/foundry-local-ocp
cp env.sh.example env.sh
# Edit env.sh — at minimum set:
#   AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID, AZURE_REGION
#   ARC_RESOURCE_GROUP, ARC_CLUSTER_NAME
#   KUBECONFIG (path to your OCP kubeconfig)
#   DEPLOYMENT_NAME (must match your existing ModelDeployment if re-running on a live cluster)
source env.sh
```

### 5. Sanity check before running scripts

```bash
az account show --query "{sub:name, tenant:tenantId}" -o table
oc whoami && oc get nodes
helm list -A 2>/dev/null | head -5
```

If all three commands return data without errors, you're ready to run `./scripts/01-prep-arc-azure.sh` (or `00-provision-ocp.sh` if you need to create the cluster first).

---

## Execution Flow

The scripts are grouped into three logical stages:

1. **Stage A — OCP cluster** (script `00`): create the OpenShift cluster. Pure OCP, no Arc.
2. **Stage B — Arc onboarding** (scripts `01`–`02`): Azure-side prep, then connect cluster to Arc.
3. **Stage C — Foundry Local** (scripts `03`–`08`): install operator, deploy a model, run tests.

```
┌─ Stage A: OCP Cluster ──────────────────────────────────┐
│  00-provision-ocp.sh                                    │
│    • Creates DNS resource group (${OCP_RESOURCE_GROUP}) │
│    • Runs openshift-install (IPI) → cluster + kubeconfig│
│    (~45 min)  — skip if you already have a cluster      │
└──────────────────────────┬──────────────────────────────┘
                           │
┌─ Stage B: Azure Arc Onboarding ─────────────────────────┐
│  01-prep-arc-azure.sh   (Azure-side, no cluster access) │
│    • Creates Arc RG (${ARC_RESOURCE_GROUP})             │
│    • Registers Microsoft.Kubernetes / .Configuration /  │
│      .ExtendedLocation providers                        │
│    • Installs az connectedk8s + k8s-extension           │
│    (~3 min)                                             │
│                                                         │
│  02-connect-arc.sh      (needs KUBECONFIG + Azure)      │
│    • Pre-creates azure-arc namespace with SCC + Helm    │
│      ownership labels (OCP workaround)                  │
│    • az connectedk8s connect --distribution openshift   │
│    (~5 min)                                             │
└──────────────────────────┬──────────────────────────────┘
                           │
┌─ Stage C: Foundry Local ────────────────────────────────┐
│  03-install-cert-manager.sh      cert-manager + trust   │
│  04-prep-namespace-scc.sh        Phase 1 SCC grants     │
│  05-install-foundry-operator.sh  Helm install operator  │
│  06-post-install-scc.sh          Phase 2 SCC grants     │
│  07-deploy-and-validate.sh       Deploy model + test    │
│  08-e2e-tests.sh                 Full E2E suite         │
│  (~10 min total)                                        │
└──────────────────────────┬──────────────────────────────┘
                           │
┌─ Stage D (optional): Entra ID Authentication ───────────┐
│  09-configure-entra-auth.sh                             │
│    • Registers Entra app (single-tenant)                │
│    • Exposes 'foundry_access' delegated scope           │
│    • Forces v2.0 tokens (accessTokenAcceptedVersion=2)  │
│    • Pre-authorizes Azure CLI as known client           │
│    • Assigns user/group RBAC role on cluster            │
│    • Grants Arc cluster identity 'Cognitive Services    │
│      OpenAI User' (REQUIRED for RBAC checks to work)    │
│    Then re-install operator with entraAuth.enabled=true │
│    (~3 min)                                             │
└─────────────────────────────────────────────────────────┘
```

**Total time: ~60–70 minutes** (mostly OCP provisioning)

---

## Quick Start (Existing OCP Cluster)

If you already have an OCP cluster, skip `00` and start from `01`:

```bash
cp env.sh.example env.sh
# Edit env.sh — set KUBECONFIG, ARC_RESOURCE_GROUP, ARC_CLUSTER_NAME, AZURE_REGION
source env.sh

./scripts/01-prep-arc-azure.sh        # Azure-side prep
./scripts/02-connect-arc.sh           # Connect cluster to Arc

./scripts/03-install-cert-manager.sh
./scripts/04-prep-namespace-scc.sh
./scripts/05-install-foundry-operator.sh
./scripts/06-post-install-scc.sh
./scripts/07-deploy-and-validate.sh
./scripts/08-e2e-tests.sh
```

If Arc is **also** already connected, skip `01` and `02` as well.

---

## Resource Group Layout

Two distinct resource groups are used, kept separate so OCP infra and Arc onboarding can be managed independently:

| Variable | Default | Created by | Purpose |
|----------|---------|------------|---------|
| `OCP_RESOURCE_GROUP` | `rg-ocp-dns` | `00-provision-ocp.sh` | Holds the Azure DNS zone for `${BASE_DOMAIN}` (IPI requirement). Compute/network goes into a separate installer-created infra RG `${CLUSTER_NAME}-<infraID>-rg`. |
| `ARC_RESOURCE_GROUP` | `rg-ocp-foundry-arc` | `01-prep-arc-azure.sh` | Holds the Arc `connectedCluster` resource. Can equal `OCP_RESOURCE_GROUP` if you prefer a single RG. |

---

## Directory Layout

```
reports/foundry-local-ocp/
├── README.md                          # This file
├── validation-report.md               # Full validation report with findings
├── scripts/
│   ├── 00-provision-ocp.sh            # [A] Provision OCP on Azure (IPI)
│   ├── 01-prep-arc-azure.sh           # [B] Azure-side Arc prep (RG, providers, az ext)
│   ├── 02-connect-arc.sh              # [B] Connect OCP cluster to Arc
│   ├── 03-install-cert-manager.sh     # [C] cert-manager + trust-manager
│   ├── 04-prep-namespace-scc.sh       # [C] Namespace + Phase 1 SCC grants
│   ├── 05-install-foundry-operator.sh # [C] Helm install inference operator
│   ├── 06-post-install-scc.sh         # [C] Phase 2 SCC grants
│   ├── 07-deploy-and-validate.sh      # [C] Deploy model + single inference test
│   ├── 08-e2e-tests.sh                # [C] Full E2E test suite with report
│   └── 09-configure-entra-auth.sh     # [D] (optional) Entra ID app + RBAC for token-based auth
├── manifests/
│   ├── local-storage-class.yaml       # Workaround: local StorageClass
│   ├── local-pv.yaml                  # Workaround: hostPath PV
│   ├── create-model-dir-pod.yaml      # Workaround: create dir on node
│   └── sample-model-deployment.yaml   # Example ModelDeployment CR
└── env.sh.example                     # Environment variables template
```

---

## Idempotency / Re-run Safety

All scripts are safe to re-run. The table below summarizes how each script handles pre-existing state:

| Script | Re-run behavior |
|--------|-----------------|
| `00-provision-ocp.sh` | RG: `az group create` is idempotent. Cluster: detects existing `${INSTALL_DIR}/metadata.json` + `auth/kubeconfig` and **skips** `openshift-install` with a clear message. To force a fresh install, run `openshift-install destroy cluster --dir=...` first. |
| `01-prep-arc-azure.sh` | Fully idempotent: `az extension add --upgrade`, `az provider register`, and `az group create` all no-op when already in the desired state. |
| `02-connect-arc.sh` | Namespace, SA, and SCC grants use `kubectl apply` / `oc adm policy add-scc-to-user` (idempotent). `az connectedk8s connect` is **guarded** — if the connectedCluster already exists, the call is skipped with its current status reported. |
| `03-install-cert-manager.sh` | `helm upgrade --install` for both charts — re-runs reconcile to the same state. Includes explicit `kubectl wait` before installing trust-manager. |
| `04-prep-namespace-scc.sh` | All `kubectl apply` and `oc adm policy` calls are idempotent. |
| `05-install-foundry-operator.sh` | `helm upgrade --install` — re-runs reconcile. |
| `06-post-install-scc.sh` | Skips SAs that don't exist yet (warns instead of failing). `kubectl rollout restart` is idempotent. |
| `07-deploy-and-validate.sh` | `kubectl apply` for the ModelDeployment is idempotent. Port-forward is cleaned up at end. |
| `08-e2e-tests.sh` | Read-only against the deployed model. Has a `trap` cleanup for port-forward. |
| `09-configure-entra-auth.sh` | Looks up existing Entra app by name and reuses it. Scope, pre-auth client, and RBAC role assignments all check for existence before creating. |

**Safe re-run patterns:**

```bash
# Re-run any single script — picks up from current state
./scripts/03-install-cert-manager.sh   # → upgrades or installs as needed

# Re-run from a specific point onward
for s in scripts/03-* scripts/04-* scripts/05-*; do bash "$s"; done

# Force a clean install (destructive — only for OCP infra)
openshift-install destroy cluster --dir=./install-dir
rm -rf ./install-dir
./scripts/00-provision-ocp.sh
```

**One non-idempotent operation** that the scripts deliberately do NOT guard:
`helm uninstall` — none of the scripts uninstall anything. Cleanup is left to the operator.

---



| Symptom | Cause | Fix |
|---------|-------|-----|
| Helm pre-install Job stuck in `Pending` | Missing SCC grants on `default` SA | Run `04-prep-namespace-scc.sh` before install |
| PVC stuck in `Pending` | CSI driver broken or wrong StorageClass | Use `local-storage` workaround (see manifests/) |
| `telemetry-collector` CrashLoop | Needs `privileged` SCC for NET_ADMIN caps | Run `06-post-install-scc.sh` |
| Model not found in catalog | Wrong alias (docs examples are outdated) | Query catalog: `kubectl get cm foundry-local-catalog -n foundry-local-operator -o jsonpath='{.data.catalog\.json}' \| jq '.models[].alias'` |
| Arc extension type fails | Preview-gated; not available in your subscription | Use Helm chart directly (script 05 does this) |
| cert-manager Arc extension fails | CRI-O incompatible images + deprecated seccomp | Use upstream Jetstack charts (script 03 does this) |
| `02-connect-arc.sh` fails with "resource group not found" | Skipped `01-prep-arc-azure.sh` | Run `01` first — it creates `${ARC_RESOURCE_GROUP}` |

### Azure CLI extension permissions on Windows

Symptom (typically when running `02-connect-arc.sh` or any `az connectedk8s ...` command):

```
[WinError 5] Access is denied: 'C:\Users\<you>\.azure\cliextensions\connectedk8s\connectedk8s-<ver>.dist-info'
```

Cause: the `connectedk8s` extension was installed under a different process/user (e.g., elevated shell, OneDrive-synced `.azure` folder, or a different Python install), so the current `az` process can't read its metadata.

Fix (in an **elevated PowerShell**, after closing all bash/az windows):

```powershell
$ext = "$env:USERPROFILE\.azure\cliextensions"
takeown /F $ext /R /D Y
icacls $ext /grant "${env:USERNAME}:(OI)(CI)F" /T
Remove-Item -Recurse -Force "$env:USERPROFILE\.azure\cliextensions\connectedk8s"
```

Then back in a **normal** (non-elevated) Git Bash:

```bash
az extension add --name connectedk8s
az extension add --name k8s-extension
az extension list -o table     # confirm both listed
```

If `.azure` is inside a OneDrive-synced folder, move it off OneDrive permanently:

```bash
export AZURE_CONFIG_DIR="/c/az-config"
mkdir -p "$AZURE_CONFIG_DIR"
az login
```

Add `export AZURE_CONFIG_DIR="/c/az-config"` to your `env.sh` so it sticks across shells.

---

## References

- [Deploy Foundry Local Arc Extension](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension)
- [What is Foundry Local](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/what-is-foundry-local-on-azure-local)
- [Configure Authentication (Entra ID + RBAC)](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/how-to-configure-authentication)
- [Authentication and Authorization concepts](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/concept-authentication-authorization)
- [Azure Arc on OpenShift Troubleshooting](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc)
- [OpenShift Install on Azure (IPI)](https://docs.openshift.com/container-platform/latest/installing/installing_azure/ipi/installing-azure-default.html)
