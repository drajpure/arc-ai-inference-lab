# Foundry Local on Self-Hosted OpenShift (Helm Standalone) — Validation Report

Status: **✅ Validated end-to-end. Inference round-trip succeeded against `qwen2.5-coder-0.5b` (HTTP 200, TLS, API-key auth).**

Install Method: Direct Helm chart from `oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator`

---

## Environment

| Item | Value |
|------|-------|
| OpenShift | 4.21.2 (Kubernetes v1.34.2, CRI-O 1.34.5) |
| Nodes | 3 × master+worker (Standard_D8s_v3, CPU-only) |
| Azure Arc | Connected (`distributionVersion=4.21`) |
| cert-manager | v1.19.2 (Jetstack upstream) |
| trust-manager | v0.20.3 (Jetstack upstream) |
| Operator chart | `0.260430.8` from MCR |
| Model | `qwen2.5-coder-0.5b` (ONNX, CPU, ~862 MB) |

---

## Phase Results

| Phase | Result |
|-------|--------|
| OCP Cluster provisioned (3 nodes) | ✅ |
| Arc connected (12 pods Running) | ✅ |
| cert-manager + trust-manager installed (Jetstack) | ✅ |
| Phase 1 SCC grants (before Helm install) | ✅ |
| Helm install inference-operator | ✅ |
| Phase 2 SCC grants (after Helm install) | ✅ |
| Model catalog sync (173 models available) | ✅ |
| Model deployed (`qwen2.5-coder-0.5b`), Ready=True | ✅ |
| Inference: HTTPS POST → HTTP 200, correct response | ✅ |
| E2E test suite: 8/8 passed (100%) | ✅ |

---

## Inference Validation — 2026-05-21

```
Model:      qwen2.5-coder-0.5b
Catalog ID: qwen2.5-coder-0.5b-instruct-generic-cpu:4
Compute:    cpu, runtime: onnx-genai
Protocol:   HTTPS (cert-manager issued TLS, port 5000)
Auth:       api-key header (secret: <deployment>-api-keys)
Cold start: ~2 min (including 29s model download, 862 MB)
Prompt:     "Hello"
Response:   "Hello! How can I assist you today?" (HTTP 200)
```

---

## E2E Test Results — 8/8 PASSED

| # | Test | Status | Duration |
|---|------|--------|----------|
| 1 | Basic Chat Completion | ✅ | 0.6–1.0s |
| 2 | System + User Prompt (code gen) | ✅ | 2.4–3.0s |
| 3 | Temperature 0 (Deterministic) | ✅ | 0.4–0.9s |
| 4 | Multi-turn Conversation | ✅ | 0.5–1.2s |
| 5 | Max Tokens Limit | ✅* | 7.3–11.0s |
| 6 | List Models (GET /v1/models) | ✅ | 0.3–0.8s |
| 7 | Auth — Invalid API Key (401) | ✅ | 0.3–0.8s |
| 8 | Error — Empty Messages (400) | ✅ | 0.3–0.9s |

*Test 5 caveat: ONNX GenAI runtime does not strictly enforce `max_tokens` — model may produce 20+ tokens with `finish_reason: "stop"` instead of `"length"`. Test passes because it only checks for `finish_reason` presence.

---

## Key Divergences from AKS

| # | Divergence | Severity | Workaround |
|---|-----------|----------|-----------|
| D1 | Two-phase SCC grants required (UIDs 0/1000 + NET_ADMIN) | 🔴 Blocking | Phase 1 before install, Phase 2 after |
| D2 | Azure Disk CSI broken on UPI/Manual credential clusters | 🔴 Env-specific | `local-storage` SC + hostPath PV |
| D3 | `Microsoft.CertManagement` Arc extension broken on CRI-O | 🔴 Blocking | Use upstream Jetstack charts |
| D4 | `telemetry-collector` needs `privileged` SCC for msi-adapter | 🟡 Partial | Grant privileged SCC to `default` SA |
| D5 | Arc extension type preview-gated | 🟡 Workaround | Use public OCI helm chart from MCR |
| D6 | PSS namespace labels have no effect on OCP | ℹ️ Info | SCC is the admission mechanism on OCP |
| D7 | `oc` CLI required for SCC grants | ℹ️ Info | Download from Red Hat mirror |

---

## Workarounds Applied

| # | What | Script |
|---|------|--------|
| W1 | Two-phase SCC: `default` + `foundry-config-reader` before install; `inference-operator` + `catalog-sync` after | `04` + `06` |
| W2 | `local-storage` SC + hostPath PV (100Gi at `/var/foundry-models`) | manifests/ |
| W3 | Upstream cert-manager v1.19.2 + trust-manager v0.20.3 | `03` |
| W4 | `--set global.storage.storageClass=local-storage` | `05` |
| W5 | `--set global.telemetry.enabled=false` | `05` |
| W6 | Query catalog ConfigMap for correct model aliases | `07` |

