# Foundry Local on OpenShift via Helm Chart (Standalone)

End-to-end scripts to install **Microsoft Foundry Local** on a **self-hosted OpenShift (OCP)** cluster using **direct Helm chart installation** from MCR.

## Tested Environment

| Component | Version |
|-----------|---------|
| OpenShift | 4.21.2 |
| Kubernetes | v1.34.2 |
| CRI-O | 1.34.5 |
| Azure Arc | Connected via `az connectedk8s` |
| Operator chart | `oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator` |

## Prerequisites

- OpenShift cluster >= 4.19 (Kubernetes >= 1.29) — see [provision-ocp/](../provision-ocp/) if you need one
- `az`, `kubectl`, `oc`, `helm`, `jq`, `curl` installed
- Foundry Local preview access ([request here](https://aka.ms/FoundryLocalAzure_PreviewRequest))

## Quick Start

```bash
# 1. Copy and fill in your environment
cp env.sh.example env.sh
vim env.sh  # fill in subscription, resource group, Arc cluster name, model, etc.

# 2. Run scripts in order
./scripts/01-prep-arc-azure.sh           # Azure-side Arc prep (RG, providers, az extensions)
./scripts/02-connect-arc.sh              # Connect OCP to Azure Arc
./scripts/03-install-cert-manager.sh     # cert-manager + trust-manager (Jetstack)
./scripts/04-prep-namespace-scc.sh       # Phase 1 SCC grants (before Helm install)
./scripts/05-install-foundry-operator.sh # Helm install inference operator
./scripts/06-post-install-scc.sh         # Phase 2 SCC grants (after Helm install)
./scripts/07-deploy-and-validate.sh      # Deploy model + single inference test
./scripts/08-e2e-tests.sh               # Full E2E test suite

# Optional:
./scripts/09-configure-entra-auth.sh     # Entra ID authentication setup
```

## OCP-Specific Workarounds

| # | Workaround | Why Needed |
|---|-----------|-----------|
| 1 | Two-phase SCC grants (Phase 1 before install, Phase 2 after) | Helm pre-install Job uses `default` SA; operator SAs created by chart |
| 2 | Upstream Jetstack cert-manager (not Arc extension) | `microsoft.certmanagement` Arc extension has CRI-O incompatible images |
| 3 | `local-storage` StorageClass + hostPath PV | Azure Disk CSI may fail on UPI/Manual cred clusters |
| 4 | Swap default StorageClass to `local-storage` | Operator ignores `modelStore.storageClassName`; uses cluster default |
| 5 | `global.telemetry.enabled=false` | Prevents OTEL collector bugs from blocking install |

## Architecture

```
OCP Cluster (namespace: foundry-local-operator)
├── inference-operator        (operator + CRD controller)
├── inference-operator-api    (API gateway + model router)
├── model-store               (model download + cache, PVC-backed)
├── telemetry-collector       (OTEL)
└── <model-deployment> pods   (one per deployed model)
```

## File Structure

```
helm-standalone/
├── README.md                          ← This file
├── validation-report.md               ← Full validation report with findings
├── env.sh.example                     ← Template — copy to env.sh
├── scripts/
│   ├── 01-prep-arc-azure.sh           ← Azure-side Arc prep (RG, providers)
│   ├── 02-connect-arc.sh             ← Connect OCP to Arc
│   ├── 03-install-cert-manager.sh     ← cert-manager + trust-manager
│   ├── 04-prep-namespace-scc.sh       ← Phase 1 SCC grants
│   ├── 05-install-foundry-operator.sh ← Helm install operator
│   ├── 06-post-install-scc.sh         ← Phase 2 SCC grants
│   ├── 07-deploy-and-validate.sh      ← Deploy model + inference test
│   ├── 08-e2e-tests.sh               ← Full E2E test suite
│   ├── 09-configure-entra-auth.sh     ← Entra ID auth (optional)
│   └── ocp-fl-demo.sh                ← Interactive step-by-step demo
└── manifests/
    ├── local-storage-class.yaml       ← local StorageClass
    ├── local-pv.yaml                  ← hostPath PV (100Gi)
    ├── create-model-dir-pod.yaml      ← Creates dir on target node
    └── sample-model-deployment.yaml   ← Example ModelDeployment CR
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Helm pre-install Job stuck `Pending` | Run `04-prep-namespace-scc.sh` before install |
| PVC stuck `Pending` | Use `local-storage` workaround (see manifests/) |
| `telemetry-collector` CrashLoop | Run `06-post-install-scc.sh` |
| Model not in catalog | Query: `kubectl get cm foundry-local-catalog -n $NS -o jsonpath='{.data.catalog\.json}' \| jq '.models[].alias'` |
| cert-manager Arc extension fails | Use upstream Jetstack charts (script 03 does this) |
| `[WinError 5] Access is denied` on `az connectedk8s` | Elevated PowerShell: `takeown /F ~/.azure/cliextensions /R /D Y` then reinstall extension |

## References

- [Deploy Foundry Local Arc Extension](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension)
- [Configure Authentication (Entra ID)](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/how-to-configure-authentication)
- [Azure Arc on OpenShift Troubleshooting](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc)
- [OpenShift Install on Azure (IPI)](https://docs.openshift.com/container-platform/latest/installing/installing_azure/ipi/installing-azure-default.html)
