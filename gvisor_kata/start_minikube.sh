#!/usr/bin/env bash
set -euo pipefail

PROFILE="kata-cluster"
POD_IMAGE="nginx:alpine"
SERVICE_PORT=80

echo "=== Minikube + Kata Helm Chart (Robust) ==="

minikube delete --all
minikube start --profile="$PROFILE" --driver=docker --container-runtime=containerd --cpus=4 --memory=8192
kubectl config use-context "$PROFILE"

# Install Helm
minikube ssh --profile="$PROFILE" "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

# Install Kata Helm chart (kube-system per official docs)
VERSION=$(curl -sSL https://api.github.com/repos/kata-containers/kata-containers/releases/latest | jq -r .tag_name)
CHART="oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy"

helm install kata-deploy \
  --namespace kube-system \
  --version "$VERSION" \
  "$CHART" \
  --wait --timeout=10m --atomic

echo "=== Checking Kata deployment status ==="
sleep 120  # Give DaemonSet time to run

# Robust job/daemonset detection (handles different chart versions)
if kubectl -n kube-system get job -l app.kubernetes.io/name=kata-deploy &>/dev/null; then
  kubectl -n kube-system wait --for=condition=complete job -l app.kubernetes.io/name=kata-deploy --timeout=300s
elif kubectl -n kube-system get daemonset -l app.kubernetes.io/name=kata-deploy &>/dev/null; then
  kubectl -n kube-system rollout status daemonset -l app.kubernetes.io/name=kata-deploy --timeout=300s
fi

# Verify RuntimeClass was created
kubectl get runtimeclass | grep kata || echo "RuntimeClass not found - checking logs..."

echo "=== Deploying test pod ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-agent-kata
  labels:
    app: test-agent-kata
spec:
  runtimeClassName: kata
  containers:
  - name: app
    image: ${POD_IMAGE}
    ports:
    - containerPort: ${SERVICE_PORT}
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo 'Serving JSON...' &&
      nc -l -p ${SERVICE_PORT} -e 'echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"pod\": \"test-agent-kata\", \"runtime_class\": \"kata\", \"handler\": \"kata\", \"deployed_by\": \"helm-chart\"}"'
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
echo "kubectl -n kube-system get all | grep kata"
echo "kubectl get runtimeclass"
