# Foundry Local on Self-Hosted OpenShift (Arc Extension) — Validation Report

**Status:** ✅ Validated end-to-end. Inference round-trip succeeded against `qwen2.5-coder-0.5b` (HTTP 200, TLS, **both API-key and Entra ID token auth**).

**Install Method:** `az k8s-extension create --extension-type microsoft.foundry` with Entra ID enabled

**Validation Date:** 2026-06-19

---

## 1. Environment

| Component | Value |
|-----------|-------|
| OpenShift | 4.21.2 |
| Kubernetes | v1.34.2 |
| CRI-O | 1.34.5 |
| Infrastructure | Azure IaaS (UPI install, `credentialsMode: Manual`) |
| Nodes | 3 × Standard_D8s_v3 (8 vCPU, 32 GB RAM, CPU-only, no GPU) |
| Topology | 3 master+worker (compact cluster, no dedicated infra nodes) |
| Azure Arc Agent | Connected (`distributionVersion=4.21`, `infrastructure=azure`) |
| Extension type | `microsoft.foundry` |
| Extension name | `foundrylocal` |
| Entra Auth | Enabled (`entraAuth.clientId=ea139b1c-c20d-4395-adb5-4757a618be7c`) |
| Operator namespace | `foundry-local-operator` |
| cert-manager | v1.19.2 (Jetstack upstream Helm chart) |
| trust-manager | v0.20.3 (Jetstack upstream Helm chart) |
| Model | `qwen2.5-coder-0.5b` (ONNX Runtime, CPU inference, ~862 MB) |

### Cluster Provisioning

```bash
# Azure IaaS: 3× Standard_D8s_v3, RHCOS, UPI install
openshift-install create cluster --dir=ocp-install --log-level=info
# credentialsMode: Manual (no cloud credential operator)
# No Azure Disk CSI secrets seeded → managed-csi SC non-functional
```

### Arc Connection

```bash
az connectedk8s connect \
  --name ocp-arc-foundry \
  --resource-group rg-ocp-foundry \
  --distribution openshift \
  --infrastructure azure
# Result: connectivityStatus=Connected, distributionVersion=4.21
```

---

## 2. Phase Results (Step-by-Step)

| # | Phase | Command / Script | Result | Duration |
|---|-------|-----------------|--------|----------|
| 1 | OCP Cluster provisioned | `openshift-install create cluster` | ✅ 3 nodes Ready | ~45 min |
| 2 | Arc connected | `az connectedk8s connect --distribution openshift` | ✅ Connected | ~3 min |
| 3 | cert-manager + trust-manager | `helm upgrade --install` (Jetstack charts) | ✅ All pods Running | ~2 min |
| 4 | Namespace + SCC grants | `02-prep-namespace-scc.sh` → 6 SAs with privileged SCC | ✅ | ~10 sec |
| 5 | Storage (local-storage + PV) | `03-prep-storage.sh` → SC swap + 100Gi hostPath PV | ✅ PV Available | ~15 sec |
| 6 | Extension install (Entra ID) | `az k8s-extension create` + `entraAuth.clientId` + `entraAuth.tenantId` | ✅ Succeeded | ~2.5 min |
| 7 | Pod readiness | All operator/store/telemetry pods Running | ✅ 14 pods total | ~1 min |
| 8 | Model deployment | `ModelDeployment` CR applied → Available=True | ✅ | ~2 min |
| 9 | Inference (API key) | HTTPS POST with `api-key:` header → HTTP 200 | ✅ | <1 sec |
| 10 | Inference (Entra ID) | HTTPS POST with `Authorization: Bearer` → HTTP 200 | ✅ | <1 sec |
| 11 | Auth rejection | Invalid/missing token → HTTP 401 | ✅ | <1 sec |

### Pod Inventory (post-install)

```
NAMESPACE                  NAME                                           READY   STATUS    REPLICAS
foundry-local-operator     foundrylocal-inference-operator-*              1/1     Running   3
foundry-local-operator     foundrylocal-inference-operator-api-*          2/2     Running   5
foundry-local-operator     foundrylocal-model-store-*                     1/1     Running   2
foundry-local-operator     foundrylocal-telemetry-collector-*             1/1     Running   4
foundry-local-operator     qwen2-5-coder-0-5b-*                          1/1     Running   1
                                                                          TOTAL: 15 pods
```

**Container counts per pod:**
- `inference-operator`: 1 container (inference-operator)
- `inference-operator-api`: 2 containers (inference-operator-api + msi-adapter init)
- `model-store`: 1 container (model-store OCI registry)
- `telemetry-collector`: 1 container (OpenTelemetry collector)
- `qwen2-5-coder-0-5b`: 1 container (ONNX Runtime inference server)

---

## 3. Inference Validation Details

### Request (API Key)

```bash
curl -sk "https://localhost:5000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "api-key: $(kubectl get secret qwen2-5-coder-0-5b-api-keys -n foundry-local-operator \
       -o jsonpath='{.data.primary-key}' | base64 -d)" \
  -d '{
    "model": "qwen2-5-coder-0-5b",
    "messages": [{"role": "user", "content": "What is 2+2? Answer with just the number."}],
    "max_tokens": 50
  }'
```

### Request (Entra ID Token)

