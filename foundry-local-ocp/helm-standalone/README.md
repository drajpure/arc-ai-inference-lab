# Foundry Local on Self-Hosted OpenShift (UPI) — Step-by-Step Guide

This directory contains everything needed to deploy a self-hosted OpenShift (OCP) cluster on Azure, connect it to Azure Arc, install Foundry Local, and validate end-to-end inference. Each stage is independent — you can start at the appropriate stage depending on what you already have provisioned.

---

## Execution Flow

The deployment is broken into **four stages**. Each stage has its own prerequisites and scripts. Stages run in order, but every script is idempotent — safe to re-run.

```
┌─ Stage A: OCP Cluster ──────────────────────────────────┐
│  00-provision-ocp.sh                                    │
│    • Creates DNS resource group                         │
│    • Runs openshift-install (IPI) → cluster + kubeconfig│
│    (~45 min)  — skip if you already have a cluster      │
└──────────────────────────┬──────────────────────────────┘
                           │
┌─ Stage B: Azure Arc Onboarding ─────────────────────────┐
│  01-prep-arc-azure.sh   (Azure-side, no cluster access) │
│    • Creates Arc RG                                     │
│    • Registers providers + installs az extensions       │
│  02-connect-arc.sh      (needs KUBECONFIG + Azure)      │
│    • Pre-creates azure-arc namespace with SCC + Helm    │
│      ownership labels (OCP workaround)                  │
│    • az connectedk8s connect --distribution openshift   │
│    (~8 min total)                                       │
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
│    • Registers Entra app + scope + RBAC                 │
│    • Then re-install operator with entraAuth.enabled    │
│    (~3 min)                                             │
└─────────────────────────────────────────────────────────┘
```

**Total time: ~60–70 minutes** (mostly OCP provisioning in Stage A).

---

## Before You Start

These steps are required regardless of which stage you start from.

### Tools Required

| Tool | Version | Purpose | Stages |
|------|---------|---------|--------|
| `az` | ≥ 2.64 | Azure CLI for resource management | A, B, D |
| `oc` | ≥ 4.14 | OpenShift CLI (SCC management, cluster admin) | B, C |
| `kubectl` | ≥ 1.29 | Kubernetes operations | B, C |
| `helm` | ≥ 3.14 | Chart installations | C |
| `openshift-install` | ≥ 4.14 | OCP cluster provisioning (UPI/IPI) | A only |
| `jq` | any | JSON processing (optional — fallback to sed if missing) | A, C, D |
| `curl` | any | Inference API testing | C |

**Downloads:**
- `oc` + `openshift-install`: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/
- `helm`: https://github.com/helm/helm/releases
- `az` CLI: https://learn.microsoft.com/cli/azure/install-azure-cli

### 1. Open Git Bash and verify tools

The scripts are bash — on Windows, use **Git Bash** or WSL.

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
az account show -o table                          # confirm
```

If you have multiple tenants:

```bash
az login --tenant <TENANT_ID>
```

> 🔍 Hit `[WinError 5] Access is denied` errors? See [Azure CLI extension permissions on Windows](#azure-cli-extension-permissions-on-windows) in Troubleshooting.

### 3. Clone this repo and configure env.sh

```bash
git clone https://github.com/drajpure/arc-ai-inference-lab.git
cd arc-ai-inference-lab/reports/foundry-local-ocp

