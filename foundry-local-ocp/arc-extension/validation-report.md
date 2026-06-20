# Foundry Local on Self-Hosted OpenShift (Arc Extension) — Validation Report

Status: **validated end-to-end. Inference round-trip succeeded against `qwen2.5-coder-0.5b` (HTTP 200, TLS, API-key auth).**

This report summarizes the outcome of deploying Foundry Local via the Azure Arc Extension mechanism (`az k8s-extension create --extension-type microsoft.foundry`) on a self-hosted OpenShift Container Platform (UPI install on Azure).

## Reference Documentation

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
| Foundry Local on ARO — Validation Report (Reference) | https://github.com/weinong/foundry-local-on-aro/blob/main/docs/validation-report.md |

---

## Environment

| Item | Value |
|------|-------|
| OpenShift version | 4.21.2 |
| OpenShift Kubernetes | v1.34.2 |
| Container runtime | cri-o://1.34.5 |
| OS | Red Hat Enterprise Linux CoreOS 9.6 |
| Region | Azure (UPI — IPI-like topology) |
| Node pool | 3 × combined master+worker (Standard_D8s_v3) |
| Arc agent version | 1.34.2 |
| Arc connectivity | Connected (`distributionVersion=4.21`) |
| Install method | `az k8s-extension create --extension-type microsoft.foundry` |
| Extension name | `foundrylocal` |
| Validation model | `qwen2.5-coder-0.5b` (ONNX, CPU, ~862 MB) |
| Subscription | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| Resource Group | `rg-openshift-arc` |
| Connected Cluster | `ocp-cluster-arc` |

---

## Phase Results

| Phase | Action | Result |
|-------|--------|--------|
| OCP Cluster | Provisioned via UPI (IPI-like topology on Azure) | ✅ OK — 3 nodes Ready |
| Arc Connect | `az connectedk8s connect --distribution openshift` | ✅ OK — `connectivityStatus=Connected` |
| Pre-create SAs | Helm-labeled ServiceAccounts with `privileged` SCC | ✅ OK — 6 SAs with correct ownership metadata |
| Storage prep | Swap default SC to `local-storage` + hostPath PV | ✅ OK — PV Available, 100Gi |
| Extension install | `az k8s-extension create --extension-type microsoft.foundry` | ✅ OK — provisioningState: Succeeded |
| Pod health | All operator pods Running | ✅ OK — operator 3/3, api 5/5, store 2/2, telemetry 4/4 |
| Model catalog | StoreModels CRD populated | ✅ OK — hardware-filtered (1 CPU model on CPU-only cluster) |
| Model deployment | `qwen2-5-coder-0-5b` via ModelDeployment CR | ✅ OK — Available=True, 5/5 Running |
| Inference call | HTTPS POST to `/v1/chat/completions` with API key | ✅ OK — HTTP 200, correct response |

---

## Inference Validation — 2026-06-19

```
- Model alias: qwen2.5-coder-0.5b
- Deployment name: qwen2-5-coder-0-5b (DNS-1035 sanitized)
- CRD: modeldeployments.foundrylocal.azure.com/v1
- Compute: cpu, runtime: onnx
- Pod replicas: 5/5 Running
- Inference HTTP status: 200
- Protocol: HTTPS (self-signed TLS on port 5000)
- Auth: api-key header (from secret <deploy-name>-api-keys, field primary-key)
- Sample prompt: "What is 2+2?"
- Sample answer: "4"
```

---

## OpenShift Divergences from the AKS-Validated Path

### D1. SCC Enforcement — All Foundry Pods Require `privileged` SCC

| Aspect | AKS Behavior | OCP Behavior |
|--------|-------------|--------------|
| Pod security | PSA (warn/audit only) | SCC enforced — `restricted-v2` by default |
| UID handling | Any UID allowed | Must be within namespace range (1000760000+) |
| Capabilities | Allowed by default | NET_ADMIN, NET_RAW denied unless explicitly granted |

**Impact:** All Foundry pods fail to start. The extension install is **atomic** — entire Helm release rolls back on any pod failure.

**Root cause:** Multiple containers specify hardcoded UIDs outside OCP's namespace range:
- `inference-operator`: runAsUser=1000, fsGroup=1000
- `model-store`: runAsUser=1000, fsGroup=1000
- `msi-adapter` init container: runAsUser=0, NET_ADMIN, NET_RAW

**Workaround:** Pre-create all 6 ServiceAccounts with Helm ownership labels AND `privileged` SCC grants BEFORE extension install:
```bash
# SAs must have these labels/annotations for Helm to accept them:
app.kubernetes.io/managed-by: Helm
meta.helm.sh/release-name: foundrylocal
meta.helm.sh/release-namespace: foundry-local-operator

# Then grant SCC:
oc adm policy add-scc-to-user privileged -z <sa-name> -n foundry-local-operator
```