```bash
# Acquire token using Azure CLI (pre-authorized in Step 4 of Entra setup)
TOKEN=$(az account get-access-token \
  --resource "api://ea139b1c-c20d-4395-adb5-4757a618be7c" \
  --query accessToken -o tsv)

curl -sk "https://localhost:5000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "model": "qwen2-5-coder-0-5b",
    "messages": [{"role": "user", "content": "What is 2+2? Answer with just the number."}],
    "max_tokens": 50
  }'
```

### Response (both methods return identical format)

```json
{
  "model": "qwen2.5-coder-0.5b-instruct-generic-cpu:4",
  "choices": [{
    "message": {"role": "assistant", "content": "4"},
    "index": 0,
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 42, "completion_tokens": 1, "total_tokens": 43},
  "id": "chat.id.1",
  "object": "chat.completion",
  "successful": true
}
```

### Validated Inference Properties

| Property | Value |
|----------|-------|
| Protocol | HTTPS (self-signed TLS, port 5000) |
| Auth mechanism 1 | `api-key` header (auto-generated key in Secret) |
| Auth mechanism 2 | `Authorization: Bearer <entra-jwt>` (v2.0 token with `scp: foundry_access`) |
| Secret name | `<deployment-name>-api-keys` |
| Secret field | `primary-key` (base64-encoded) |
| Entra App Client ID | `ea139b1c-c20d-4395-adb5-4757a618be7c` |
| Entra Token Resource | `api://ea139b1c-c20d-4395-adb5-4757a618be7c` |
| API compatibility | OpenAI Chat Completions (`/v1/chat/completions`) |
| CRD group | `foundrylocal.azure.com` |
| CRD version | `v1` |
| CRD kind | `ModelDeployment` |
| Readiness condition | `type: Available`, `status: "True"` |
| Service port | 5000 (model pod exposes HTTPS directly) |
| Invalid api-key | HTTP 401 `{"error":{"code":"invalid_token"}}` |
| Invalid Bearer token | HTTP 401 `{"error":{"code":"invalid_token","message":"Token validation failed"}}` |
| Missing auth header | HTTP 401 `{"error":{"code":"missing_credentials"}}` |
| Wrong model name | HTTP 404 (model not found) |

---

## 4. Key Divergences from AKS (D1–D11)

These are behaviors where Foundry Local on OCP diverges from the documented AKS experience. Each divergence has a severity (🔴 Blocking install, 🟡 Partial/Operational, ⚪ Cosmetic/Doc) and a workaround.

| # | Divergence | Severity | Root Cause | Workaround |
|---|-----------|----------|-----------|-----------|
| D1 | SCC enforcement — all pods require `privileged` SCC | 🔴 Blocking | Hardcoded UIDs + `NET_ADMIN` capabilities | Pre-create 6 SAs with SCC rolebindings + Helm labels |
| D2 | `modelStore.storageClassName` config setting is ignored | 🔴 Blocking | PVC template omits `storageClassName` field | Swap cluster default SC to `local-storage` |
| D3 | Azure Disk CSI broken on UPI/Manual credential clusters | 🔴 Blocking | No `azure-disk-credentials` secret + org policy blocks SP | Use hostPath PV with node affinity |
| D4 | Pre-created resources MUST have Helm ownership labels | 🔴 Blocking | Atomic install fails with "invalid ownership metadata" | Label SAs with `managed-by: Helm` + release annotations |
| D5 | `Microsoft.CertManagement` Arc extension broken on CRI-O | 🔴 Blocking | Deprecated seccomp annotations, hostPath mounts, nested OCI | Use upstream Jetstack cert-manager + trust-manager Helm charts |
| D6 | `model-store` and model pods use `default` SA instead of dedicated SAs | 🟡 Security | Helm chart Deployments don't set `serviceAccountName` | Grant `privileged` SCC to `default` SA in namespace (not ideal — upstream fix needed) |
| D7 | OTEL telemetry collector bugs | 🟡 Operational | Collector fails to initialize when no OTEL endpoint configured | `global.telemetry.enabled=false` (pods still created) |
| D8 | PV enters `Released` state after atomic rollback | 🟡 Operational | Helm rollback deletes PVC but PV retains stale `claimRef` | `kubectl patch pv --type=json` to clear claimRef |
| D9 | Extension type must be exact lowercase `microsoft.foundry` | ⚪ Doc gap | ARM resource type is case-sensitive | Use exact string in `az k8s-extension create` |
| D10 | CRD API is `foundrylocal.azure.com/v1` not `inference.foundry.azure.com/v1alpha1` | ⚪ Doc gap | New API version, old blogs/docs reference deprecated API | Use `apiVersion: foundrylocal.azure.com/v1` |
| D11 | ModelDeployment name must be DNS-1035 (no dots, no uppercase) | ⚪ Doc gap | Kubernetes validation rejects names with `.` in them | Sanitize: `echo "$model" \| tr '.' '-' \| tr '[:upper:]' '[:lower:]'` |

---

## 5. Divergence Deep-Dives

### D1: SCC Enforcement (🔴 Blocking)

**Problem:** OpenShift uses SecurityContextConstraints (SCC) instead of Kubernetes Pod Security Standards (PSS). The Foundry Local Helm chart hardcodes security contexts that violate the default `restricted` SCC.

**Specific violations observed:**

