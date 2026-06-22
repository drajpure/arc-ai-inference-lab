#!/bin/bash
# 02-install-cert-manager.sh
# Install cert-manager and trust-manager via upstream Jetstack Helm charts.
#
# Per the official Foundry Local docs (Step 1):
#   https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension
#
# The Microsoft.CertManagement Arc extension does NOT work on OpenShift/CRI-O
# (deprecated seccomp annotations, hostPath volumes, nested OCI manifest).
# We use the upstream Jetstack charts instead.
#
# IMPORTANT:
#   - trust-manager secretTargets.enabled=true and secretTargets.authorizedSecretsAll=true
#     are MANDATORY — Foundry Local will not function without them.
#   - Do NOT install trust-manager until cert-manager pods are up and running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.2}"
TRUST_MANAGER_VERSION="${TRUST_MANAGER_VERSION:-v0.20.3}"

echo "=== Installing cert-manager + trust-manager ==="
echo ""
echo "  cert-manager: ${CERT_MANAGER_VERSION}"
echo "  trust-manager: ${TRUST_MANAGER_VERSION}"
echo ""

# Check if already installed
if helm list -n cert-manager 2>/dev/null | grep -q cert-manager; then
  echo "✓ cert-manager already installed:"
  helm list -n cert-manager
  echo ""
  if helm list -n cert-manager 2>/dev/null | grep -q trust-manager; then
    echo "✓ trust-manager already installed."
    echo ""
    echo "  Next: ./scripts/03-prep-namespace-scc.sh"
    exit 0
  fi
fi

# Add Jetstack repo
echo "--- Adding Jetstack Helm repo ---"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

# Install cert-manager
echo ""
echo "--- Installing cert-manager ${CERT_MANAGER_VERSION} ---"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set crds.keep=true \
  --set image.tag="${CERT_MANAGER_VERSION}" \
  --set webhook.image.tag="${CERT_MANAGER_VERSION}" \
  --set cainjector.image.tag="${CERT_MANAGER_VERSION}" \
  --set acmesolver.image.tag="${CERT_MANAGER_VERSION}" \
  --set startupapicheck.image.tag="${CERT_MANAGER_VERSION}" \
  --wait \
  --timeout 5m

# Wait for readiness before trust-manager
echo ""
echo "--- Waiting for cert-manager pods ---"
kubectl wait --for=condition=Available --timeout=300s -n cert-manager \
  deployment/cert-manager \
  deployment/cert-manager-cainjector \
  deployment/cert-manager-webhook

# Install trust-manager
echo ""
echo "--- Installing trust-manager ${TRUST_MANAGER_VERSION} ---"
helm upgrade --install trust-manager jetstack/trust-manager \
  --namespace cert-manager \
  --version "${TRUST_MANAGER_VERSION}" \
  --set image.tag="${TRUST_MANAGER_VERSION}" \
  --set defaultPackage.enabled=false \
  --set secretTargets.enabled=true \
  --set secretTargets.authorizedSecretsAll=true \
  --wait \
  --timeout 5m

echo ""
echo "--- Verifying ---"
kubectl get pods -n cert-manager
echo ""
echo "✓ cert-manager and trust-manager installed successfully."
echo ""
echo "  Next: ./scripts/03-prep-namespace-scc.sh"
