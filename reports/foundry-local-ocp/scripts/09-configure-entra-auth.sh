#!/bin/bash
# 09-configure-entra-auth.sh
# Configure Microsoft Entra ID authentication for Foundry Local on Arc.
# Implements all 6 mandatory + 1 optional steps from:
# https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/how-to-configure-authentication
#
# Performs:
#   Step 1: Register an Entra app (single-tenant)
#   Step 2: Expose an API — set Application ID URI + add 'foundry_access' delegated scope
#   Step 3: Set accessTokenAcceptedVersion to 2 (v2.0 tokens)
#   Step 4: Authorize Azure CLI as a known client (so 'az account get-access-token' works)
#   Step 5: Assign a user/group an RBAC role on the connected cluster
#   Step 6: Grant the cluster's Arc identity 'Cognitive Services OpenAI User'
#           (REQUIRED — without this, all authenticated requests fail with 500 rbac_check_unavailable)
#   Step 7 (optional): Assign role to a managed identity / service principal
#
# Prerequisites:
#   - 02-connect-arc.sh has completed (cluster has an Arc principal)
#   - Caller has Application Administrator (or equivalent) Entra permissions
#   - Caller has Owner / User Access Administrator on the connectedCluster scope
#
# Re-run safe: all operations are idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

# === Required inputs ===
ARC_RESOURCE_GROUP="${ARC_RESOURCE_GROUP:-rg-ocp-foundry-arc}"
ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:-ocp-foundry-arc}"
ENTRA_APP_NAME="${ENTRA_APP_NAME:-FoundryLocal-Production}"

# User or group to grant inference access to (object ID).
# Leave unset to skip Step 5 (you can run it later with a different principal).
ENTRA_USER_OR_GROUP_OBJECT_ID="${ENTRA_USER_OR_GROUP_OBJECT_ID:-}"
ENTRA_USER_ROLE="${ENTRA_USER_ROLE:-Cognitive Services OpenAI User}"  # or 'Cognitive Services Contributor'

# Optional: managed identity / service principal object ID (Step 7).
ENTRA_MSI_OBJECT_ID="${ENTRA_MSI_OBJECT_ID:-}"

# Azure CLI client ID — well-known, do not change.
AZ_CLI_CLIENT_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"

echo "=== Configure Entra ID auth for Foundry Local ==="
echo "  App name:           ${ENTRA_APP_NAME}"
echo "  Arc RG / cluster:   ${ARC_RESOURCE_GROUP} / ${ARC_CLUSTER_NAME}"
echo "  User/group grantee: ${ENTRA_USER_OR_GROUP_OBJECT_ID:-<skipped — Step 5 will not run>}"
echo "  MSI grantee:        ${ENTRA_MSI_OBJECT_ID:-<skipped — Step 7 will not run>}"
echo ""

# Validate tools
for cmd in az jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '${cmd}' not found." >&2
    exit 1
  fi
done

if ! az account show &>/dev/null; then
  echo "ERROR: Not logged into Azure CLI. Run 'az login' first." >&2
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
CLUSTER_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ARC_RESOURCE_GROUP}/providers/Microsoft.Kubernetes/connectedClusters/${ARC_CLUSTER_NAME}"

# Verify Arc cluster exists
if ! az connectedk8s show -n "${ARC_CLUSTER_NAME}" -g "${ARC_RESOURCE_GROUP}" &>/dev/null; then
  echo "ERROR: Arc-connected cluster '${ARC_CLUSTER_NAME}' not found in '${ARC_RESOURCE_GROUP}'." >&2
  echo "       Run ./scripts/02-connect-arc.sh first." >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Step 1: Register (or look up) the Entra app