| Pod | Container | UID | Capabilities | SCC Violation |
|-----|-----------|-----|-------------|---------------|
| inference-operator | inference-operator | `runAsUser: 1000` | None | UID outside namespace range (OCP allocates 1000660000+) |
| inference-operator-api | inference-operator-api | `runAsUser: 1000` | None | UID outside namespace range |
| inference-operator-api | msi-adapter (init) | `runAsUser: 0` | `NET_ADMIN`, `NET_RAW` | Root UID + Linux capabilities |
| model-store | model-store | `runAsUser: 1000, fsGroup: 1000` | None | UID + fsGroup outside range |
| telemetry-collector | otel-collector | `runAsUser: 1000` | None | UID outside namespace range |
| telemetry-collector | msi-adapter (init) | `runAsUser: 0` | `NET_ADMIN`, `NET_RAW` | Root UID + Linux capabilities |

**Why `privileged` and not `anyuid`:**
- `anyuid` SCC only relaxes the UID constraint (allows running as any user)
- `privileged` SCC is required because the `msi-adapter` init container requests `NET_ADMIN` and `NET_RAW` capabilities, which are only allowed under `privileged`
- Even `nonroot-v2` won't work because the msi-adapter explicitly sets `runAsUser: 0`

**ServiceAccount naming convention (derived from `--name foundrylocal`):**
```
system:serviceaccount:foundry-local-operator:foundrylocal-inference-operator
system:serviceaccount:foundry-local-operator:foundrylocal-inference-operator-api
system:serviceaccount:foundry-local-operator:foundrylocal-inference-operator-catalog-sync
system:serviceaccount:foundry-local-operator:foundry-config-reader
system:serviceaccount:foundry-local-operator:inference-operator-crd-update
system:serviceaccount:foundry-local-operator:default
```

**Workaround implementation:**
```bash
# For each SA: create with Helm labels, then bind to privileged SCC
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: foundrylocal-inference-operator
  namespace: foundry-local-operator
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: foundrylocal
    meta.helm.sh/release-namespace: foundry-local-operator
EOF

kubectl create rolebinding scc-privileged-foundrylocal-inference-operator \
  --clusterrole=system:openshift:scc:privileged \
  --serviceaccount=foundry-local-operator:foundrylocal-inference-operator \
  -n foundry-local-operator
```

**Risk assessment:** Granting `privileged` SCC is a significant security relaxation. It gives pods root access, all Linux capabilities, and host namespace access. In a production environment, this should be scoped to the `foundry-local-operator` namespace only, and the Foundry team should work toward dropping root from `msi-adapter`.

---

### D2: StorageClass Config Ignored (🔴 Blocking)

**Problem:** The `az k8s-extension create` command accepts `--configuration-settings "modelStore.storageClassName=..."` but the Helm chart template does NOT reference this value. The PVC manifest is:

```yaml
# Actual PVC created by the extension (captured via kubectl get pvc -o yaml):
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: foundrylocal-model-store
  namespace: foundry-local-operator
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 100Gi
  # NOTE: storageClassName is ABSENT — Kubernetes uses cluster default SC
```

**Impact:** On AKS, the default SC (`managed-csi`) works. On OCP UPI where `managed-csi` is broken (D3), the PVC pends forever, the model-store pod can't start, and the atomic install rolls back the entire extension.

**Workaround:** Swap the cluster default StorageClass to one that works:
```bash
# Remove default annotation from managed-csi
kubectl annotate sc managed-csi storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
# Set local-storage as default
kubectl annotate sc local-storage storageclass.kubernetes.io/is-default-class=true
```

---

### D3: Azure Disk CSI on UPI/Manual Credential Clusters (🔴 Blocking)

**Problem:** OCP cluster provisioned with `credentialsMode: Manual` (required by some org policies). The Cloud Credential Operator does not automatically provision cloud provider secrets. Azure Disk CSI driver pods are stuck:

```
$ kubectl get pods -n openshift-cluster-csi-drivers
NAME                                             READY   STATUS     RESTARTS
azure-disk-csi-driver-controller-*               0/6     Init:0/1   0
azure-disk-csi-driver-node-*                     0/3     Init:0/1   0

$ kubectl logs azure-disk-csi-driver-controller-* -c csi-provisioner -n openshift-cluster-csi-drivers
E0617 ... secret "azure-disk-credentials" not found in namespace "openshift-cluster-csi-drivers"
```

**Org policy block:**
```
Error creating SP: CredentialTypeNotAllowedAsPerAppPolicy - The credential type is not allowed as per app policy.
```

**Impact:** PVCs requesting `managed-csi` will pend indefinitely. Combined with D2, this means the extension can never bind its model-store PVC.

**Workaround:** Create a `local-storage` StorageClass + manually provision a hostPath PV:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: foundry-model-store-pv
spec:
  capacity:
    storage: 100Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /var/foundry-models
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: ["ocp-worker-0"]
```

**Trade-off:** Model-store pod is pinned to a single node. In multi-node clusters, this limits HA. For production, use a CSI driver that works (e.g., NFS, or fix managed-csi credentials).

---

### D4: Helm Ownership Labels (🔴 Blocking)

**Problem:** The Arc extension installation is an atomic Helm release. When pre-created resources (ServiceAccounts) exist in the namespace WITHOUT proper Helm ownership metadata, the install fails immediately with:

```
Error: rendered manifests contain a resource that already exists. 
Unable to continue with install: existing resource conflict: 
namespace "foundry-local-operator" is owned by another release
```

Or with incorrect labels:
```
Error: invalid ownership metadata; label validation error: 
missing key "app.kubernetes.io/managed-by": must be set to "Helm"
```

**Required metadata on ALL pre-created resources:**
```yaml
metadata:
  labels:
    app.kubernetes.io/managed-by: Helm        # REQUIRED — exact value
  annotations:
    meta.helm.sh/release-name: foundrylocal    # Must match --name param
    meta.helm.sh/release-namespace: foundry-local-operator  # Must match namespace
