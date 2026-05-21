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

## Execution Flow

```
┌─────────────────────────────────────────────────────────┐
│  Phase 1: Provision OCP Cluster                         │
│  scripts/00-provision-ocp.sh                            │
│  (~45 min)                                              │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Phase 2: Connect to Azure Arc                          │
│  scripts/01-connect-arc.sh                              │
│  (~5 min)                                               │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Phase 3: Install cert-manager + trust-manager          │
│  scripts/02-install-cert-manager.sh                     │
│  (~2 min)                                               │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Phase 4: Prepare namespace + SCC grants (Phase 1)      │
│  scripts/03-prep-namespace-scc.sh                       │
│  (~30 sec)                                              │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Phase 5: Install Foundry inference operator            │
│  scripts/04-install-foundry-operator.sh                 │
│  (~3 min)                                               │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Phase 6: Post-install SCC grants (Phase 2)             │
│  scripts/05-post-install-scc.sh                         │
│  (~30 sec)                                              │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Phase 7: Deploy model + validate inference             │
│  scripts/06-deploy-and-validate.sh                      │
│  (~3–5 min)                                             │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Phase 8: Run E2E test suite + generate report          │
│  scripts/07-e2e-tests.sh                                │
│  (~2 min)                                               │
└─────────────────────────────────────────────────────────┘
```

**Total time: ~60–70 minutes** (mostly OCP provisioning)

---

## Quick Start (Existing OCP Cluster)

If you already have an OCP cluster with Arc connected:

```bash
export KUBECONFIG=/path/to/kubeconfig
export STORAGE_CLASS=""  # Leave empty for default, or "local-storage" if CSI is broken

# Steps 3–8 only
./scripts/02-install-cert-manager.sh
./scripts/03-prep-namespace-scc.sh
./scripts/04-install-foundry-operator.sh
./scripts/05-post-install-scc.sh
./scripts/06-deploy-and-validate.sh
./scripts/07-e2e-tests.sh
```

---

## Directory Layout

```
reports/foundry-local-ocp/
├── README.md                          # This file
├── validation-report.md               # Full validation report with findings
├── scripts/
│   ├── 00-provision-ocp.sh            # Provision OCP on Azure (IPI)
│   ├── 01-connect-arc.sh              # Connect cluster to Azure Arc
│   ├── 02-install-cert-manager.sh     # cert-manager + trust-manager
│   ├── 03-prep-namespace-scc.sh       # Namespace + Phase 1 SCC grants
│   ├── 04-install-foundry-operator.sh # Helm install inference operator
│   ├── 05-post-install-scc.sh         # Phase 2 SCC grants
│   ├── 06-deploy-and-validate.sh      # Deploy model + single inference test
│   └── 07-e2e-tests.sh               # Full E2E test suite with report
├── manifests/
│   ├── local-storage-class.yaml       # Workaround: local StorageClass
│   ├── local-pv.yaml                  # Workaround: hostPath PV
│   ├── create-model-dir-pod.yaml      # Workaround: create dir on node
│   └── sample-model-deployment.yaml   # Example ModelDeployment CR
└── env.sh.example                     # Environment variables template
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Helm pre-install Job stuck in `Pending` | Missing SCC grants on `default` SA | Run `03-prep-namespace-scc.sh` before install |
| PVC stuck in `Pending` | CSI driver broken or wrong StorageClass | Use `local-storage` workaround (see manifests/) |
| `telemetry-collector` CrashLoop | Needs `privileged` SCC for NET_ADMIN caps | Run `05-post-install-scc.sh` |
| Model not found in catalog | Wrong alias (docs examples are outdated) | Query catalog: `kubectl get cm foundry-local-catalog -n foundry-local-operator -o jsonpath='{.data.catalog\.json}' \| jq '.models[].alias'` |
| Arc extension type fails | Preview-gated; not available in your subscription | Use Helm chart directly (script 04 does this) |
| cert-manager Arc extension fails | CRI-O incompatible images + deprecated seccomp | Use upstream Jetstack charts (script 02 does this) |

---

## References

- [Deploy Foundry Local Arc Extension](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension)
- [What is Foundry Local](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/what-is-foundry-local-on-azure-local)
- [Configure Authentication](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/how-to-configure-authentication)
- [Azure Arc on OpenShift Troubleshooting](https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc)
- [OpenShift Install on Azure (IPI)](https://docs.openshift.com/container-platform/latest/installing/installing_azure/ipi/installing-azure-default.html)
