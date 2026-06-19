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

# 2. Run scripts in order
./scripts/00-prerequisites.sh        # Verify tools, connectivity, Arc status

# (Only if cluster is NOT yet Arc-connected:)
./scripts/01a-prep-arc-azure.sh      # Register providers, create RG, install CLI extensions
./scripts/01b-connect-arc.sh         # Connect OCP cluster to Azure Arc

# Core install flow:
./scripts/01-prep-namespace-scc.sh   # Pre-create SAs, grant privileged SCC
./scripts/02-prep-storage.sh         # Set up local-storage SC + PV (if needed)
./scripts/03-install-extension.sh    # Install via az k8s-extension create
./scripts/04-deploy-model.sh         # Deploy a model from catalog
./scripts/05-validate-inference.sh   # Port-forward + send inference request

# Validation & auth:
./scripts/07-e2e-tests.sh            # Full E2E test suite (10 tests)
./scripts/08-configure-entra-auth.sh # Entra ID authentication setup
```

## Uninstall

```bash
./scripts/06-uninstall.sh  # Removes extension, SCC grants, CRDs, PVCs; restores default SC
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
ArcExtension/
├── README.md                      ← This file
├── env.sh.example                 ← Template — copy to env.sh
├── gaps-and-workarounds.md        ← Detailed gap analysis report
├── scripts/
│   ├── 00-prerequisites.sh        ← Verify tools & connectivity
│   ├── 01a-prep-arc-azure.sh      ← Azure providers + RG (if not Arc-connected)
│   ├── 01b-connect-arc.sh         ← Connect OCP to Azure Arc (if not Arc-connected)
│   ├── 01-prep-namespace-scc.sh   ← Namespace + SCC grants
│   ├── 02-prep-storage.sh         ← StorageClass + PV setup
│   ├── 03-install-extension.sh    ← Arc extension install
│   ├── 04-deploy-model.sh         ← Deploy model from catalog
│   ├── 05-validate-inference.sh   ← Quick inference validation
│   ├── 06-uninstall.sh            ← Clean removal
│   ├── 07-e2e-tests.sh            ← Full E2E test suite (10 tests)
│   └── 08-configure-entra-auth.sh ← Entra ID authentication setup
└── manifests/                     ← (Optional YAML manifests for reference)
```