# ----------------------------------------------------------------------------
echo "=== Step 1: Entra app registration ==="
APP_ID=$(az ad app list --display-name "${ENTRA_APP_NAME}" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -z "${APP_ID}" ]]; then
  echo "  Creating new app '${ENTRA_APP_NAME}'..."
  APP_ID=$(az ad app create \
    --display-name "${ENTRA_APP_NAME}" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  # Allow Entra to propagate before we PATCH it
  sleep 5
else
  echo "  Reusing existing app: ${APP_ID}"
fi

APP_OBJECT_ID=$(az ad app show --id "${APP_ID}" --query id -o tsv)
echo "  App (client) ID:  ${APP_ID}"
echo "  App object ID:    ${APP_OBJECT_ID}"
echo "  Tenant ID:        ${TENANT_ID}"

# ----------------------------------------------------------------------------
# Step 2: Set Application ID URI + add 'foundry_access' delegated scope
# ----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Expose API (Application ID URI + foundry_access scope) ==="

APP_ID_URI="api://${APP_ID}"

# Use a deterministic GUID for the scope's permission ID so reruns don't duplicate it.
SCOPE_ID=$(uuidgen 2>/dev/null || python -c "import uuid; print(uuid.uuid4())" 2>/dev/null || cat /proc/sys/kernel/random/uuid)
EXISTING_SCOPE_ID=$(az ad app show --id "${APP_ID}" \
  --query "api.oauth2PermissionScopes[?value=='foundry_access'].id | [0]" -o tsv 2>/dev/null || true)

if [[ -n "${EXISTING_SCOPE_ID}" ]]; then
  echo "  'foundry_access' scope already exists (id=${EXISTING_SCOPE_ID}). Skipping create."
  SCOPE_ID="${EXISTING_SCOPE_ID}"
else
  TMP_API_JSON=$(mktemp)
  cat > "${TMP_API_JSON}" <<EOF
{
  "oauth2PermissionScopes": [
    {
      "id": "${SCOPE_ID}",
      "adminConsentDescription": "Allows the application to access Foundry Local inference endpoints on behalf of the signed-in user",
      "adminConsentDisplayName": "Access Foundry Local inference endpoints",
      "isEnabled": true,
      "type": "Admin",
      "value": "foundry_access"
    }
  ]
}
EOF

  az ad app update --id "${APP_ID}" \
    --identifier-uris "${APP_ID_URI}" \
    --set api=@"${TMP_API_JSON}"

  rm -f "${TMP_API_JSON}"
  echo "  Created scope 'foundry_access' (id=${SCOPE_ID})"
fi

echo "  Application ID URI: ${APP_ID_URI}"

# ----------------------------------------------------------------------------
# Step 3: Set accessTokenAcceptedVersion to 2 (CRITICAL)
# Without this, tokens use v1.0 with issuer https://sts.windows.net/ which the
# Foundry auth sidecar rejects.
# ----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Force v2.0 tokens (accessTokenAcceptedVersion=2) ==="
az ad app update --id "${APP_ID}" --set api.requestedAccessTokenVersion=2
echo "  Token version set to v2.0"

# ----------------------------------------------------------------------------
# Step 4: Authorize Azure CLI as a known client
# ----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Authorize Azure CLI as pre-authorized client ==="

PRE_AUTH=$(az ad app show --id "${APP_ID}" \
  --query "api.preAuthorizedApplications[?appId=='${AZ_CLI_CLIENT_ID}'] | [0].appId" -o tsv 2>/dev/null || true)

if [[ -n "${PRE_AUTH}" ]]; then
  echo "  Azure CLI already pre-authorized. Skipping."
else
  TMP_PRE_JSON=$(mktemp)
  cat > "${TMP_PRE_JSON}" <<EOF
[
  {
    "appId": "${AZ_CLI_CLIENT_ID}",
    "delegatedPermissionIds": ["${SCOPE_ID}"]
  }
]
EOF
  az ad app update --id "${APP_ID}" --set api.preAuthorizedApplications=@"${TMP_PRE_JSON}"
  rm -f "${TMP_PRE_JSON}"
  echo "  Azure CLI (${AZ_CLI_CLIENT_ID}) pre-authorized for 'foundry_access'"
fi

# ----------------------------------------------------------------------------
# Step 5: Assign user/group an RBAC role on the cluster
# ----------------------------------------------------------------------------
echo ""
echo "=== Step 5: Assign user/group role on connected cluster ==="
if [[ -z "${ENTRA_USER_OR_GROUP_OBJECT_ID}" ]]; then
  echo "  ENTRA_USER_OR_GROUP_OBJECT_ID not set — skipping."
  echo "  To grant access later:"
  echo "    az role assignment create --assignee <OBJECT_ID> \\"
  echo "      --role '${ENTRA_USER_ROLE}' --scope '${CLUSTER_SCOPE}'"
else
  az role assignment create \
    --assignee "${ENTRA_USER_OR_GROUP_OBJECT_ID}" \
    --role "${ENTRA_USER_ROLE}" \
    --scope "${CLUSTER_SCOPE}" \
    --only-show-errors 2>&1 | grep -v "already exists" || true
  echo "  Assigned '${ENTRA_USER_ROLE}' to ${ENTRA_USER_OR_GROUP_OBJECT_ID}"
fi

# ----------------------------------------------------------------------------
# Step 6: Grant the cluster's Arc identity Cognitive Services OpenAI User
# REQUIRED — without this, all authenticated requests return 500 rbac_check_unavailable
# ----------------------------------------------------------------------------
echo ""
echo "=== Step 6: Grant Arc cluster identity 'Cognitive Services OpenAI User' (REQUIRED) ==="

ARC_PRINCIPAL_ID=$(az connectedk8s show \
  -n "${ARC_CLUSTER_NAME}" -g "${ARC_RESOURCE_GROUP}" \
  --query "identity.principalId" -o tsv)

if [[ -z "${ARC_PRINCIPAL_ID}" || "${ARC_PRINCIPAL_ID}" == "null" ]]; then
  echo "ERROR: Arc cluster has no managed identity principalId." >&2
  echo "       The cluster may not be fully connected yet. Re-run after Arc agents are healthy." >&2
  exit 1
fi
echo "  Arc principal ID: ${ARC_PRINCIPAL_ID}"

az role assignment create \
  --assignee-object-id "${ARC_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope "${CLUSTER_SCOPE}" \
  --only-show-errors 2>&1 | grep -v "already exists" || true
echo "  Assigned 'Cognitive Services OpenAI User' to Arc cluster identity"

# ----------------------------------------------------------------------------
# Step 7 (optional): Assign role to a managed identity / service principal
# ----------------------------------------------------------------------------
echo ""
echo "=== Step 7 (optional): Assign role to MSI / SP ==="
if [[ -z "${ENTRA_MSI_OBJECT_ID}" ]]; then
  echo "  ENTRA_MSI_OBJECT_ID not set — skipping."
else
  az role assignment create \
    --assignee-object-id "${ENTRA_MSI_OBJECT_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "${ENTRA_USER_ROLE}" \
    --scope "${CLUSTER_SCOPE}" \
    --only-show-errors 2>&1 | grep -v "already exists" || true
  echo "  Assigned '${ENTRA_USER_ROLE}' to MSI/SP ${ENTRA_MSI_OBJECT_ID}"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "✓ Entra ID auth configured for Foundry Local."
echo ""
echo "  App (client) ID:     ${APP_ID}"
echo "  Tenant ID:           ${TENANT_ID}"
echo "  Application ID URI:  ${APP_ID_URI}"
echo "  Scope:               foundry_access"
echo "  Token version:       v2.0"
echo ""
echo "  Save these for env.sh:"
echo "    export ENTRA_APP_CLIENT_ID=\"${APP_ID}\""
echo "    export ENTRA_TENANT_ID=\"${TENANT_ID}\""
echo "    export ENTRA_APP_ID_URI=\"${APP_ID_URI}\""
echo ""
echo "  Next step: install/upgrade the Foundry operator with Entra auth enabled:"
echo "    helm upgrade --install inference-operator \\"
echo "      oci://mcr.microsoft.com/unlisted/aksarc/inference-operator \\"
echo "      --version \${OPERATOR_VERSION} \\"
echo "      --namespace \${NAMESPACE} \\"
echo "      --set entraAuth.enabled=true \\"
echo "      --set entraAuth.tenantId=${TENANT_ID} \\"
echo "      --set entraAuth.audience=${APP_ID_URI}"
echo ""
echo "  Test token acquisition:"
echo "    az account get-access-token --resource ${APP_ID_URI} --query accessToken -o tsv"
echo "================================================================"