**Affected SAs (derived from `--name foundrylocal`):**
- `foundrylocal-inference-operator`
- `foundrylocal-inference-operator-api`
- `foundrylocal-inference-operator-catalog-sync`
- `foundry-config-reader`
- `inference-operator-crd-update`
- `default`

### D2. StorageClass Configuration Ignored — Extension Always Uses Default

| Expected | Actual |
|----------|--------|
| `modelStore.storageClassName` config respected | **Completely ignored** — PVC uses cluster default |

**Impact:** If default SC (e.g., `managed-csi`) doesn't work, model-store PVC stays Pending → extension timeout → rollback.

**Workaround:** Temporarily swap the cluster default StorageClass to `local-storage` before installing:
```bash
# Remove default from existing SC
kubectl annotate sc managed-csi storageclass.kubernetes.io/is-default-class- --overwrite
# Set local-storage as default
kubectl annotate sc local-storage storageclass.kubernetes.io/is-default-class=true
```

### D3. Azure Disk CSI Non-Functional (UPI / Manual Credentials)

| IPI Cluster | UPI (credentialsMode: Manual) |
|------------|-------------------------------|
| CSI works (credentials auto-injected) | Fails: `CredentialTypeNotAllowedAsPerAppPolicy` |

**Workaround:** Use local-storage (hostPath PV with node affinity):
1. StorageClass: `local-storage` (no provisioner)
2. PersistentVolume: 100Gi hostPath at `/var/foundry-models`
3. Create directory on target node

### D4. OTEL Telemetry Collector Bug

**Symptom:** Image pull failures or crash loops in telemetry pods without workaround.

**Workaround:** Set `global.telemetry.enabled=false` as extension configuration:
```bash
az k8s-extension create ... \
  --configuration-settings "global.telemetry.enabled=false"
```
Telemetry pods still run (4 replicas) but don't attempt data export. Known bug per Foundry team.

### D5. PV Lifecycle After Failed Install Attempts

After a failed install → rollback, the PV transitions to `Released` state (stale claimRef). Subsequent installs can't bind it.

**Workaround:** Clear claimRef before retry:
```bash
kubectl patch pv <name> --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
```

### D6. Extension Type Discovery Gap

| Expected | Actual |
|----------|--------|
| `Microsoft.FoundryLocal` or `Microsoft.Foundry` | `microsoft.foundry` (lowercase exactly) |

**Discovery:**
```bash
az k8s-extension extension-types list-by-cluster \
  --cluster-name <arc-cluster> --resource-group <rg> \
  --cluster-type connectedClusters --query "[?contains(extensionType,'foundry')]"
```

### D7. ModelDeployment CRD Schema (Arc Extension vs Helm)

| Arc Extension | Older Helm docs |
|---------------|-----------------|
| `apiVersion: foundrylocal.azure.com/v1` | `apiVersion: inference.foundry.azure.com/v1alpha1` |
| `metadata.name` must be DNS-1035 (no dots) | `spec.modelId: "model-name"` |
| `spec.model.catalog.name: "qwen2.5-coder-0.5b"` | N/A |

**Workaround:** Use the current schema:
```yaml
apiVersion: foundrylocal.azure.com/v1
kind: ModelDeployment
metadata:
  name: qwen2-5-coder-0-5b
spec:
  model:
    catalog:
      name: qwen2.5-coder-0.5b
  compute: cpu
```

### D8. Helm Ownership Labels Required on Pre-Created Resources

**Unique to Arc Extension path.** Since the extension install is an atomic Helm release, any pre-existing resources in the namespace must have Helm ownership metadata or the install fails with "invalid ownership metadata."

**Workaround:** All pre-created SAs must include:
```yaml
labels:
  app.kubernetes.io/managed-by: Helm
annotations:
  meta.helm.sh/release-name: foundrylocal
  meta.helm.sh/release-namespace: foundry-local-operator
```

### D9. Namespace UID Range Conflict (Root Cause of D1)

| OCP Namespace UID Range | Foundry Hardcoded UIDs |
|------------------------|----------------------|
| 1000760000–1000769999 | 0 (root), 1000, 101, 10001 |

All Foundry container UIDs fall outside the namespace's allocated range. Only `privileged` SCC permits all of them (UID 0 for msi-adapter needs more than `anyuid`).

---

## Specific Workarounds Applied

