#!/bin/bash
# 03-install-cert-manager.sh
# Install cert-manager and trust-manager via upstream Jetstack Helm charts.
# Matches exactly the commands from the official Foundry Local Helm Installation Guide.
#
# The Microsoft.CertManagement Arc extension does NOT work on OpenShift/CRI-O,
# so the upstream Jetstack charts are used instead.
#
# IMPORTANT (per official guide):
#   - For trust-manager, secretTargets.enabled=true and secretTargets.authorizedSecretsAll=true
#     are MANDATORY — Foundry Local will not function without them.
#   - Do NOT install trust-manager until cert-manager pods are up and running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.2}"
TRUST_MANAGER_VERSION="${TRUST_MANAGER_VERSION:-v0.20.3}"

echo "=== Adding Jetstack Helm repo ==="
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

# ----------------------------------------------------------------------------
# cert-manager — official Foundry guide pins every component image tag to the
# chart version. crds.keep=true preserves CRDs across upgrades/uninstalls.
# ----------------------------------------------------------------------------
echo ""
echo "=== Installing cert-manager ${CERT_MANAGER_VERSION} ==="
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

# Explicit readiness gate before trust-manager (the guide warns against installing it early)
echo ""
echo "=== Waiting for cert-manager pods to be Ready ==="
kubectl wait --for=condition=Available --timeout=300s -n cert-manager \
  deployment/cert-manager \
  deployment/cert-manager-cainjector \
  deployment/cert-manager-webhook

# ----------------------------------------------------------------------------
# trust-manager — secretTargets flags are MANDATORY for Foundry Local.
# defaultPackage.enabled=false disables the CA bundle download (not needed).
# ----------------------------------------------------------------------------
echo ""
echo "=== Installing trust-manager ${TRUST_MANAGER_VERSION} ==="
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
echo "=== Verifying ==="
kubectl get pods -n cert-manager
echo ""
echo "✓ cert-manager and trust-manager installed successfully."