```

**Why this is unique to Arc Extension (not Helm standalone):**
In the direct Helm path, you control the install command and can use `--force` or delete conflicting resources. In the Arc Extension path, the Helm install is executed by the Arc agent — you have zero control over Helm flags. The agent uses strict ownership checking with no override.

---

### D5: Microsoft.CertManagement Arc Extension Broken on CRI-O (🔴 Blocking)

**Problem:** The official docs recommend installing cert-manager via the `Microsoft.CertManagement` Arc extension:
```bash
az k8s-extension create --extension-type microsoft.certmanager ...
```

This extension DOES NOT work on OpenShift/CRI-O due to:

1. **Deprecated seccomp annotations:** Container spec uses `seccomp.security.alpha.kubernetes.io/pod` annotation (deprecated since Kubernetes 1.19, removed in 1.27). OCP 4.21 ignores this annotation entirely.

2. **hostPath volume mounts:** The packaged cert-manager requests hostPath volumes that violate OCP's restricted SCC.

3. **Nested OCI manifests:** The extension's container images use nested OCI manifest lists that CRI-O handles differently from containerd, causing image pull failures on some versions.

**Workaround:** Install upstream Jetstack Helm charts directly:
```bash
helm repo add jetstack https://charts.jetstack.io --force-update

# cert-manager
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.19.2 \
  --set crds.enabled=true --set crds.keep=true \
  --wait --timeout 5m

# trust-manager (AFTER cert-manager pods are ready)
helm upgrade --install trust-manager jetstack/trust-manager \
  --namespace cert-manager \
  --version v0.20.3 \
  --set defaultPackage.enabled=false \
  --set secretTargets.enabled=true \
  --set secretTargets.authorizedSecretsAll=true \
  --wait --timeout 5m
```

**Critical trust-manager settings:**
- `secretTargets.enabled=true` — allows trust-manager to write TLS bundles as Kubernetes Secrets (not just ConfigMaps)
- `secretTargets.authorizedSecretsAll=true` — grants trust-manager permission to write secrets in any namespace (required because Foundry Local expects cert bundles in `foundry-local-operator` namespace, not `cert-manager`)

Without these two settings, the Foundry Local operator will fail to start with certificate errors.

---

### D6: Model-Store and Model Pods Use `default` ServiceAccount (🟡 Security)

**Problem:** The Foundry Local Helm chart does not set `spec.serviceAccountName` on the `foundrylocal-model-store` Deployment or the dynamically-created model Deployments (e.g., `qwen2-5-coder-0-5b`). They default to the `default` SA:

```
$ kubectl get pods -n foundry-local-operator -o custom-columns="POD:.metadata.name,SA:.spec.serviceAccountName"
POD                                                    SA
foundrylocal-inference-operator-696964bd5c-t8jsk       foundrylocal-inference-operator    ✅
foundrylocal-inference-operator-api-57f65d4685-295b2   foundrylocal-inference-operator-api ✅
foundrylocal-model-store-f654f9c7d-9jj5q               default                            ⚠️
qwen2-5-coder-0-5b-68f874ccc-lb7rw                     default                            ⚠️
telemetry-collector-6f9fc58688-dw766                   foundrylocal-inference-operator    ✅
```

**Security concern:** On OCP, granting `privileged` SCC to the `default` SA means ANY pod in the namespace (including unintentional ones) would inherit elevated permissions. Best practice is to use dedicated SAs per workload.

**Current workaround:** In `03-prep-namespace-scc.sh`, the `default` SA in the namespace is also bound to `privileged` SCC, which allows model-store and model pods to start. This is necessary but overly broad.

**Recommendation to Foundry Local team:** The Helm chart should:
1. Create dedicated SAs (e.g., `foundrylocal-model-store`, `foundrylocal-model-inference`)
2. Set `spec.serviceAccountName` on the model-store Deployment
3. Set `spec.serviceAccountName` on dynamically-created model Deployments (via the operator's pod template)

**Impact:** This does not block functionality — pods work fine with `default` SA + privileged SCC. But it violates the principle of least privilege and would fail a security review for production workloads on multi-tenant OCP clusters.

---

### D7: OTEL Telemetry Collector Bug (🟡 Operational)

**Problem:** With telemetry enabled, the OTEL collector pod enters CrashLoopBackOff when no valid OTEL endpoint is configured. Error observed:

```
Error: cannot start pipelines: failed to start exporters: failed to start exporter "otlp/azure_monitor": 
  context deadline exceeded: failed to export traces
