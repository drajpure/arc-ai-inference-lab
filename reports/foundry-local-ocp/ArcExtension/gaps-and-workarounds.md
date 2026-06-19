# Foundry Local on OpenShift — Gaps & Workarounds Report

**Date:** July 2025  
**Platform:** OpenShift 4.21.2 / Kubernetes v1.34.2 / CRI-O 1.34.5  
**Install Method:** Azure Arc Extension (`microsoft.foundry`)  
**Status:** ✅ Fully operational with workarounds

---

## Executive Summary

Microsoft Foundry Local's official documentation targets AKS (Azure Kubernetes Service). When deploying on self-hosted OpenShift via the Arc Extension mechanism, **9 gaps** require workarounds. After applying all workarounds, the extension installs successfully, models deploy from the catalog, and inference works end-to-end.

The install is **atomic** (Helm-based) — all workarounds must be applied *before* running `az k8s-extension create`. There is no opportunity to fix issues post-install; a failed install rolls back completely.

---

## Gap Analysis

### G1: SecurityContextConstraints (SCC) — BLOCKING

| Aspect | AKS Behavior | OCP Behavior |
|--------|-------------|--------------|
| Pod security | PSA (warn/audit only in most namespaces) | SCC enforced — `restricted-v2` by default |
| UID handling | Any UID allowed | Must be within namespace range (e.g., 1000760000–1000769999) |
| Capabilities | Allowed by default | NET_ADMIN, NET_RAW denied unless explicitly granted |

**Impact:** All Foundry pods fail to start. The extension's Helm install times out and rolls back.

**Root cause:** Multiple containers specify hardcoded UIDs outside OCP's namespace range:
- `inference-operator`: runAsUser=1000, fsGroup=1000
- `model-store`: runAsUser=1000, fsGroup=1000
- `msi-adapter` init container (in operator-api, telemetry): runAsUser=0, NET_ADMIN, NET_RAW

**Workaround:** Pre-grant `privileged` SCC to all 6 ServiceAccounts before extension install.

**Why `privileged` and not `anyuid`?** The `msi-adapter` init container runs as root (UID 0) and requests `NET_ADMIN` + `NET_RAW` capabilities for iptables rules. `anyuid` only relaxes the UID constraint, not capabilities.

**Affected SAs (predictable from `--name` parameter):**
```
<extension-name>-inference-operator
<extension-name>-inference-operator-api
<extension-name>-inference-operator-catalog-sync
foundry-config-reader
inference-operator-crd-update
default
```

---

### G2: StorageClass Configuration Ignored — BLOCKING

| Aspect | Expected | Actual |
|--------|----------|--------|
| `modelStore.storageClassName` config | Respected — sets SC for model-store PVC | **Completely ignored** |
| PVC binding | Uses specified SC | Always uses cluster default SC |

**Impact:** On clusters where the default SC (e.g., `managed-csi`) doesn't work, the model-store PVC stays Pending → Helm timeout → rollback.

**Root cause:** The extension's Helm chart does not template the storageClassName from configuration settings. The PVC spec omits `storageClassName`, causing Kubernetes to use the cluster default.

**Workaround:** Temporarily swap the cluster default StorageClass to one that works (e.g., `local-storage`) before installing the extension.

---

### G3: Azure Disk CSI on UPI/Manual Credential Clusters — BLOCKING (environment-specific)

| Aspect | IPI Cluster | UPI (credentialsMode: Manual) |
|--------|------------|-------------------------------|
| Azure Disk CSI | Works (credentials auto-injected) | Fails: `CredentialTypeNotAllowedAsPerAppPolicy` |

**Impact:** If the cluster uses `credentialsMode: Manual` without pre-seeded cloud credentials, the `managed-csi` StorageClass cannot provision volumes.

**Root cause:** The Azure Disk CSI driver requires AAD credentials to call Azure Storage APIs. In Manual mode, these aren't automatically provisioned.

**Workaround:** Use local-storage (hostPath PV with node affinity) instead of Azure Disk.

---

### G4: OTEL Telemetry Collector Bug — PARTIALLY BLOCKING

| Aspect | Detail |
|--------|--------|
| Symptom | Image pull failures or crash loops in telemetry pods |
| Config flag | `global.telemetry.enabled=false` |
| Effect of flag | Prevents data collection; does NOT prevent pod creation |

**Impact:** Without the flag, telemetry components may fail and block install (atomic Helm release).

**Workaround:** Set `global.telemetry.enabled=false` as a configuration setting during extension creation. Telemetry pods still run (4 replicas) but don't attempt data export.

**Note:** This was confirmed as a known bug by the Foundry team. The workaround is officially recommended.

---

### G5: No Dynamic Provisioner for Local Storage — BLOCKING (when G3 applies)

| Aspect | AKS | OCP UPI |
|--------|-----|---------|
| Default SC | `managed-csi` with dynamic provisioner | `managed-csi` (may be broken per G3) |
| Local-storage | Not needed | No provisioner — requires manual PV |

**Impact:** Even after creating a `local-storage` StorageClass, PVCs remain Pending because there's no provisioner to create PVs dynamically.

**Workaround:** Manually create:
1. StorageClass (`local-storage`, `kubernetes.io/no-provisioner`)
2. PersistentVolume (100Gi, hostPath, node affinity to specific node)
3. Host directory on the target node

---

### G6: PV Lifecycle After Failed Installs — OPERATIONAL

