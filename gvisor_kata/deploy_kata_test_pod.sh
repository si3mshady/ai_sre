#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-kata-cluster}"
POD_IMAGE="${POD_IMAGE:-nginx:alpine}"
SERVICE_PORT="${SERVICE_PORT:-80}"

echo "=== Deploying Kata Test Pod ==="

# Use the first available kata runtime class
#RUNTIME_CLASS="kata-qemu"

RUNTIME_CLASS=$(kubectl get runtimeclass | grep '^kata-' | head -n1 | awk '{print $1}')

if [[ -z "$RUNTIME_CLASS" ]]; then
  echo "No kata runtime class found. Available classes:"
  kubectl get runtimeclass
  exit 1
fi

echo "Using runtime class: $RUNTIME_CLASS"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-agent-kata
  labels:
    app: test-agent-kata
spec:
  runtimeClassName: ${RUNTIME_CLASS}
  containers:
  - name: app
    image: ${POD_IMAGE}
    ports:
    - containerPort: ${SERVICE_PORT}
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo 'Serving JSON...' &&
      nc -l -p ${SERVICE_PORT} -e 'echo -e "HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\n\\r\\n{\\"pod\\": \\"test-agent-kata\\", \\"runtime_class\\": \\"${RUNTIME_CLASS}\\", \\"handler\\": \\"kata\\", \\"deployed_by\\": \\"helm-chart\\"}"'
EOF

kubectl wait --for=condition=ready pod/test-agent-kata --timeout=120s || {
  echo "Pod failed - checking events..."
  kubectl describe pod test-agent-kata
  exit 1
}

kubectl expose pod test-agent-kata --type=NodePort --port=80
IP=$(minikube ip --profile="$PROFILE")
PORT=$(kubectl get svc test-agent-kata -o jsonpath='{.spec.ports[0].nodePort}')

echo "=== READY! ==="
echo "curl http://${IP}:${PORT}/"
echo ""
echo "Status check:"
echo "kubectl get pod test-agent-kata -o yaml | grep runtimeClassName"
echo "kubectl -n kube-system get all | grep kata"
echo "kubectl get runtimeclass | grep ${RUNTIME_CLASS}"