---

## Recommendations to Foundry Team

| Priority | Recommendation |
|----------|---------------|
| 🔴 High | Add `openshift.enabled=true` Helm value with automatic SCC resource creation |
| 🔴 High | Pre-create all SAs in pre-install hooks (eliminate two-phase SCC) |
| 🔴 High | Make container UIDs configurable (or remove hardcoded 1000) |
| 🔴 High | Document OpenShift deployment path |
| 🟡 Medium | Document helm-chart install as primary path (not gated) |
| 🟡 Medium | Fix `Microsoft.CertManagement` extension for CRI-O |
| 🟡 Medium | StorageClass validation before PVC creation |
| ⚪ Low | OLM Operator packaging for OperatorHub |
| ⚪ Low | Integration with OCP service-ca |
| ⚪ Low | Strict `max_tokens` enforcement in ONNX GenAI runtime |

---

## Conclusion

**Foundry Local works on self-hosted OpenShift 4.21 via direct Helm install** with 6 workarounds. The fundamental gap: Foundry assumes Kubernetes PSS (namespace labels) while OpenShift uses SCC (per-SA grants) — incompatible admission systems. Adding `--set openshift.enabled=true` with automatic SCC creation would make OCP a first-class target.

---
---

# Appendix

## A. Divergence Details

### D1: Two-Phase SCC Grants

**Root cause:** Foundry containers hardcode UIDs outside OCP namespace range:
- `inference-operator`: runAsUser=1000, fsGroup=1000
- `model-store`: runAsUser=1000, runAsGroup=1000, fsGroup=1000
- `msi-adapter` init: runAsUser=0, NET_ADMIN, NET_RAW

**Chicken-and-egg:** Chart creates SAs during install, but pre-install Job runs under `default` SA. Must grant SCC to `default` BEFORE install, then to operator SAs AFTER.

```bash
# Phase 1 (before helm install):
oc adm policy add-scc-to-user privileged -z default -n foundry-local-operator
oc adm policy add-scc-to-user privileged -z foundry-config-reader -n foundry-local-operator

# Phase 2 (after helm install):
oc adm policy add-scc-to-user privileged -z inference-operator -n foundry-local-operator
oc adm policy add-scc-to-user privileged -z inference-operator-catalog-sync -n foundry-local-operator
```

### D3: Microsoft.CertManagement Arc Extension Broken on CRI-O

Three independent blockers:
1. **Deprecated seccomp annotations** — OCP SCC rejects `seccomp.security.alpha.kubernetes.io/pod`
2. **hostPath volumes** — default SCCs forbid hostPath
3. **Nested OCI index image** — CRI-O can't pull `otel-collector-internal` sidecar

**Fix:** Use upstream `jetstack/cert-manager` + `jetstack/trust-manager` directly.

### D5: Preview-Gated Arc Extension

`az k8s-extension create --extension-type microsoft.foundry` returns "doesn't have any supporting artifacts" without subscription allowlisting.

**Fix:** The OCI helm chart on MCR is public (not gated):
```bash
helm install inference-operator \
  oci://mcr.microsoft.com/microsoft.foundry/foundrylocalenabledbyarc/helmcharts/helm/inference-operator \
  --version 0.260430.8 --namespace foundry-local-operator
```

---

## B. Performance Observations

| Metric | Value |
|--------|-------|
| Average inference latency (simple prompts) | 0.3–0.6s |
| Average inference latency (code generation) | ~2.4s |
| Model download (MCR → local OCI store) | ~29s (862 MB) |
| Pod cold start (init + model load) | ~2 min |
| API key validation | <10ms |

---

## C. AuthN/AuthZ

### API Key Authentication (Validated ✅)
- Auto-generates primary/secondary keys in Secret (`<deployment>-api-keys`)
- Validates via `api-key` header or `Authorization: Bearer` header
- Returns `401 Unauthorized` for invalid keys
- No OCP-specific issues

### Entra ID Integration (Not Tested)
- When `entraAuth.enabled=true`, potential OCP issues with identity providers
- Recommendation: API key auth (`entraAuth.enabled=false`) is the validated path

### Security Model Comparison

| Aspect | Foundry Assumption | OpenShift Reality |
|--------|-------------------|-------------------|
| Pod admission | Kubernetes PSS labels | SCC per-ServiceAccount grants |
| UID/GID | Hardcoded 1000 | Allocated from namespace range (1000760000+) |
| Capabilities | NET_ADMIN allowed | Only `privileged` SCC permits |
| Authorization | Single layer: RBAC | Two layers: RBAC + SCC |
| TLS | cert-manager via Arc extension | Arc ext broken on CRI-O |

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
| OpenShift Install on Azure (IPI) | https://docs.openshift.com/container-platform/latest/installing/installing_azure/ipi/installing-azure-default.html |
| OCP SecurityContextConstraints | https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html |