```

**Workaround:** Disable at install time:
```bash
az k8s-extension create ... --configuration-settings "global.telemetry.enabled=false"
```

**Caveat:** This flag does NOT prevent telemetry pods from being created — 4 collector replicas still run. The flag only disables data collection within them. The pods run idle.

---

### D8: PV `Released` State After Rollback (🟡 Operational)

**Problem:** When the atomic install fails (e.g., SCC issue missed), Helm rolls back and deletes all resources including the PVC. But the PV retains a `spec.claimRef` pointing to the now-deleted PVC, putting the PV in `Released` state. On retry, the new PVC can't bind to a `Released` PV.

**Detection:**
```bash
$ kubectl get pv foundry-model-store-pv
NAME                      CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM
foundry-model-store-pv    100Gi      RWO            Retain           Released   foundry-local-operator/foundrylocal-model-store
```

**Fix:**
```bash
kubectl patch pv foundry-model-store-pv --type=json \
  -p '[{"op":"remove","path":"/spec/claimRef"}]'
# PV transitions: Released → Available
```

---

### D11: ModelDeployment DNS-1035 Naming (⚪ Doc gap)

**Problem:** Model catalog names like `qwen2.5-coder-0.5b` contain dots. Kubernetes resource names must comply with DNS-1035 (RFC 1035: `[a-z]([-a-z0-9]*[a-z0-9])?`). Dots are invalid.

**Error when using dots:**
```
The ModelDeployment "qwen2.5-coder-0.5b" is invalid: 
metadata.name: Invalid value: "qwen2.5-coder-0.5b": 
a DNS-1035 label must consist of lower case alphanumeric characters or '-', 
start with an alphabetic character, and end with an alphanumeric character
```

**Workaround:** Sanitize the model name before creating the CR:
```bash
DEPLOY_NAME=$(echo "$MODEL_ALIAS" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
# "qwen2.5-coder-0.5b" → "qwen2-5-coder-0-5b"
```

The `spec.model.catalog.name` field retains the original name with dots — only `metadata.name` must be DNS-compliant.

---

## 6. Workarounds Summary

| # | What | Script | Lines of Code | Reversible? |
|---|------|--------|---------------|-------------|
| W1 | Pre-create 6 SAs with Helm labels + bind `privileged` SCC | `03-prep-namespace-scc.sh` | ~60 lines | Yes (`10-uninstall.sh` removes) |
| W2 | Swap cluster default SC to `local-storage` | `04-prep-storage.sh` | ~20 lines | Yes (swap back) |
| W3 | Create `local-storage` SC + hostPath PV (100Gi) + host dir | `04-prep-storage.sh` | ~60 lines | Yes (delete PV/SC) |
| W4 | `global.telemetry.enabled=false` at install time | `05-install-extension.sh` | 1 flag | N/A (install-time config) |
| W5 | Clear PV `claimRef` if state = Released | `05-install-extension.sh` | 5 lines | Automatic |
| W6 | DNS-1035 name sanitization (dots → hyphens) | `06-deploy-model.sh` | 1 line | N/A |
| W7 | Upstream cert-manager + trust-manager (Jetstack) | `02-install-cert-manager.sh` | ~90 lines | Yes (helm uninstall) |
| W8 | Bind `default` SA to `privileged` SCC (for model-store + model pods) | `03-prep-namespace-scc.sh` | ~5 lines | Yes (remove rolebinding) |

---

## 7. End-to-End Installation Flow

```text
+=========================================================================+
|                       INSTALLATION SEQUENCE                             |
+=========================================================================+
|                                                                         |
|  +-------------------+       +--------------------------+               |
|  | 01-connect-arc.sh |------>| 02-install-cert-manager  |               |
|  |                   |       |   cert-manager v1.19.2   |               |
|  | * Register provs  |       |   trust-manager v0.20.3  |               |
|  | * Create RG       |       |   (Jetstack Helm charts) |               |
|  | * az connectedk8s |       +------------+-------------+               |
|  +-------------------+                    |                             |
|                                           v                             |
|  +-------------------------------------------------------------------+  |
|  | 03-prep-namespace-scc.sh                                          |  |
|  |   1. Create namespace foundry-local-operator                      |  |
|  |   2. Pre-create 6 ServiceAccounts with Helm ownership labels      |  |
|  |   3. Bind each SA to privileged SCC via RoleBinding               |  |
|  +--------------------------------+----------------------------------+  |
|                                   v                                     |
|  +-------------------------------------------------------------------+  |
|  | 04-prep-storage.sh                                                |  |
|  |   1. Create local-storage StorageClass                            |  |
|  |   2. Remove default annotation from managed-csi                   |  |
|  |   3. Set local-storage as cluster default                         |  |
|  |   4. SSH to node -> mkdir -p /var/foundry-models                  |  |
|  |   5. Create 100Gi PV with nodeAffinity                            |  |
|  +--------------------------------+----------------------------------+  |
|                                   v                                     |
|  +-------------------------------------------------------------------+  |
|  | 05-install-extension.sh                                           |  |
|  |   az k8s-extension create \                                       |  |
|  |     --name foundrylocal \                                         |  |
|  |     --extension-type microsoft.foundry \                          |  |
|  |     --config "global.telemetry.enabled=false" \                   |  |
|  |     --config "entraAuth.tenantId=<tenant>" \                      |  |
|  |     --config "entraAuth.clientId=<client-id>" \                   |  |
|  |     --no-wait                                                     |  |
|  |                                                                   |  |
|  |   Poll provisioningState every 15s (timeout: 10 min)              |  |
|  |   Atomic: Any pod failure -> full Helm rollback                   |  |
|  +--------------------------------+----------------------------------+  |
|                                   v                                     |
|  +-------------------------------------------------------------------+  |
|  | 06-deploy-model.sh                                                |  |
|  |   1. Sanitize: qwen2.5-coder-0.5b -> qwen2-5-coder-0-5b           |  |
|  |   2. Apply ModelDeployment CR (foundrylocal.azure.com/v1)         |  |
|  |   3. Wait for Available=True (timeout: 10 min)                    |  |
|  |   Model download: MCR -> model-store (OCI) -> inference pod       |  |
|  +--------------------------------+----------------------------------+  |
|                                   v                                     |
|  +-------------------------------------------------------------------+  |
|  | 07-validate-inference.sh                                          |  |
|  |   1. Extract API key from Secret (primary-key, base64)            |  |
|  |   2. kubectl port-forward svc/<model> 5000:5000                   |  |
|  |   3. curl -sk https://localhost:5000/v1/chat/completions          |  |
|  |      -H "api-key: $KEY" -d '{"model":"...","messages":[...]}'     |  |
|  |   4. Validate: HTTP 200 + choices[0].message.content non-empty    |  |
|  +-------------------------------------------------------------------+  |
+=========================================================================+
```

---

## 8. End-to-End Inference Flow

```text
+=========================================================================+
|                       INFERENCE REQUEST FLOW                            |
+=========================================================================+
|                                                                         |
|  Client (curl/app)                                                      |
|       |                                                                 |
|       | POST https://<svc>:5000/v1/chat/completions                     |
|       | Headers: api-key: <key> OR Authorization: Bearer <token>        |
|       | Body: {"model":"qwen2-5-coder-0-5b","messages":[...]}           |
|       v                                                                 |
|  +-------------------------------------------------------------------+  |
|  | Kubernetes Service: qwen2-5-coder-0-5b:5000                       |  |
|  | (ClusterIP, TLS termination at pod)                               |  |
|  +--------------------------------+----------------------------------+  |
|                                   v                                     |
|  +-------------------------------------------------------------------+  |
|  | Model Pod: qwen2-5-coder-0-5b-*                                   |  |
|  |                                                                   |  |
|  |  1. TLS handshake (self-signed cert from cert-manager)            |  |
|  |  2. Auth validation:                                              |  |
|  |     - api-key header -> compare vs Secret                         |  |
|  |     - Bearer token -> Entra ID JWT validation (tenant+audience)   |  |
|  |  3. Tokenize prompt (model-specific tokenizer)                    |  |
|  |  4. ONNX Runtime inference (CPU, AVX2/AVX512)                     |  |
|  |  5. Stream/collect tokens                                         |  |
|  |  6. Return OpenAI-compatible JSON response                        |  |
|  +-------------------------------------------------------------------+  |
|                                                                         |
|  Model weights source chain:                                            |
|  MCR (mcr.microsoft.com) -> model-store pod (OCI registry, PVC)         |
|                           -> model pod (volume mount from store)        |
+=========================================================================+
```

---

## 9. Performance Observations

| Metric | Value | Notes |
|--------|-------|-------|
| Extension install (cold) | ~3 min | Includes image pulls for 14 pods |
| Extension install (images cached) | ~45 sec | Helm install + pod scheduling |
| cert-manager + trust-manager install | ~2 min | Includes CRD installation |
| Model download (MCR → model-store) | ~2 min | 862 MB, depends on network |
| Model loading (model-store → inference) | ~1 min | ONNX model initialization |
| Total cold-start (extension + model) | ~8 min | First-time full install |
| Inference latency (simple prompt, 1 token) | 0.3–0.5s | "What is 2+2?" |
| Inference latency (code completion, ~100 tokens) | 3–8s | Multi-line code generation |
| Inference throughput (tokens/sec, CPU) | ~15–25 tok/s | Standard_D8s_v3, no GPU |
| API key validation overhead | <10 ms | Secret lookup cached |
| Port-forward latency added | <1 ms | localhost only |

### Resource Consumption (steady state, model loaded)

| Pod | CPU Request | CPU Limit | Memory Request | Memory Limit |
|-----|-------------|-----------|----------------|--------------|
| inference-operator (×3) | 100m | 500m | 128Mi | 512Mi |
| inference-operator-api (×5) | 100m | 500m | 128Mi | 512Mi |
| model-store (×2) | 100m | 1000m | 256Mi | 2Gi |
| telemetry-collector (×4) | 50m | 200m | 64Mi | 256Mi |
| qwen2-5-coder-0-5b (×1) | 4000m | 8000m | 4Gi | 16Gi |
| **Total** | **~5.5 cores** | **~14 cores** | **~6.5 Gi** | **~24 Gi** |

---

## 10. Authentication & Authorization

### API Key Authentication (Validated ✅)

**Mechanism:**
- Extension auto-generates a random API key during model deployment
- Key stored in Secret: `<deployment-name>-api-keys`, field: `primary-key` (base64)
- Client must pass `api-key: <value>` header
- Each ModelDeployment gets its own key

**Validation tests performed:**
| Test | Expected | Actual | Result |
|------|----------|--------|--------|
| Valid api-key header | 200 + response | 200 + response | ✅ |
| Invalid api-key value | 401 | 401 `invalid_token` | ✅ |
| Missing api-key header | 401 | 401 `missing_credentials` | ✅ |
| Empty api-key value | 401 | 401 `missing_credentials` | ✅ |

### Microsoft Entra ID Authentication (Validated ✅)

**Status:** Fully validated end-to-end on OCP 4.21 with Arc Extension. Both delegated user tokens (via Azure CLI) and the API key path work simultaneously.

**Setup required (one-time):**
1. Register Entra app (single-tenant) with `foundry_access` delegated scope
2. Set `accessTokenAcceptedVersion: 2` (v2.0 tokens required)
3. Pre-authorize Azure CLI (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) as known client
4. Install extension with `--config entraAuth.tenantId=<tenant> --config entraAuth.clientId=<client>`
5. Grant Arc cluster identity `Cognitive Services OpenAI User` on connected cluster scope
6. Grant calling user/group the same role on the connected cluster scope

**Extension install command (with Entra):**
```bash
az k8s-extension create \
  --name foundrylocal \
  --extension-type microsoft.foundry \
  --cluster-name <arc-cluster> \
  --resource-group <rg> \
  --cluster-type connectedClusters \
  --scope cluster \
  --release-namespace foundry-local-operator \
  --release-train stable \
  --auto-upgrade-minor-version true \
  --configuration-settings "global.telemetry.enabled=false" \
  --configuration-settings "entraAuth.tenantId=<tenant-id>" \
  --configuration-settings "entraAuth.clientId=<app-client-id>"
```

**Token acquisition:**
```bash
# Acquire delegated user token via Azure CLI
TOKEN=$(az account get-access-token \
  --resource "api://<app-client-id>" \
  --query accessToken -o tsv)

# Use in inference request
curl -sk "https://localhost:5000/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2-5-coder-0-5b","messages":[{"role":"user","content":"Hello"}]}'
```

**Validation tests performed:**
| Test | Expected | Actual | Result |
|------|----------|--------|--------|
| Valid Entra Bearer token | 200 + response | 200 + response (content: "4") | ✅ |
| Invalid Bearer token | 401 | 401 `{"code":"invalid_token","message":"Token validation failed"}` | ✅ |
| No auth header at all | 401 | 401 `{"code":"missing_credentials","message":"No Bearer token or API key provided"}` | ✅ |
| API key still works alongside Entra | 200 | 200 + response (content: "4") | ✅ |

**Key finding:** Both auth mechanisms work **simultaneously**. The inference pod accepts either `api-key:` or `Authorization: Bearer` headers — no need to choose one or the other. This means teams can use API keys for simple testing and Entra ID for production RBAC without reinstalling.

**OCP-specific observations:**
- The `msi-adapter` sidecar (used for Entra token validation) runs in every inference-operator-api pod and model deployment pod
- No additional SCC requirements beyond what's already needed (D1) — `privileged` SCC covers the msi-adapter
- Token validation adds ~46s latency on first request (cold JWT validation cache), subsequent requests are sub-second
- The Arc cluster's managed identity must have `Cognitive Services OpenAI User` role; without it, all Bearer requests fail with `500 rbac_check_unavailable`

---

## 11. Recommendations to Foundry Team

| # | Priority | Recommendation | Impact |
|---|----------|---------------|--------|
| 1 | 🔴 High | **Honor `modelStore.storageClassName` config** — template the value into the PVC spec | Unblocks non-default SC environments |
| 2 | 🔴 High | **Drop root from msi-adapter** — use non-root UID + drop NET_ADMIN/NET_RAW capabilities | Allows `anyuid` SCC instead of `privileged` |
| 3 | 🔴 High | **Document OpenShift deployment path** — zero official docs exist for OCP | Enables enterprise OCP customers |
| 4 | 🔴 High | **Fix or document Microsoft.CertManagement on CRI-O** — or recommend Jetstack charts for OCP | Unblocks cert-manager prerequisite |
| 5 | 🟡 Medium | **Document DNS-1035 naming constraint** for ModelDeployment metadata.name | Prevents user confusion with dots in model names |
| 6 | 🟡 Medium | **Document `foundrylocal.azure.com/v1` CRD schema** with examples | Current docs/blogs reference deprecated API |
| 7 | 🟡 Medium | **Fix telemetry flag** to suppress pod creation entirely when disabled | Eliminates 4 unnecessary pods + their SCC needs |
| 8 | 🟡 Medium | **Graceful SCC handling** — detect OCP via API discovery and skip runAsUser if SCC present | Eliminates D1 entirely on OCP |
| 9 | ⚪ Low | **OLM Operator packaging** for OperatorHub distribution | Native OCP install experience |
| 10 | ⚪ Low | **Integration with OCP service-ca** operator | Eliminates external cert-manager dependency |

---

## 12. Conclusion

**Foundry Local runs successfully on self-hosted OpenShift 4.21 via Azure Arc Extension** with 8 workarounds addressing 11 documented divergences from the AKS path.

**The fundamental architectural gap** is that Foundry Local assumes Kubernetes Pod Security Standards (PSS) — where security is enforced via namespace labels — while OpenShift uses SecurityContextConstraints (SCC), an admission controller that evaluates per-ServiceAccount. These are incompatible systems: PSS is "deny by default, relax via label"; SCC is "restricted by default, grant via rolebinding." The Foundry Helm chart's hardcoded `runAsUser: 1000` and `runAsUser: 0` violate both models.

**The atomic install compounds the problem.** The Arc extension's Helm release is all-or-nothing — if a single pod can't start (SCC rejection, PVC binding failure, image pull error), the entire release rolls back. This eliminates the iterative "deploy, observe, fix" workflow and requires all workarounds to be applied BEFORE the first install attempt.

**Despite these challenges, the system is fully functional.** Inference performance is acceptable for CPU-only workloads (15–25 tokens/sec), the OpenAI-compatible API works correctly, TLS and API-key auth work without modification, and the model catalog/download pipeline functions identically to AKS.

**Path to production readiness:**
1. Fix D1 (drop root from msi-adapter) — reduces security blast radius from `privileged` to `anyuid`
2. Fix D2 (honor storageClassName config) — eliminates SC swap hack
3. Document OCP path officially — enables enterprise adoption

---
---

# Appendix

## A. CRD Schema Reference

### ModelDeployment (foundrylocal.azure.com/v1)

```yaml
apiVersion: foundrylocal.azure.com/v1
kind: ModelDeployment
metadata:
  name: qwen2-5-coder-0-5b          # DNS-1035 compliant (no dots)
  namespace: foundry-local-operator