cp env.sh.example env.sh
# Edit env.sh — see comments inside the file
source env.sh
```

The variables you must set depend on which stage you start at:

| Variable | Required by | Notes |
|----------|------------|-------|
| `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_REGION` | All | Region must be a [Foundry Local supported region](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/what-is-foundry-local-on-azure-local#supported-regions) |
| `CLUSTER_NAME`, `BASE_DOMAIN`, `OCP_RESOURCE_GROUP`, `PULL_SECRET_FILE` | Stage A | OCP install only |
| `ARC_RESOURCE_GROUP`, `ARC_CLUSTER_NAME` | Stages B, D | Arc connectedCluster |
| `KUBECONFIG` | Stages B, C, D | Path to OCP kubeconfig |
| `STORAGE_CLASS`, `MODEL_ALIAS`, `DEPLOYMENT_NAME`, `NAMESPACE` | Stage C | Foundry Local |
| `ENTRA_APP_NAME`, `ENTRA_USER_OR_GROUP_OBJECT_ID` | Stage D | Optional |

---

## Stage A — Provision OCP Cluster

> **Skip this stage if you already have an OpenShift cluster.** Go directly to [Stage B](#stage-b--connect-cluster-to-azure-arc).

### Already have an OCP cluster? Quick check

```bash
# If any of these succeed, you can skip Stage A:
oc whoami --show-server                              # Returns your OCP API URL
oc get nodes                                         # Returns 3+ nodes
kubectl --kubeconfig=/path/to/your/kubeconfig get nodes
```

If you have a kubeconfig but no `KUBECONFIG` var set yet, configure it now and skip ahead:

```bash
export KUBECONFIG="/path/to/your/kubeconfig.yaml"
echo "export KUBECONFIG=\"$KUBECONFIG\"" >> env.sh
oc get nodes                                          # Sanity check, then go to Stage B
```

### Stage A Prerequisites

| Requirement | How to obtain |
|-------------|---------------|
| Subscription with **Contributor + User Access Administrator** (or Owner) | Existing Azure subscription |
| Azure quota: ≥ **24 vCPU** of `Standard_D8s_v3` in your region | `az vm list-usage -l <region> -o table` to check |
| **Azure DNS zone** matching `${BASE_DOMAIN}` (e.g., `example.com`) | `az network dns zone create -g ${OCP_RESOURCE_GROUP} -n example.com` |
| **Red Hat pull secret** | Download from https://console.redhat.com/openshift/install/azure/installer-provisioned — save as `.pull-secret.txt` in this directory |
| **Azure service principal** with VM/network/DNS create permissions | `az ad sp create-for-rbac --role Contributor --scopes /subscriptions/<sub-id>` — credentials cached in `~/.azure/osServicePrincipal.json` by `openshift-install` |
| `openshift-install` binary on `PATH` | See [Tools Required](#tools-required) |

### Stage A Steps

```bash
source env.sh
./scripts/00-provision-ocp.sh
```

> **What happens if the cluster is already provisioned?** The script detects existing install state (`${INSTALL_DIR}/metadata.json` + `auth/kubeconfig`) and **automatically skips** `openshift-install create cluster` with a clear next-steps message. It will never overwrite a working cluster. To force a fresh install, run `openshift-install destroy cluster --dir=./install-dir` first, then delete `./install-dir`.

This will:
1. Create the **DNS resource group** (`${OCP_RESOURCE_GROUP}`, default `rg-ocp-dns`).
2. Generate `install-config.yaml` from your env vars + pull secret.
3. Run `openshift-install create cluster` — takes ~45 minutes.

**On completion**, capture the kubeconfig path:

```bash
export KUBECONFIG="$(pwd)/install-dir/auth/kubeconfig"
echo "export KUBECONFIG=\"$KUBECONFIG\"" >> env.sh   # persist for next session
oc get nodes
oc get clusterversion
```

### Resource Group Layout (after Stage A)

Two distinct RGs exist after this stage (and the next):

| Variable | Default | Created by | Purpose |
|----------|---------|------------|---------|
| `OCP_RESOURCE_GROUP` | `rg-ocp-dns` | Stage A | Holds the Azure DNS zone for `${BASE_DOMAIN}`. The installer creates a separate infra RG `${CLUSTER_NAME}-<infraID>-rg` for VMs/networking. |
| `ARC_RESOURCE_GROUP` | `rg-ocp-foundry-arc` | Stage B | Holds the Arc `connectedCluster` resource. Can equal `OCP_RESOURCE_GROUP` if you prefer a single RG. |

---

## Stage B — Connect Cluster to Azure Arc

> **Already Arc-connected?** Both scripts in this stage are idempotent and will detect existing state:
> - `01-prep-arc-azure.sh` is safe to re-run — all operations (RG create, provider register, extension add) no-op if already in the desired state.
> - `02-connect-arc.sh` checks for an existing `connectedCluster` resource and **skips `az connectedk8s connect`** if it exists, printing the current connectivity status.

### Already Arc-connected? Quick check

```bash
az connectedk8s list -g "$ARC_RESOURCE_GROUP" -o table

# Or check a specific cluster:
az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" \
  --query "{name:name, status:connectivityStatus}" -o table
