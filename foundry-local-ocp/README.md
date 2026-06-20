# Foundry Local on Self-Hosted OpenShift (OCP)

Deploy **Microsoft Foundry Local** on a self-hosted OpenShift cluster connected to Azure Arc. Two installation methods are provided — choose the one that fits your scenario.

## Installation Methods

| | [Arc Extension](arc-extension/) | [Helm Standalone](helm-standalone/) |
|---|---|---|
| **Install method** | `az k8s-extension create` | `helm install` |
| **Lifecycle** | Managed by Arc Extension Manager | Self-managed |
| **Updates** | Auto-update via Arc | Manual Helm upgrade |
| **Azure portal** | Extension visible in Arc resource | Not visible |
| **Best for** | Production / managed deployments | Dev / air-gapped / custom |
| **Scripts** | 10 scripts (00–09) | 10 scripts (00–09) |

### Arc Extension (Recommended)

The Arc Extension approach uses `az k8s-extension create --extension-type microsoft.foundry` to install Foundry Local. The Arc Extension Manager handles Helm chart installation, upgrades, and health monitoring automatically.

```bash
cd arc-extension
cp env.sh.example env.sh && vim env.sh
./scripts/00-prerequisites.sh
# Follow the "Next:" prompts
```

👉 **[Full guide →](arc-extension/README.md)**

### Helm Standalone

Direct Helm chart installation with full control over operator version, cert-manager, and trust-manager. Useful for development, air-gapped environments, or when you need custom Helm values.

```bash
cd helm-standalone
cp env.sh.example env.sh && vim env.sh
./scripts/00-provision-ocp.sh   # or skip if cluster exists
# Follow the numbered scripts
```

👉 **[Full guide →](helm-standalone/README.md)**

## Common Prerequisites

- OpenShift cluster ≥ 4.19 (Kubernetes ≥ 1.29)
- Cluster connected to Azure Arc (`az connectedk8s connect`)
- `az`, `kubectl`, `oc`, `jq`, `curl` installed
- Foundry Local preview access ([request here](https://aka.ms/FoundryLocalAzure_PreviewRequest))

## Tested Environment

| Component | Version |
|-----------|---------|
| OpenShift | 4.21.2 |
| Kubernetes | v1.34.2 |
| CRI-O | 1.34.5 |
| Nodes | 3 masters (CPU-only, no GPU) |
| Model | qwen2.5-coder-0.5b (CPU/ONNX) |