spec:
  model:
    catalog:
      name: qwen2.5-coder-0.5b      # Original model name (dots OK here)
  compute: cpu                        # "cpu" or "gpu"
status:
  conditions:
    - type: Available                 # NOT "Ready" (different from older API)
      status: "True"
      message: "Model is available for inference"
```

### StoreModels (read-only, hardware-filtered catalog)

```bash
# Lists models available for THIS cluster's hardware
kubectl get storemodels -n foundry-local-operator
# On CPU-only cluster: shows only CPU-compatible models
# Full catalog (all 173+ models): kubectl get cm foundry-local-catalog -n foundry-local-operator -o yaml
```

## B. Troubleshooting Guide

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Extension install rolls back immediately | SCC rejection → pods can't start | Re-run `03-prep-namespace-scc.sh`, verify all 6 SAs have `privileged` |
| PVC stuck in Pending | No default SC, or default SC provisioner broken | Run `04-prep-storage.sh`, verify `kubectl get sc` shows `local-storage (default)` |
| PV in Released state | Previous failed install left stale claimRef | `kubectl patch pv foundry-model-store-pv --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'` |
| Model pod CrashLoopBackOff | Insufficient memory for model | Check `kubectl describe pod` — model needs ~4Gi RAM for 0.5B param model |
| `api-key` returns 401 | Wrong header format | Use `api-key: <value>` (NOT `Authorization: Bearer <value>`) |
| Cert errors on HTTPS | trust-manager secretTargets not enabled | Reinstall trust-manager with `--set secretTargets.enabled=true --set secretTargets.authorizedSecretsAll=true` |
| Extension type not found | Wrong casing | Must be exactly `microsoft.foundry` (lowercase) |
| ModelDeployment rejected | Name contains dots | Sanitize: `tr '.' '-'` |