```

If `connectivityStatus` is `Connected`, you can either:
- **Skip Stage B entirely** and go to [Stage C](#stage-c--install-foundry-local), or
- Re-run the scripts anyway — they'll detect the existing state and complete in ~30 seconds without modifying anything.

### Stage B Prerequisites

| Requirement | Check |
|-------------|-------|
| Azure auth done (Step 2 above) | `az account show` succeeds |
| `KUBECONFIG` points to an OCP cluster | `oc whoami` returns `system:admin` or your user |
| Cluster admin / SCC privileges on the cluster | `oc auth can-i create scc` returns `yes` |
| `ARC_RESOURCE_GROUP` and `ARC_CLUSTER_NAME` set in env.sh | `echo $ARC_RESOURCE_GROUP $ARC_CLUSTER_NAME` |

The `az connectedk8s` and `k8s-extension` extensions are installed automatically by script `01`.

### Stage B Steps

```bash
source env.sh
./scripts/01-prep-arc-azure.sh    # Azure-side prep — creates ARC_RESOURCE_GROUP, registers providers
./scripts/02-connect-arc.sh       # Cluster-side prep + az connectedk8s connect
```

> **Expected output if already connected:**
> ```
> Arc connectedCluster 'ocp-cluster-arc' already exists (status=Connected).
> Skipping 'az connectedk8s connect'. To re-onboard, run:
>   az connectedk8s delete -n ocp-cluster-arc -g rg-openshift-arc --yes
> ```
> The cluster-side namespace/SA/SCC setup still runs (it's idempotent), so the script is also useful for repairing partial state.

### Stage B Verification

```bash
az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" \
  --query "{name:name, status:connectivityStatus, distro:distribution}" -o table

kubectl get pods -n azure-arc        # all should be Running
```

Expected output: `connectivityStatus: Connected`, `distribution: openshift`, all 12 Arc agent pods in `azure-arc` namespace Running.

---

## Stage C — Install Foundry Local

> **Already installed Foundry Local?** All scripts in this stage are idempotent:
> - `03`, `05`: use `helm upgrade --install` — re-runs reconcile to the same state without recreating resources.
> - `04`, `06`: SCC grants and namespace creation use `kubectl apply` and `oc adm policy add-scc-to-user` — both silently no-op if already applied.
> - `07`: `kubectl apply` for the ModelDeployment is idempotent. If the model is already Ready, it returns immediately and runs the inference test.
> - `08`: read-only — runs the E2E test suite against whatever is currently deployed.

### Already deployed? Quick check

```bash
# Is the operator running?
kubectl get pods -n "$NAMESPACE"
helm list -n "$NAMESPACE"

# Is a model deployed and Ready?
kubectl get modeldeployment -n "$NAMESPACE"
```

If everything is Running/Ready, you can skip directly to `08-e2e-tests.sh` to re-validate, or re-run the whole sequence — it's fast (~2 minutes) and confirms each layer is healthy.

### Stage C Prerequisites

| Requirement | Notes |
|-------------|-------|
| Cluster Arc-connected (Stage B done) | `az connectedk8s show ...` returns Connected |
| Foundry Local preview approval | Submit at https://aka.ms/FoundryLocalAzure_PreviewRequest — note the Helm chart on MCR is publicly accessible even without approval |
| **`microsoft.certmanagement` Arc extension does NOT work on OpenShift** | Script 03 installs upstream Jetstack cert-manager directly instead |
| Working `StorageClass` for ReadWriteOnce PVCs | If your default `StorageClass` is broken, set `STORAGE_CLASS=local-storage` in env.sh and apply the local-storage manifests (see [manifests/](#directory-layout)) |
| `DEPLOYMENT_NAME` set in env.sh | Used by both 07 and 08 — must match if re-running on an existing deployment |

**Why two SCC phases?** OpenShift's Security Context Constraints require granting access to specific service accounts. The Foundry Helm chart's pre-install Job runs under the `default` SA (which doesn't exist yet at install time), so SCC must be granted in two phases:
- **Phase 1** (`04`): Grant SCC to `default` and `foundry-config-reader` *before* `helm install`.
- **Phase 2** (`06`): Grant SCC to `inference-operator` and `inference-operator-catalog-sync` (created by the chart) *after* `helm install`.

### Stage C Steps

```bash
source env.sh
./scripts/03-install-cert-manager.sh       # cert-manager + trust-manager (Jetstack)
./scripts/04-prep-namespace-scc.sh         # Phase 1 SCC
./scripts/05-install-foundry-operator.sh   # Helm install inference-operator
./scripts/06-post-install-scc.sh           # Phase 2 SCC
./scripts/07-deploy-and-validate.sh        # Deploy MODEL_ALIAS + single inference test
./scripts/08-e2e-tests.sh                  # Full 8-test E2E suite
```

### Stage C Verification

```bash
kubectl get pods -n "$NAMESPACE"           # inference-operator, model-store, telemetry-collector all Running
kubectl get modeldeployment -n "$NAMESPACE"
oc get crd | grep foundry                   # CRDs registered
```

The E2E suite (`08`) prints a summary table with PASS/FAIL counts. Expect **7/8 passing** on first run (see [validation-report.md](validation-report.md) for details).

---

## Stage D (optional) — Configure Entra ID Authentication

> **Already configured Entra auth?** Script `09` is fully idempotent:
> - Looks up the Entra app by name (`ENTRA_APP_NAME`) and reuses it if present.
> - Checks if `foundry_access` scope already exists before creating.
> - RBAC role assignments accept "already exists" errors silently.

By default, Foundry Local uses **API-key authentication** (script `05` sets `entraAuth.enabled=false`). For production use, switch to Microsoft Entra ID with Azure RBAC.

### Already configured? Quick check

```bash
# Is the Entra app already registered?
az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].{appId:appId, idUri:identifierUris}" -o table