| State | Cause | Fix |
|-------|-------|-----|
| `Released` | PVC deleted during rollback; PV retains stale `claimRef` | Patch PV to remove `/spec/claimRef` |
| `Bound` (to deleted PVC) | Race condition during rapid retry | Same patch |

**Impact:** Subsequent install attempts can't bind the PV even though it has capacity.

**Workaround:** Before each install attempt, verify PV is in `Available` state. If `Released`, clear the claimRef:
```bash
kubectl patch pv <name> --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
```

---

### G7: Extension Type Discovery — DOCUMENTATION GAP

| Expected | Actual |
|----------|--------|
| `Microsoft.FoundryLocal` or `Microsoft.Foundry` (capital) | `microsoft.foundry` (lowercase) |

**Impact:** Using wrong type name causes immediate failure with "extension type not found."

**Discovery method:**
```bash
az k8s-extension extension-types list-by-cluster \
  --cluster-name <arc-cluster> --resource-group <rg> \
  --cluster-type connectedClusters --query "[?contains(extensionType,'foundry')]"
```

**Workaround:** Use `microsoft.foundry` exactly.

---

### G8: Model CRD Schema Version — DOCUMENTATION GAP

| Old Schema (Helm v0.260430.8) | Current Schema (Arc Extension) |
|-------------------------------|-------------------------------|
| `spec.modelId: "model-name"` | `spec.model.catalog.name: "model-name"` |
| | `spec.compute: cpu` |

**Impact:** Using the old schema creates a CR that the operator ignores (no status update, no model download).

**Workaround:** Use the current schema:
```yaml
apiVersion: inference.foundry.azure.com/v1alpha1
kind: ModelDeployment
metadata:
  name: qwen2.5-coder-0.5b
spec:
  model:
    catalog:
      name: qwen2.5-coder-0.5b
  compute: cpu
```

---

### G9: Namespace UID Range Conflict — INFORMATIONAL

| OCP Namespace UID Range | Foundry Hardcoded UIDs |
|------------------------|----------------------|
| 1000760000–1000769999 | 0 (root), 1000, 101, 10001 |

**Impact:** All Foundry container UIDs fall outside the namespace's allocated range. OCP's SCC rejects them unless `privileged` or `anyuid` SCC is granted.

**Note:** This is the underlying cause of G1 but called out separately because it explains *why* `anyuid` alone isn't sufficient (UID 0 for msi-adapter requires `privileged`).

---

## Summary Matrix

| Gap | Severity | Category | Automated in Scripts? |
|-----|----------|----------|----------------------|
| G1: SCC enforcement | 🔴 Blocking | Security | ✅ `01-prep-namespace-scc.sh` |
| G2: StorageClassName ignored | 🔴 Blocking | Storage | ✅ `02-prep-storage.sh` |
| G3: Azure Disk CSI broken | 🔴 Blocking (env-specific) | Storage | ✅ `02-prep-storage.sh` |
| G4: OTEL collector bug | 🟡 Partially blocking | Telemetry | ✅ `03-install-extension.sh` |
| G5: No local-storage provisioner | 🔴 Blocking (when G3) | Storage | ✅ `02-prep-storage.sh` |
| G6: PV Released state | 🟡 Operational | Storage | ✅ `02-prep-storage.sh` |
| G7: Extension type name | 🟡 Documentation gap | Install | ✅ `env.sh.example` |
| G8: CRD schema change | 🟡 Documentation gap | Model | ✅ `04-deploy-model.sh` |
| G9: Namespace UID range | ℹ️ Informational | Security | ✅ (covered by G1 fix) |

---

## Recommendations to Foundry Local Team

1. **Template `storageClassName`** — Honor the `modelStore.storageClassName` configuration setting in the Helm chart's PVC spec. This is the single most impactful fix for non-AKS platforms.

2. **Reduce SCC requirements** — Consider:
   - Running `msi-adapter` as non-root with reduced capabilities
   - Using OCP-compatible UID ranges (or `runAsUser: null` to inherit namespace range)
   - Documenting exact SCC requirements for OpenShift

3. **Fix telemetry flag** — `global.telemetry.enabled=false` should prevent telemetry pod creation entirely, not just disable data collection.

4. **Document extension type** — Add `microsoft.foundry` to official docs (currently only referenced in Arc extension marketplace).

5. **Document CRD schema** — Provide versioned API examples in official docs. The schema change from `spec.modelId` to `spec.model.catalog.name` is undocumented.

6. **Add OCP to supported platforms** — Even a "community-supported" tier with documented workarounds would help adoption.

---

## Test Evidence

| Test | Result |
|------|--------|
| Extension install (`az k8s-extension create`) | ✅ provisioningState: Succeeded |
| All pods Running (operator 3/3, api 5/5, store 2/2, telemetry 4/4) | ✅ |
| Model catalog accessible (178 models) | ✅ |
| Model deployment (`qwen2.5-coder-0.5b`) Ready=True | ✅ |
| Inference: "What is 2+2?" → "4" | ✅ |
| Uninstall + reinstall cycle | ✅ |

---

## References

- [Foundry Local Docs (AKS)](https://learn.microsoft.com/azure/ai-foundry/foundry-local/overview)
- [Arc Extensions](https://learn.microsoft.com/azure/azure-arc/kubernetes/extensions)
- [OCP SecurityContextConstraints](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
- [Install Scripts](./scripts/)
