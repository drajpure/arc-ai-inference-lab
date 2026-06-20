# Foundry Local on Self-Hosted OpenShift (Arc Extension) — Validation Report

Status: **✅ Validated end-to-end. Inference round-trip succeeded against `qwen2.5-coder-0.5b` (HTTP 200, TLS, API-key auth).**

Install Method: `az k8s-extension create --extension-type microsoft.foundry`

---

## Environment

| Item | Value |
|------|-------|
| OpenShift | 4.21.2 (Kubernetes v1.34.2, CRI-O 1.34.5) |
| Nodes | 3 × master+worker (Standard_D8s_v3, CPU-only) |
| Azure Arc | Connected (`distributionVersion=4.21`) |
| Extension | `microsoft.foundry` (name: `foundrylocal`) |
| Model | `qwen2.5-coder-0.5b` (ONNX, CPU, ~862 MB) |

---

## Phase Results

| Phase | Result |
|-------|--------|
| OCP Cluster provisioned (3 nodes) | ✅ |
| Arc connected (`az connectedk8s connect --distribution openshift`) | ✅ |
| Pre-create SAs with Helm labels + `privileged` SCC | ✅ |
| Storage: swap default SC to `local-storage` + hostPath PV | ✅ |
| Extension install (`az k8s-extension create`) | ✅ Succeeded |
| Pods: operator 3/3, api 5/5, store 2/2, telemetry 4/4 | ✅ |
| Model deployed (`qwen2-5-coder-0-5b`), Available=True | ✅ |
| Inference: HTTPS POST → HTTP 200, correct response | ✅ |

---

## Inference Validation — 2026-06-19

```
Model:      qwen2.5-coder-0.5b (deployment: qwen2-5-coder-0-5b)
CRD:        modeldeployments.foundrylocal.azure.com/v1
Protocol:   HTTPS (self-signed TLS, port 5000)
Auth:       api-key header (secret: <deploy-name>-api-keys)
Prompt:     "What is 2+2?"
Response:   "4" (HTTP 200)
```

---

## Key Divergences from AKS

| # | Divergence | Severity | Workaround |
|---|-----------|----------|-----------|
| D1 | All pods require `privileged` SCC (hardcoded UIDs + NET_ADMIN) | 🔴 Blocking | Pre-create 6 SAs with SCC grants + Helm ownership labels |
| D2 | `modelStore.storageClassName` config ignored | 🔴 Blocking | Swap cluster default SC to `local-storage` |
| D3 | Azure Disk CSI broken on UPI/Manual credential clusters | 🔴 Env-specific | Use hostPath PV with node affinity |
| D4 | OTEL telemetry collector bug | 🟡 Partial | Set `global.telemetry.enabled=false` |
| D5 | PV goes `Released` after failed install rollback | 🟡 Operational | Clear claimRef before retry |
| D6 | Extension type must be `microsoft.foundry` (lowercase exactly) | 🟡 Doc gap | Use exact casing |
| D7 | CRD is `foundrylocal.azure.com/v1` (not `inference.foundry.azure.com/v1alpha1`) | 🟡 Doc gap | Use current API version |
| D8 | Pre-created resources need Helm ownership labels | 🔴 Arc-specific | Add `managed-by: Helm` + release annotations |
| D9 | ModelDeployment name must be DNS-1035 (no dots) | 🟡 Doc gap | Sanitize: `tr '.' '-'` |

---

## Workarounds Applied

| # | What | Script |
|---|------|--------|
| W1 | Pre-create 6 SAs with Helm labels + `privileged` SCC | `02-prep-namespace-scc.sh` |
| W2 | Swap default StorageClass to `local-storage` | `03-prep-storage.sh` |
| W3 | Create hostPath PV (100Gi) + dir on node | `03-prep-storage.sh` |
| W4 | Set `global.telemetry.enabled=false` | `04-install-extension.sh` |
| W5 | Clear PV claimRef on retry | `03-prep-storage.sh` |
| W6 | DNS-1035 sanitize model name (dots → hyphens) | `05-deploy-model.sh` |

---

## Recommendations to Foundry Team