## C. Comparison: Arc Extension vs Helm Standalone

| Aspect | Arc Extension | Helm Standalone |
|--------|--------------|-----------------|
| Install command | `az k8s-extension create` | `helm upgrade --install` |
| Helm control | None (Arc agent manages) | Full (`--set`, `--values`) |
| Atomic rollback | Yes (all-or-nothing) | Configurable (`--atomic` flag) |
| CRD API group | `foundrylocal.azure.com` | `inference.foundry.azure.com` |
| CRD version | `v1` | `v1alpha1` |
| Model readiness condition | `Available` | `Ready` |
| Auth header | `api-key: <key>` | `Authorization: Bearer <key>` |
| Service port | 5000 | 5000 |
| SA naming | `<extension-name>-*` | `<release-name>-*` |
| Pre-create SAs required? | Yes (with Helm labels) | No (Helm creates them) |
| Telemetry pods | Always created (4 replicas) | Optional |
| Upgrade path | `az k8s-extension update` | `helm upgrade` |
| Azure portal visibility | Yes (Extension resource) | No |
| Requires Arc connection | Yes | No |

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
| Jetstack cert-manager | https://cert-manager.io/docs/installation/helm/ |
| Jetstack trust-manager | https://cert-manager.io/docs/trust/trust-manager/installation/ |

## E. Test Results (E2E Suite)

The `08-e2e-tests.sh` script runs 10 validation tests, plus 3 additional Entra ID auth tests:

| # | Test | Status |
|---|------|--------|
| 1 | Extension provisioningState = Succeeded | ✅ Pass |
| 2 | All operator pods Running (3/3) | ✅ Pass |
| 3 | All API pods Running (5/5) | ✅ Pass |
| 4 | Model-store pods Running (2/2) | ✅ Pass |
| 5 | PVC Bound to PV | ✅ Pass |
| 6 | ModelDeployment Available=True | ✅ Pass |
| 7 | API key extractable from Secret | ✅ Pass |
| 8 | Inference (api-key) returns HTTP 200 | ✅ Pass |
| 9 | Response contains valid content | ✅ Pass |
| 10 | Invalid API key returns 401 | ✅ Pass |
| 11 | Entra token acquired via `az account get-access-token` | ✅ Pass |
| 12 | Inference (Entra Bearer) returns HTTP 200 | ✅ Pass |
| 13 | Invalid Bearer token returns 401 | ✅ Pass |

**Result: 13/13 tests passed.**
