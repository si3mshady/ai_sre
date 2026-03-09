#!/bin/bash
# Tenant Factory + Real-Time Redpanda Streaming Dashboard + Ollama AI
# Golden Drop-In Replacement
# Elliot Arnold — 2026-03-08

# ================= GLOBAL CONFIG =================
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/self_gov"
MODEL_NAME="${MODEL_NAME:-llama3.2:3b}"
REDPANDA_NS="streaming"
TENANT_BASE_NS="tenant"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "================ Tenant Factory v1.0 ================="
echo "[INFO] Using Linux user: $LINUX_USER"
echo "[INFO] Project root: $PROJECT_ROOT"
echo "======================================================="

# ================= PERMISSIONS FIX =================
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# ================= HELM REPOS =================
helm repo add redpanda https://charts.redpanda.com || true
helm repo add jetstack https://charts.jetstack.io || true
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo update

# ================= CERT-MANAGER =================
if ! helm status cert-manager -n cert-manager >/dev/null 2>&1; then
    echo "[INSTALL] Deploying cert-manager..."
    helm install cert-manager jetstack/cert-manager \
        --set crds.enabled=true \
        --namespace cert-manager \
        --create-namespace
fi

# ================= KYVERNO =================
if ! helm status kyverno -n kyverno >/dev/null 2>&1; then
    echo "[INSTALL] Deploying Kyverno..."
    helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
fi

# ================= REDPANDA (AUTO NODEPORT) =================
if ! helm status redpanda -n $REDPANDA_NS >/dev/null 2>&1; then
    echo "[INSTALL] Deploying Redpanda with auto-assigned NodePorts..."
    helm install redpanda redpanda/redpanda \
        --version 25.3.2 \
        --namespace $REDPANDA_NS \
        --create-namespace \
        --set external.domain=customredpandadomain.local \
        --set statefulset.initContainers.setDataDirOwnership.enabled=true \
        --set external.nodePort0=null \
        --set external.nodePort1=null \
        --set external.nodePort2=null \
        --wait
else
    echo "[SKIP] Redpanda already installed"
fi

# Wait for Redpanda pods
echo "[INFO] Waiting for Redpanda pods to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=redpanda -n $REDPANDA_NS --timeout=180s

