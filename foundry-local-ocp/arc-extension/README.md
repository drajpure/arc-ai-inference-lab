# Foundry Local on OpenShift via Arc Extension

End-to-end scripts to install **Microsoft Foundry Local** on a **self-hosted OpenShift (OCP)** cluster using the **Azure Arc Extension** mechanism (not manual Helm).

## Tested Environment

| Component | Version |
|-----------|---------|
| OpenShift | 4.21.2 |
| Kubernetes | v1.34.2 |
| CRI-O | 1.34.5 |
| Azure Arc | Connected via `az connectedk8s` |
| Extension type | `microsoft.foundry` |

## Prerequisites

- OpenShift cluster ≥ 4.19 (Kubernetes ≥ 1.29)
- Cluster connected to Azure Arc (`az connectedk8s connect`)
- `az`, `kubectl`, `oc`, `jq`, `curl` installed
- Foundry Local preview access approved (request via https://aka.ms/FoundryLocalAzure_PreviewRequest)

## Quick Start

```bash
# 1. Copy and fill in your environment
cp env.sh.example env.sh
vim env.sh  # fill in subscription, resource group, Arc cluster name, node, etc.
             # For Entra ID auth: set ENTRA_APP_CLIENT_ID (run 09-configure-entra-auth.sh first)

# 2. (Optional) Set up Entra ID auth BEFORE extension install
./scripts/09-configure-entra-auth.sh # Creates app registration, scopes, RBAC
                                      # Copy the ENTRA_APP_CLIENT_ID output to env.sh

# 3. Run scripts in order
./scripts/00-prerequisites.sh        # Verify tools, connectivity, Arc status
./scripts/01-connect-arc.sh          # Register providers, create RG, connect to Arc (skips if already done)
./scripts/02-install-cert-manager.sh # Install cert-manager + trust-manager (required by Foundry)
./scripts/03-prep-namespace-scc.sh   # Pre-create SAs, grant privileged SCC
./scripts/04-prep-storage.sh         # Set up local-storage SC + PV (if needed)
./scripts/05-install-extension.sh    # Install via az k8s-extension create (auto-detects Entra config)
./scripts/06-deploy-model.sh         # Deploy a model from catalog
./scripts/07-validate-inference.sh   # Port-forward + test API key + Entra token auth
```

## Uninstall

```bash
./scripts/10-uninstall.sh  # Removes extension, SCC grants, CRDs, PVCs; restores default SC
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  OCP Cluster (self-hosted on Azure)                     │
│                                                         │
│  namespace: foundry-local-operator                      │
│  ┌───────────────────────────────────────────────────┐  │
│  │  inference-operator (3 replicas)                  │  │
│  │  inference-operator-api (5 replicas)              │  │
│  │  model-store (2 replicas, PVC-backed)             │  │
│  │  telemetry-collector (4 replicas)                 │  │
│  │  model-deployment pods (per model)                │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  namespace: azure-arc                                   │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Arc agents (flux, config-agent, etc.)            │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
         │
         │ az k8s-extension create
         ▼
┌─────────────────────────┐
│  Azure Resource Manager │
│  - Extension resource   │
│  - Helm chart delivery  │
└─────────────────────────┘
```

## OCP-Specific Workarounds

These workarounds address gaps between the Foundry Local docs (written for AKS) and OCP's security model:

| # | Workaround | Why Needed |
|---|-----------|-----------|
| 1 | Pre-grant `privileged` SCC to 6 ServiceAccounts | OCP's SCC blocks pods that set runAsUser outside namespace UID range, or request NET_ADMIN/NET_RAW (msi-adapter init container) |
| 2 | Swap default StorageClass to `local-storage` | Extension ignores `modelStore.storageClassName` config; always uses cluster default. Azure Disk CSI may fail on UPI/Manual cred clusters |
| 3 | Create `local-storage` StorageClass | OCP UPI installs don't ship a local-volume provisioner |
| 4 | Create PersistentVolume (100Gi, hostPath) | No dynamic provisioner for local-storage |
| 5 | Create host directory on target node | Node filesystem must have the path pre-created |
| 6 | Config: `global.telemetry.enabled=false` | Prevents OTEL collector bugs from blocking install (telemetry pods still created but data collection disabled) |
| 7 | Clear PV claimRef after failed attempts | PV goes to `Released` state after rollback — must patch to make Available again |
| 8 | Use extension type `microsoft.foundry` | Not `Microsoft.FoundryLocal` or any other variant |
| 9 | Use model CRD schema `spec.model.catalog.name` | Newer API version; not the older `spec.modelId` |

## ServiceAccount Naming Convention

The Arc extension creates SAs with a predictable naming pattern based on the `--name` parameter:

```
<EXTENSION_NAME>-inference-operator
<EXTENSION_NAME>-inference-operator-api
<EXTENSION_NAME>-inference-operator-catalog-sync
foundry-config-reader              (fixed)
inference-operator-crd-update      (fixed)
default                            (OCP built-in)
```

With `--name foundrylocal` (default in env.sh.example), the prefixed SAs become:
- `foundrylocal-inference-operator`
- `foundrylocal-inference-operator-api`
- `foundrylocal-inference-operator-catalog-sync`

## Known Limitations

1. **`modelStore.storageClassName` config is ignored** — extension always uses the cluster default SC
2. **Install is atomic** — if any pod can't start (SCC, PVC binding), entire Helm release rolls back
3. **`global.telemetry.enabled=false` does NOT prevent telemetry pod creation** — pods still run, but data collection is disabled
4. **Privileged SCC required** (not just `anyuid`) — due to `msi-adapter` init container in operator-api
5. **Single-node PV** — local-storage PV has node affinity; model-store pod must land on that node

## File Structure

```
arc-extension/
├── README.md                      ← This file
├── env.sh.example                 ← Template — copy to env.sh
├── validation-report.md           ← Full validation report with findings
└── scripts/
    ├── 00-prerequisites.sh        ← Verify tools & connectivity
    ├── 01-connect-arc.sh          ← Azure prep + connect OCP to Arc
    ├── 02-install-cert-manager.sh ← cert-manager + trust-manager (Jetstack)
    ├── 03-prep-namespace-scc.sh   ← Namespace + SCC grants
    ├── 04-prep-storage.sh         ← StorageClass + PV setup
    ├── 05-install-extension.sh    ← Arc extension install
    ├── 06-deploy-model.sh         ← Deploy model from catalog
    ├── 07-validate-inference.sh   ← Quick inference validation
    ├── 08-e2e-tests.sh            ← Full E2E test suite (10 tests)
    ├── 09-configure-entra-auth.sh ← Entra ID authentication setup
    ├── 10-uninstall.sh            ← Clean removal
    └── ocp-fl-demo.sh             ← Interactive step-by-step demo
```
