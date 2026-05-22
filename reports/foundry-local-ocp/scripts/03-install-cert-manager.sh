#!/bin/bash
# 01-install-cert-manager.sh
# Install cert-manager and trust-manager via upstream Jetstack Helm charts.
# The Microsoft.CertManagement Arc extension does NOT work on OpenShift/CRI-O.
set -euo pipefail

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.2}"
TRUST_MANAGER_VERSION="${TRUST_MANAGER_VERSION:-v0.20.3}"

echo "=== Adding Jetstack Helm repo ==="
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

echo "=== Installing cert-manager ${CERT_MANAGER_VERSION} ==="
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --wait --timeout 5m

echo "=== Installing trust-manager ${TRUST_MANAGER_VERSION} ==="
helm install trust-manager jetstack/trust-manager \
  --namespace cert-manager \
  --version "${TRUST_MANAGER_VERSION}" \
  --wait --timeout 5m

echo "=== Verifying ==="
kubectl get pods -n cert-manager
echo ""
echo "cert-manager and trust-manager installed successfully."
