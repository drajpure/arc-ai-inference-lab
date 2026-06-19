#!/bin/bash
# 07-deploy-and-validate.sh
# Deploy a Foundry Local catalog model and validate inference end-to-end.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh" 2>/dev/null || true

NAMESPACE="${NAMESPACE:-foundry-local-operator}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen2.5-coder-0.5b}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-qwen-coder-deploy}"

echo "=== Deploying model: ${MODEL_ALIAS} as '${DEPLOYMENT_NAME}' in ${NAMESPACE} ==="

cat <<EOF | kubectl apply -f -
apiVersion: foundrylocal.azure.com/v1
kind: ModelDeployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
spec:
  displayName: "${MODEL_ALIAS} (validation)"
  model:
    catalog:
      name: "${MODEL_ALIAS}"
  workloadType: generative
  compute: cpu
  runtime: onnx-genai
  replicas: 1
  resources:
    requests:
      cpu: "500m"
      memory: "2Gi"
    limits:
      cpu: "4000m"
      memory: "4Gi"
EOF

# Check readiness using multiple possible status paths.
# Different operator versions populate different fields:
#   - Some set .status.ready (boolean) directly
#   - Some only set .status.conditions[type=Ready]
#   - Some populate the kubectl printer columns (parsed via wide output) but not jsonpath
get_ready_state() {
  local r
  # Path 1: .status.ready (older versions)
  r=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.ready}' 2>/dev/null)
  [[ "${r}" == "true" ]] && { echo "true"; return; }

  # Path 2: Ready condition
  r=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "${r}" == "True" ]] && { echo "true"; return; }

  # Path 3: parse the kubectl printer columns (column 5 = READY)
  # Use awk to be tolerant of column-width changes.
  r=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
    --no-headers 2>/dev/null | awk '{print $5}')
  [[ "${r}" == "true" || "${r}" == "True" ]] && { echo "true"; return; }

  # Path 4: state=Running + readyReplicas == spec.replicas
  local state ready_r desired_r
  state=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.state}' 2>/dev/null)
  ready_r=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  desired_r=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [[ "${state}" == "Running" && -n "${ready_r}" && "${ready_r}" == "${desired_r}" ]]; then
    echo "true"; return
  fi

  echo "false"
}

echo "=== Waiting for model to become ready (up to 10 min) ==="
READY="false"
for i in $(seq 1 60); do
  STATE=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
  READY=$(get_ready_state)
  echo "  [${i}/60] state=${STATE} ready=${READY}"
  if [[ "${READY}" == "true" ]]; then
    echo ""
    echo "✓ Model deployment is Ready!"
    break
  fi
  sleep 10
done

if [[ "${READY}" != "true" ]]; then
  echo "✗ Model did not become ready within 10 minutes."
  kubectl get pods -n "${NAMESPACE}"
  exit 1
fi

echo ""
echo "=== Running inference test ==="

# Get API key
API_KEY=$(kubectl get secret "${DEPLOYMENT_NAME}-api-keys" -n "${NAMESPACE}" \
  -o jsonpath='{.data.primary-key}' | base64 -d)

# Port-forward in background — cleanup on any exit path
kubectl port-forward "svc/${DEPLOYMENT_NAME}" 5000:5000 -n "${NAMESPACE}" &
PF_PID=$!
cleanup() {
  kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT
sleep 3

# Call inference
RESPONSE=$(curl -sk https://localhost:5000/v1/chat/completions \
  -H "api-key: ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one sentence.\"}],\"max_tokens\":50}")

echo ""
echo "=== Inference Response ==="
echo "${RESPONSE}" | python3 -m json.tool 2>/dev/null || \
  echo "${RESPONSE}" | jq . 2>/dev/null || \
  echo "${RESPONSE}"

# Validate
if echo "${RESPONSE}" | grep -q '"finish_reason":\s*"stop"\|"successful":\s*true'; then
  echo ""
  echo "✓ Inference validation PASSED"
  exit 0
else
  echo ""
  echo "✗ Inference validation FAILED"
  exit 1
fi