| # | Workaround | Problem | Script |
|---|-----------|---------|--------|
| W1 | Pre-create SAs with Helm labels + `privileged` SCC | Arc Extension atomic install rejects pre-existing SAs without ownership metadata | `02-prep-namespace-scc.sh` |
| W2 | Swap default StorageClass to `local-storage` | Extension ignores `modelStore.storageClassName` config | `03-prep-storage.sh` |
| W3 | Create hostPath PV (100Gi) + dir on node | No dynamic provisioner for local-storage | `03-prep-storage.sh` |
| W4 | Set `global.telemetry.enabled=false` | OTEL bug can block atomic install | `04-install-extension.sh` |
| W5 | Clear PV claimRef on retry | PV goes `Released` after rollback | `03-prep-storage.sh` |
| W6 | DNS-1035 sanitize model name (dots → hyphens) | ModelDeployment name validation | `05-deploy-model.sh` |

---

## Performance Observations

| Metric | Value |
|--------|-------|
| Extension install time | ~3 min (including Helm release) |
| Model download (MCR → local OCI store) | ~2 min |
| Pod cold start (init + model load) | ~3 min |
| Inference latency (simple prompts) | 0.3–1.0s |
| API key validation | <10ms |
| TLS handshake (self-signed) | Negligible |

---

## Recommendations to Foundry Local Team

### High Priority (Blocking for OpenShift adoption)

| # | Improvement | Rationale |
|---|-------------|-----------|
| 1 | **Honor `modelStore.storageClassName` config** | Single most impactful fix — currently ignored on every non-AKS platform |
| 2 | **Reduce SCC requirements** | Drop `runAsUser: 0` from msi-adapter; use configurable UIDs or inherit namespace range |
| 3 | **Document OpenShift deployment path** | Zero official docs exist for OCP; this repo is the only reference |
| 4 | **Fix telemetry flag** | `global.telemetry.enabled=false` should prevent pod creation, not just disable data export |

### Medium Priority (Usability)

| # | Improvement | Rationale |
|---|-------------|-----------|
| 5 | **Document DNS-1035 name requirement** | ModelDeployment name silently rejected with dots; no guidance in docs |
| 6 | **Document CRD schema changes** | `foundrylocal.azure.com/v1` vs old `inference.foundry.azure.com/v1alpha1` undocumented |
| 7 | **Document extension type name** | `microsoft.foundry` only discoverable via API query |
| 8 | **Support OCP Routes natively** | Add `endpoint.type=route` for OpenShift-native external access |

### Low Priority (Nice to Have)

| # | Improvement | Rationale |
|---|-------------|-----------|
| 9 | **OLM Operator packaging** | OCP users expect OperatorHub install with automatic SCC lifecycle |
| 10 | **Integration with OCP service-ca** | Eliminate cert-manager dependency for OCP-native TLS |
| 11 | **Full model catalog CRD** | `storemodels` only shows hardware-filtered subset; no way to browse full 173+ catalog |

---

## AuthN/AuthZ & RBAC

### API Key Authentication (Working)

Foundry Local's built-in API key auth works correctly on OCP with no modifications:
- Auto-generates primary/secondary keys stored in K8s Secret (`<deployment>-api-keys`)
- Validates via `api-key:` header
- Returns proper `401 Unauthorized` for invalid keys

**No OCP-specific issues.** Cluster-internal; doesn't conflict with OCP's OAuth proxy.

### Entra ID Integration (Not Tested)

When `entraAuth.enabled=true`, potential OCP issues:
- OCP clusters typically use their own identity provider (LDAP, OIDC, HTPasswd)
- The `msi-adapter` sidecar in Entra mode may have additional SCC requirements

**Recommendation:** For OCP deployments, API key auth (`entraAuth.enabled=false`) is the validated path.

---

## Conclusion

**Foundry Local successfully deploys and runs on self-hosted OpenShift 4.21 via Arc Extension** with manual workarounds.

### What Works Well
- Arc Extension install (atomic, managed lifecycle)
- StoreModels CRD for hardware-filtered catalog
- Model download and serving (CPU/ONNX, ~3 min cold start)
- API key authentication (auto-generated, properly enforced)
- TLS on model service (self-signed cert, port 5000)
- OpenAI-compatible API (`/v1/chat/completions`, `/v1/models`)

### What Requires Manual Intervention
- **6 SCC grants across 6 ServiceAccounts** with Helm ownership labels (undocumented)
- **StorageClass swap** — extension ignores config, uses cluster default
- **Local-storage PV** — no dynamic provisioner, manual hostPath
- **Telemetry disable** — must set config flag to avoid OTEL issues
- **Model name sanitization** — dots not allowed in deployment name

### Fundamental Gap
Foundry Local's security model assumes **Kubernetes Pod Security Standards** (namespace-level labels). OpenShift uses **Security Context Constraints** (per-ServiceAccount grants). These are incompatible admission control systems. The Arc Extension's atomic install makes this worse — there's no opportunity to fix SCC issues mid-install; everything must be pre-configured correctly.

The platform is viable for on-premises AI inference on Red Hat OpenShift with Azure Arc connectivity, but requires OCP-specific operational knowledge not currently documented by the Foundry Local team.
