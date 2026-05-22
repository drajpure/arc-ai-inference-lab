#!/bin/bash
# 05-deploy-model.sh
# Deploy a catalog model and validate inference.
set -euo pipefail

NAMESPACE="${NAMESPACE:-foundry-local-operator}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen2.5-coder-0.5b}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-test-model-deploy}"

echo "=== Deploying model: ${MODEL_ALIAS} ==="

cat <<EOF | kubectl apply -f -
apiVersion: foundrylocal.azure.com/v1
kind: ModelDeployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
spec:
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

echo "=== Waiting for model to become ready ==="
for i in $(seq 1 60); do
  STATE=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
  READY=$(kubectl get modeldeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
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

# Port-forward in background
kubectl port-forward "svc/${DEPLOYMENT_NAME}" 5000:5000 -n "${NAMESPACE}" &
PF_PID=$!
sleep 3

# Call inference
RESPONSE=$(curl -sk https://localhost:5000/v1/chat/completions \
  -H "api-key: ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one sentence.\"}],\"max_tokens\":50}")

# Cleanup port-forward
kill $PF_PID 2>/dev/null || true

echo ""
echo "=== Inference Response ==="
echo "${RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${RESPONSE}"

# Validate
if echo "${RESPONSE}" | grep -q '"successful": true\|"finish_reason": "stop"'; then
  echo ""
  echo "✓ Inference validation PASSED"
  exit 0
else
  echo ""
  echo "✗ Inference validation FAILED"
  exit 1
fi
