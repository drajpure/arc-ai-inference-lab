#!/usr/bin/env bash
# 09-configure-entra-auth.sh
# Configure Microsoft Entra ID authentication for Foundry Local on Arc.
#
# Implements the 7-step process from:
# https://learn.microsoft.com/azure/ai-foundry/foundry-local/how-to-configure-authentication
#
# Steps:
#   1. Register an Entra app (single-tenant)
#   2. Expose API — set Application ID URI + add 'foundry_access' delegated scope
#   3. Set accessTokenAcceptedVersion to 2 (v2.0 tokens)
#   4. Authorize Azure CLI as a known client
#   5. Assign a user/group an RBAC role on the connected cluster
#   6. Grant the cluster's Arc identity 'Cognitive Services OpenAI User'
#   7. (Optional) Assign role to a managed identity / service principal
#
# Prerequisites:
#   - Cluster connected to Arc (01b-connect-arc.sh)
#   - Caller has Application Administrator Entra permissions
#   - Caller has Owner / User Access Administrator on connectedCluster scope
#
# Re-run safe: all operations are idempotent.

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ env.sh not found. Copy env.sh.example to env.sh and fill in your values."
  exit 1
fi
source "$ENV_FILE"

# === Entra Auth Configuration ===
ENTRA_APP_NAME="${ENTRA_APP_NAME:-FoundryLocal-${ARC_CLUSTER_NAME}}"
ENTRA_USER_OR_GROUP_OBJECT_ID="${ENTRA_USER_OR_GROUP_OBJECT_ID:-}"
ENTRA_USER_ROLE="${ENTRA_USER_ROLE:-Cognitive Services OpenAI User}"
ENTRA_MSI_OBJECT_ID="${ENTRA_MSI_OBJECT_ID:-}"

# Azure CLI client ID (well-known, do not change)
AZ_CLI_CLIENT_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"

CLUSTER_SCOPE="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${ARC_RESOURCE_GROUP}/providers/Microsoft.Kubernetes/connectedClusters/${ARC_CLUSTER_NAME}"

echo "=== Configure Entra ID Auth for Foundry Local ==="
echo "  App name:    $ENTRA_APP_NAME"
echo "  Arc cluster: $ARC_CLUSTER_NAME"
echo "  Cluster scope: $CLUSTER_SCOPE"
echo "  User/group:  ${ENTRA_USER_OR_GROUP_OBJECT_ID:-<not set — Step 5 skipped>}"
echo ""

# Validate
for cmd in az jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ '$cmd' not found."
    exit 1
  fi
done

if ! az account show &>/dev/null; then
  echo "❌ Not logged into Azure CLI."
  exit 1
fi

TENANT_ID_ACTUAL=$(az account show --query tenantId -o tsv)

# Verify Arc cluster exists
if ! az connectedk8s show -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" &>/dev/null; then
  echo "❌ Arc cluster '$ARC_CLUSTER_NAME' not found. Run 01b-connect-arc.sh first."
  exit 1
fi

# ============================================================================
# Step 1: Register (or look up) the Entra app
# ============================================================================
echo "--- Step 1: Entra app registration ---"
APP_ID=$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -z "$APP_ID" ]]; then
  echo "  Creating app '$ENTRA_APP_NAME'..."
  APP_ID=$(az ad app create \
    --display-name "$ENTRA_APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  sleep 5  # Allow Entra propagation
else
  echo "  Reusing existing app: $APP_ID"
fi

APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)
echo "  ✅ App ID: $APP_ID"
echo ""

# ============================================================================
# Step 2: Expose API (Application ID URI + foundry_access scope)
# ============================================================================
echo "--- Step 2: Expose API ---"
APP_ID_URI="api://${APP_ID}"

EXISTING_SCOPE_ID=$(az ad app show --id "$APP_ID" \
  --query "api.oauth2PermissionScopes[?value=='foundry_access'].id | [0]" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_SCOPE_ID" ]]; then
  echo "  ✅ 'foundry_access' scope already exists (id=$EXISTING_SCOPE_ID)"
  SCOPE_ID="$EXISTING_SCOPE_ID"
else
  SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
             python -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
             cat /proc/sys/kernel/random/uuid 2>/dev/null || \
             uuidgen)

  TMP_FILE=$(mktemp)
  cat > "$TMP_FILE" <<EOF
{
  "oauth2PermissionScopes": [
    {
      "id": "${SCOPE_ID}",
      "adminConsentDescription": "Access Foundry Local inference endpoints",
      "adminConsentDisplayName": "Access Foundry Local inference endpoints",
      "isEnabled": true,
      "type": "Admin",
      "value": "foundry_access"
    }
  ]
}
EOF

  az ad app update --id "$APP_ID" \
    --identifier-uris "$APP_ID_URI" \
    --set api=@"$TMP_FILE"
  rm -f "$TMP_FILE"
  echo "  ✅ Created scope 'foundry_access' (id=$SCOPE_ID)"
fi
echo "  Application ID URI: $APP_ID_URI"
echo ""