# Is the Arc cluster identity already granted Cognitive Services OpenAI User?
ARC_OID=$(az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" --query identity.principalId -o tsv)
az role assignment list --assignee "$ARC_OID" -o table
```

If the app exists with `api://...` URI **and** the Arc identity has the role assignment, you can skip Stage D — or re-run script `09` (it'll no-op every existing piece and only create what's missing).

### Stage D Prerequisites

| Requirement | Notes |
|-------------|-------|
| Stages A, B, C complete | Cluster Arc-connected + Foundry installed |
| **Application Administrator** (or equivalent) role in Entra | Required to create the app registration |
| **Owner / User Access Administrator** on the cluster RG scope | Required to assign Azure RBAC roles |
| Object ID of user/group to grant inference access (optional) | `az ad user show --id <upn> --query id -o tsv` |

### Stage D Steps

```bash
source env.sh
./scripts/09-configure-entra-auth.sh       # Registers app, sets scope/v2, assigns RBAC
```

The script outputs three values needed for the operator upgrade. Either copy them into `env.sh` or re-run the script which echoes them at the end:

```bash
# Take values from script output, then:
helm upgrade --install inference-operator \
  oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator \
  --version "$OPERATOR_VERSION" \
  --namespace "$NAMESPACE" \
  --set entraAuth.enabled=true \
  --set entraAuth.tenantId="$ENTRA_TENANT_ID" \
  --set entraAuth.audience="$ENTRA_APP_ID_URI"
```

Then re-run `06-post-install-scc.sh` if the chart created new SAs.

### Stage D Verification

```bash
# Acquire a token via az
TOKEN=$(az account get-access-token --resource "$ENTRA_APP_ID_URI" --query accessToken -o tsv)

# Call the inference endpoint with the bearer token instead of api-key
curl -sk https://localhost:5000/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"'"$MODEL_ALIAS"'","messages":[{"role":"user","content":"hi"}],"max_tokens":20}'
```

A 200 response confirms Entra auth is working. A `401 invalid_token` means a Stage D step was missed — check the [auth doc](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/how-to-configure-authentication).

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
./scripts/03-install-cert-manager.sh

# Re-run from a specific point onward
for s in scripts/03-* scripts/04-* scripts/05-*; do bash "$s"; done

# Force a clean install (destructive — only for OCP infra)
openshift-install destroy cluster --dir=./install-dir
rm -rf ./install-dir
./scripts/00-provision-ocp.sh
```

`helm uninstall` is deliberately not in any script — cleanup is left to the operator.

---

## Directory Layout

```
reports/foundry-local-ocp/
├── README.md                          # This file
├── validation-report.md               # Full validation report with findings
├── env.sh.example                     # Environment variables template
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
│   └── 09-configure-entra-auth.sh     # [D] (optional) Entra ID app + RBAC
└── manifests/
    ├── local-storage-class.yaml       # Workaround: local StorageClass
    ├── local-pv.yaml                  # Workaround: hostPath PV
    ├── create-model-dir-pod.yaml      # Workaround: create dir on node
    └── sample-model-deployment.yaml   # Example ModelDeployment CR
```

---

## Troubleshooting

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