| Priority | Recommendation |
|----------|---------------|
| 🔴 High | Honor `modelStore.storageClassName` config (currently ignored) |
| 🔴 High | Reduce SCC requirements — drop root UID from msi-adapter |
| 🔴 High | Document OpenShift deployment path (zero docs exist) |
| 🟡 Medium | Document DNS-1035 name requirement for ModelDeployment |
| 🟡 Medium | Document `foundrylocal.azure.com/v1` CRD schema |
| 🟡 Medium | Fix telemetry flag to prevent pod creation entirely |
| ⚪ Low | OLM Operator packaging for OperatorHub |
| ⚪ Low | Integration with OCP service-ca (eliminate cert-manager dep) |

---

## Conclusion

**Foundry Local works on self-hosted OpenShift 4.21 via Arc Extension** with 6 workarounds. The fundamental gap is that Foundry assumes Kubernetes PSS (namespace labels) while OpenShift uses SCC (per-SA grants) — incompatible admission systems. The atomic install makes this worse: everything must be pre-configured correctly with no opportunity to fix mid-install.

---
---

# Appendix

## A. Divergence Details

### D1: SCC Enforcement

**Root cause:** Multiple containers specify hardcoded UIDs outside OCP's namespace range:
- `inference-operator`: runAsUser=1000, fsGroup=1000
- `model-store`: runAsUser=1000, fsGroup=1000
- `msi-adapter` init container: runAsUser=0, NET_ADMIN, NET_RAW

**Why `privileged` (not just `anyuid`)?** The `msi-adapter` runs as root (UID 0) and requests `NET_ADMIN` + `NET_RAW`. `anyuid` only relaxes UID; `privileged` is needed for capabilities.

**Affected SAs (derived from `--name foundrylocal`):**
```
foundrylocal-inference-operator
foundrylocal-inference-operator-api
foundrylocal-inference-operator-catalog-sync
foundry-config-reader
inference-operator-crd-update
default
```

### D2: StorageClass Config Ignored

The extension does not template `storageClassName` from configuration settings. The PVC spec omits it, causing Kubernetes to use the cluster default.

### D3: Azure Disk CSI on UPI

Cluster provisioned with `credentialsMode: Manual`. CSI driver pods stuck in `Init:0/1` for hours: `secret "azure-disk-credentials" not found`. Org policy (`CredentialTypeNotAllowedAsPerAppPolicy`) prevents creating SP secrets.

### D8: Helm Ownership Labels

Unique to Arc Extension path. The extension install is an atomic Helm release — any pre-existing resources (SAs, etc.) must have:
```yaml
labels:
  app.kubernetes.io/managed-by: Helm
annotations:
  meta.helm.sh/release-name: foundrylocal
  meta.helm.sh/release-namespace: foundry-local-operator
```
Without these, install fails with "invalid ownership metadata."

---

## B. Performance Observations

| Metric | Value |
|--------|-------|
| Extension install time | ~3 min |
| Model download (MCR → OCI store) | ~2 min |
| Pod cold start (init + model load) | ~3 min |
| Inference latency (simple prompts) | 0.3–1.0s |
| API key validation | <10ms |

---

## C. AuthN/AuthZ

### API Key Authentication (Validated ✅)
- Auto-generates keys in Secret (`<deployment>-api-keys`, field `primary-key`)
- Validates via `api-key:` header
- Returns `401 Unauthorized` for invalid keys
- No OCP-specific issues

### Entra ID Integration (Not Tested)
- Potential SCC issues with `msi-adapter` sidecar in Entra mode
- Recommendation: API key auth is the validated path for OCP

---

## D. Reference Documentation

| Document | URL |
|----------|-----|
| Deploy Foundry Local Arc Extension | https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension |
| What is Foundry Local on Azure Local | https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/what-is-foundry-local-on-azure-local |
| Configure Authentication | https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/how-to-configure-authentication |
| Inference Operator Concepts | https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/concept-inference-operator |
| Supported Regions | https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/what-is-foundry-local-on-azure-local#supported-regions |
| Preview Access Request | https://aka.ms/FoundryLocalAzure_PreviewRequest |
| Azure Arc-enabled Kubernetes | https://learn.microsoft.com/azure/azure-arc/kubernetes/overview |
| Arc OpenShift Troubleshooting | https://learn.microsoft.com/azure/azure-arc/kubernetes/troubleshooting#unable-to-connect-openshift-cluster-to-azure-arc |
| Foundry Local on ARO (Reference) | https://github.com/weinong/foundry-local-on-aro/blob/main/docs/validation-report.md |
| OCP SecurityContextConstraints | https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html |