# ============================================================================
# Step 3: Force v2.0 tokens
# ============================================================================
echo "--- Step 3: Set accessTokenAcceptedVersion=2 ---"
az ad app update --id "$APP_ID" --set api.requestedAccessTokenVersion=2
echo "  ✅ Token version set to v2.0"
echo ""

# ============================================================================
# Step 4: Authorize Azure CLI as pre-authorized client
# ============================================================================
echo "--- Step 4: Authorize Azure CLI as known client ---"
PRE_AUTH=$(az ad app show --id "$APP_ID" \
  --query "api.preAuthorizedApplications[?appId=='${AZ_CLI_CLIENT_ID}'] | [0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$PRE_AUTH" ]]; then
  echo "  ✅ Azure CLI already pre-authorized"
else
  TMP_FILE=$(mktemp)
  cat > "$TMP_FILE" <<EOF
[
  {
    "appId": "${AZ_CLI_CLIENT_ID}",
    "delegatedPermissionIds": ["${SCOPE_ID}"]
  }
]
EOF
  az ad app update --id "$APP_ID" --set api.preAuthorizedApplications=@"$TMP_FILE"
  rm -f "$TMP_FILE"
  echo "  ✅ Azure CLI pre-authorized for 'foundry_access'"
fi
echo ""

# ============================================================================
# Step 5: Assign user/group role on connected cluster
# ============================================================================
echo "--- Step 5: Assign user/group role ---"
if [[ -z "$ENTRA_USER_OR_GROUP_OBJECT_ID" ]]; then
  echo "  ⏭️  ENTRA_USER_OR_GROUP_OBJECT_ID not set — skipping"
  echo "  To grant later:"
  echo "    az role assignment create --assignee <OID> --role '$ENTRA_USER_ROLE' --scope '$CLUSTER_SCOPE'"
else
  az role assignment create \
    --assignee "$ENTRA_USER_OR_GROUP_OBJECT_ID" \
    --role "$ENTRA_USER_ROLE" \
    --scope "$CLUSTER_SCOPE" \
    --only-show-errors 2>&1 | grep -v "already exists" || true
  echo "  ✅ Assigned '$ENTRA_USER_ROLE' to $ENTRA_USER_OR_GROUP_OBJECT_ID"
fi
echo ""

# ============================================================================
# Step 6: Grant Arc cluster identity 'Cognitive Services OpenAI User' (REQUIRED)
# ============================================================================
echo "--- Step 6: Grant Arc identity RBAC (REQUIRED) ---"
ARC_PRINCIPAL_ID=$(az connectedk8s show \
  -n "$ARC_CLUSTER_NAME" -g "$ARC_RESOURCE_GROUP" \
  --query "identity.principalId" -o tsv)

if [[ -z "$ARC_PRINCIPAL_ID" || "$ARC_PRINCIPAL_ID" == "null" ]]; then
  echo "❌ Arc cluster has no managed identity principalId."
  echo "   Cluster may not be fully connected. Wait for Arc agents to be healthy."
  exit 1
fi

az role assignment create \
  --assignee-object-id "$ARC_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope "$CLUSTER_SCOPE" \
  --only-show-errors 2>&1 | grep -v "already exists" || true
echo "  ✅ Assigned 'Cognitive Services OpenAI User' to Arc identity ($ARC_PRINCIPAL_ID)"
echo ""

# ============================================================================
# Step 7: (Optional) Assign role to managed identity / service principal
# ============================================================================
echo "--- Step 7: Assign role to MSI/SP (optional) ---"
if [[ -z "$ENTRA_MSI_OBJECT_ID" ]]; then
  echo "  ⏭️  ENTRA_MSI_OBJECT_ID not set — skipping"
else
  az role assignment create \
    --assignee-object-id "$ENTRA_MSI_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$ENTRA_USER_ROLE" \
    --scope "$CLUSTER_SCOPE" \
    --only-show-errors 2>&1 | grep -v "already exists" || true
  echo "  ✅ Assigned '$ENTRA_USER_ROLE' to MSI/SP $ENTRA_MSI_OBJECT_ID"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "================================================================"
echo "✅ Entra ID auth configured for Foundry Local"
echo ""
echo "  App (client) ID:     $APP_ID"
echo "  Tenant ID:           $TENANT_ID_ACTUAL"
echo "  Application ID URI:  $APP_ID_URI"
echo "  Scope:               foundry_access"
echo "  Token version:       v2.0"
echo ""
echo "  Add to env.sh:"
echo "    export ENTRA_APP_CLIENT_ID=\"$APP_ID\""
echo "    export ENTRA_APP_ID_URI=\"$APP_ID_URI\""
echo ""
echo "  Test token acquisition:"
echo "    az account get-access-token --resource $APP_ID_URI --query accessToken -o tsv"
echo ""
echo "  Note: The Arc Extension does not currently support entraAuth config"
echo "  settings. Entra auth may require a Helm-based install or future"
echo "  extension version that accepts auth settings."
echo "================================================================"