# ================= TENANT FACTORY FUNCTION =================
deploy_tenant() {
    TENANT_NAME=$1
    CPU_LIMIT=${2:-"1000m"}
    MEM_LIMIT=${3:-"2Gi"}
    TENANT_NS="$TENANT_BASE_NS-$TENANT_NAME"

    echo "🚀 Bootstrapping tenant: $TENANT_NAME..."
    kubectl create namespace $TENANT_NS --dry-run=client -o yaml | kubectl apply -f -

    # --- Persistent Volume Claim ---
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-pvc
  namespace: $TENANT_NS
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources:
    requests:
      storage: 5Gi
EOF

    # --- Tenant Deployment: AI Agent + Streamlit Dashboard ---
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tenant-services
  namespace: $TENANT_NS
spec:
  replicas: 1
  selector:
    matchLabels: { app: tenant-services }
  template:
    metadata:
      labels: { app: tenant-services, team: "${TENANT_NAME}" }
    spec:
      containers:
      - name: agent
        image: python:3.11-slim
        env:
        - name: TENANT_NAME
          value: "${TENANT_NAME}"
        - name: MODEL_NAME
          value: "${MODEL_NAME}"
        command: ["/bin/sh","-c"]
        args:
        - |
          pip install fastapi uvicorn requests --no-cache-dir
          cat <<'PYEOF' > main.py
          import os, requests, uvicorn
          from fastapi import FastAPI
          
          app = FastAPI()
          TENANT_NAME = os.getenv('TENANT_NAME', 'Unknown')
          MODEL_NAME = os.getenv('MODEL_NAME', 'llama3.2:3b')

          @app.get('/dispatch')
          async def d(msg: str):
              prompt = f"You are a specialized AI agent for {TENANT_NAME}. Respond to user: {msg}"
              try:
                  r = requests.post('http://localhost:11434/api/generate', 
                                    json={'model': MODEL_NAME, 'prompt': prompt, 'stream': False},
                                    timeout=120)
                  return r.json()
              except Exception as e:
                  return {"error": str(e)}

          if __name__ == '__main__':
              uvicorn.run(app, host='0.0.0.0', port=8000)
          PYEOF
          python main.py
        ports: [{ containerPort: 8000 }]
        resources:
          limits: { cpu: "500m", memory: "512Mi" }

      - name: ollama
        image: ollama/ollama:latest
        ports: [{ containerPort: 11434 }]
        volumeMounts:
        - name: model-storage
          mountPath: /root/.ollama
        resources:
          limits: { cpu: "${CPU_LIMIT}", memory: "${MEM_LIMIT}" }

      - name: streamlit-dashboard
        image: python:3.11-slim
        env:
        - name: TENANT_NAME
          value: "${TENANT_NAME}"
        command: ["/bin/sh","-c"]
        args:
        - |
          pip install streamlit redpanda kafka-python pandas --no-cache-dir
          mkdir -p /app
          cat <<'STEOF' > /app/dashboard.py
          import streamlit as st
          import pandas as pd
          from kafka import KafkaConsumer
          import json, os, threading

          TENANT_NAME = os.getenv("TENANT_NAME", "Unknown")
          TOPIC = f"{TENANT_NAME}-events"
          BROKER = "redpanda.streaming.svc.cluster.local:9092"

          st.title(f"Real-Time Dashboard for {TENANT_NAME}")

          # Data frame for events
          df = pd.DataFrame(columns=["timestamp","event"])

          def consume_events():
              consumer = KafkaConsumer(
                  TOPIC,
                  bootstrap_servers=[BROKER],
                  auto_offset_reset='earliest',
                  value_deserializer=lambda x: json.loads(x.decode('utf-8'))
              )
              global df
              for msg in consumer:
                  row = pd.DataFrame([{"timestamp": msg.value.get("timestamp"), "event": msg.value.get("event")}])
                  df = pd.concat([df, row], ignore_index=True)
          threading.Thread(target=consume_events, daemon=True).start()

          st.dataframe(df)
          STEOF
          streamlit run /app/dashboard.py --server.port 8501 --server.address 0.0.0.0
        ports: [{ containerPort: 8501 }]
        resources:
          limits: { cpu: "500m", memory: "512Mi" }

      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: ollama-pvc
EOF

    # --- Create Services ---
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: tenant-agent-service
  namespace: $TENANT_NS
spec:
  type: NodePort
  selector: { app: tenant-services }
  ports: [{ port: 8000 }]
---
apiVersion: v1
kind: Service
metadata:
  name: tenant-dashboard-service
  namespace: $TENANT_NS
spec:
  type: NodePort
  selector: { app: tenant-services }
  ports: [{ port: 8501 }]
EOF

    # --- Print endpoints ---
    AGENT_PORT=$(kubectl get svc tenant-agent-service -n $TENANT_NS -o jsonpath='{.spec.ports[0].nodePort}')
    DASHBOARD_PORT=$(kubectl get svc tenant-dashboard-service -n $TENANT_NS -o jsonpath='{.spec.ports[0].nodePort}')

    echo "✅ Tenant $TENANT_NAME deployed!"
    echo "🔗 AI Agent endpoint: http://$VM_IP:$AGENT_PORT/dispatch?msg=Hello"
    echo "📊 Streamlit Dashboard: http://$VM_IP:$DASHBOARD_PORT"
    echo ""
    echo "💡 Kafka Topic for events: ${TENANT_NAME}-events"
    echo "💡 Redpanda Broker: redpanda.$REDPANDA_NS.svc.cluster.local:9092"
}

# ================= FINAL OUTPUT =================
echo "======================================================="
echo "Tenant Factory ready!"
echo "Use: deploy_tenant 'tenant-name' to spin up a tenant."
echo "Redpanda broker namespace: $REDPANDA_NS"
kubectl get svc -n $REDPANDA_NS
echo "======================================================="
