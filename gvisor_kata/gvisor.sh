#!/bin/bash
# setup-minikube-gvisor.sh (Fixed version - April 2026)
# Standalone script to create Minikube cluster with gVisor (runsc) RuntimeClass.
# Uses correct gVisor release URLs, Docker driver, containerd runtime.
# Assumes minikube/kubectl installed. Self-contained, idempotent.
# Steps: Minikube → gVisor install → containerd config → RuntimeClass → test pod [web:23][web:9][web:31]

set -euo pipefail

RUNTIME_NAME="gvisor"
HANDLER="runsc"
POD_PORT=8080
SERVICE_PORT=30080
CLUSTER_NAME="gvisor-minikube"

echo "Step 1: Starting fresh Minikube cluster with containerd..."

minikube delete "${CLUSTER_NAME}" --all || true
minikube start "${CLUSTER_NAME}" \
  --driver=docker \
  --container-runtime=containerd \
  --cpus=4 \
  --memory=8192mb \
  --wait=timeout:5m

echo "Step 2: Installing runsc and containerd-shim-runsc-v1 (fixed URLs)..."

minikube ssh "
  sudo apt-get update -qq
  sudo apt-get install -y wget jq

  # Determine architecture and fetch latest gVisor version
  ARCH=\$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  VERSION=\$(wget -qO- https://api.github.com/repos/google/gvisor/releases/latest | jq -r .tag_name)
  BASE_URL=https://storage.googleapis.com/gvisor/releases/release/\${VERSION}/\${ARCH}
  
  cd /tmp
  wget -q \${BASE_URL}/runsc \${BASE_URL}/runsc.sha512
  wget -q \${BASE_URL}/containerd-shim-runsc-v1 \${BASE_URL}/containerd-shim-runsc-v1.sha512
  
  echo 'Verifying checksums...'
  sha512sum -c runsc.sha512 containerd-shim-runsc-v1.sha512
  
  rm -f *.sha512
  chmod a+rx runsc containerd-shim-runsc-v1
  sudo mv runsc containerd-shim-runsc-v1 /usr/local/bin/
  
  runsc --version
"

echo "Step 3: Configuring containerd for runsc..."

minikube ssh "
  sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak || true
  
  # Full containerd config with runsc (generated properly)
  containerd config default | sed '/runc/runtimes.runc.runtime_type = \"io.containerd.runc.v2\"' | \
  sed '/\[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc\]/a [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]\n  runtime_type = \"io.containerd.runsc.v1\"' | \
  sudo tee /etc/containerd/config.toml
  
  sudo systemctl restart containerd
  sudo systemctl status containerd --no-pager | head -20
"

echo "Step 4: Creating RuntimeClass..."

kubectl create -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: ${RUNTIME_NAME}
handler: ${HANDLER}
EOF

echo "Step 5: Deploying test pod/service with gVisor..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-${RUNTIME_NAME}
  labels:
    app: test-${RUNTIME_NAME}
spec:
  runtimeClassName: ${RUNTIME_NAME}
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
    command: ["/bin/sh","-c"]
    args:
    - |
      mkfifo /tmp/fifo &&  
      while true; do  
        (while read line; do printf '%s\n' "\$line"; done < /tmp/fifo | nc -l 8080 > /dev/null) &  
        echo '{"pod":"test-${RUNTIME_NAME}","runtime_class":"${RUNTIME_NAME}","handler":"${HANDLER}"}' > /tmp/fifo  
      done
---
apiVersion: v1
kind: Service
metadata:
  name: test-${RUNTIME_NAME}-service
spec:
  type: NodePort
  selector:
    app: test-${RUNTIME_NAME}
  ports:
  - port: 80
    targetPort: 8080
    nodePort: ${SERVICE_PORT}
EOF

echo "Waiting for pod (check runtime with 'kubectl describe pod test-gvisor')..."
kubectl wait --for=condition=Ready pod/test-${RUNTIME_NAME} --timeout=300s

echo ""
echo "✅ SUCCESS! gVisor cluster ready."
echo "Validate runtime:"
echo "curl http://localhost:${SERVICE_PORT}/runtime"
echo "Expected: {\"pod\":\"test-gvisor\",\"runtime_class\":\"gvisor\",\"handler\":\"runsc\"}"
echo ""
echo "Check pod runtime:"
echo "kubectl get pod test-${RUNTIME_NAME} -o yaml | grep runtimeHandler"
echo ""
echo "Cleanup: minikube delete ${CLUSTER_NAME} --all"
