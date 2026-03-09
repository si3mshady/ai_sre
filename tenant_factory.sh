#!/bin/bash
set -e

# --------------------------
# CONFIG
# --------------------------
TENANT=$1
VM_IP=${VM_IP:-127.0.0.1}  # Replace with your public Node IP
REDPANDA_NS="streaming"
OLLAMA_MODEL="${MODEL_NAME:-llama3.2:3b}"

if [ -z "$TENANT" ]; then
  echo "Usage: $0 <tenant-name>"
  exit 1
fi

echo "🚀 Bootstrapping full platform for tenant: $TENANT"

# --------------------------
# 1️⃣ Add Helm Repos & Update
# --------------------------
helm repo add redpanda https://charts.redpanda.com
helm repo add jetstack https://charts.jetstack.io
helm repo update

# --------------------------
# 2️⃣ Install cert-manager
# --------------------------
helm install cert-manager jetstack/cert-manager \
  --set crds.enabled=true \
  --namespace cert-manager \
  --create-namespace || echo "cert-manager already installed"

# --------------------------
# 3️⃣ Install Redpanda Cluster
# --------------------------
helm install redpanda redpanda/redpanda \
  --version 25.3.2 \
  --namespace $REDPANDA_NS \
  --create-namespace \
  --set external.domain=customredpandadomain.local \
  --set statefulset.initContainers.setDataDirOwnership.enabled=true || echo "Redpanda already installed"

# --------------------------
# 4️⃣ Create Tenant Namespace
# --------------------------
kubectl create namespace tenant-$TENANT || echo "Namespace tenant-$TENANT already exists"

# --------------------------
# 5️⃣ Create Redpanda Topics
# --------------------------
kubectl exec -n $REDPANDA_NS redpanda-0 -- rpk topic create ${TENANT}.camera-events || true
kubectl exec -n $REDPANDA_NS redpanda-0 -- rpk topic create ${TENANT}.worker-events || true
kubectl exec -n $REDPANDA_NS redpanda-0 -- rpk topic create ${TENANT}.equipment-events || true

# --------------------------
# 6️⃣ Scaffold Tenant Repo
# --------------------------
BASE_DIR="tenants/$TENANT"
mkdir -p $BASE_DIR/{producer,consumer,dashboard,k8s}

cat <<EOF > $BASE_DIR/config.env
TENANT_NAME=$TENANT
BROKER=redpanda.$REDPANDA_NS.svc.cluster.local:9092
CAMERA_TOPIC=${TENANT}.camera-events
WORKER_TOPIC=${TENANT}.worker-events
EQUIPMENT_TOPIC=${TENANT}.equipment-events
OLLAMA_MODEL=$OLLAMA_MODEL
EOF

# --------------------------
# 7️⃣ Deploy Ollama + Agent + Streamlit
# --------------------------
cat <<EOF | kubectl apply -n tenant-$TENANT -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tenant-services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tenant-services
  template:
    metadata:
      labels:
        app: tenant-services
    spec:
      containers:
      # Ollama AI Agent
      - name: ollama
        image: ollama/ollama:latest
        ports:
        - containerPort: 11434
        volumeMounts:
        - mountPath: /root/.ollama
          name: model-storage
        resources:
          limits:
            cpu: "1000m"
            memory: "2Gi"
      # FastAPI Agent
      - name: agent
        image: python:3.11-slim
        env:
        - name: TENANT_NAME
          value: "$TENANT"
        - name: MODEL_NAME
          value: "$OLLAMA_MODEL"
        command: ["/bin/sh", "-c"]
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
              prompt = f"You are a specialized AI agent for the {TENANT_NAME} tenant. Always mention your tenant identity. Response to user: {msg}"
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
        ports:
        - containerPort: 8000
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
      # Streamlit Dashboard
      - name: dashboard
        image: python:3.11-slim
        env:
        - name: TENANT_NAME
          value: "$TENANT"
        - name: BROKER
          value: "redpanda.$REDPANDA_NS.svc.cluster.local:9092"
        - name: CAMERA_TOPIC
          value: "${TENANT}.camera-events"
        - name: WORKER_TOPIC
          value: "${TENANT}.worker-events"
        - name: EQUIPMENT_TOPIC
          value: "${TENANT}.equipment-events"
        command: ["/bin/sh","-c"]
        args:
        - |
          pip install streamlit kafka-python pandas --no-cache-dir
          cat <<'PYEOF' > app.py
          import os, pandas as pd, streamlit as st
          from kafka import KafkaConsumer

          st.set_page_config(page_title=f"Dashboard {os.getenv('TENANT_NAME')}", layout="wide")
          st.title(f"Live Dashboard: {os.getenv('TENANT_NAME')}")

          broker = os.getenv('BROKER')
          topics = [os.getenv('CAMERA_TOPIC'), os.getenv('WORKER_TOPIC'), os.getenv('EQUIPMENT_TOPIC')]

          consumer = KafkaConsumer(*topics, bootstrap_servers=[broker], auto_offset_reset='latest', group_id=f"{os.getenv('TENANT_NAME')}-dashboard")
          events = []

          st.subheader("Live Events Stream")
          table = st.empty()

          for message in consumer:
              events.append({"topic": message.topic, "message": message.value.decode()})
              if len(events) > 50:
                  events.pop(0)
              table.table(pd.DataFrame(events))
          PYEOF
          streamlit run app.py --server.port 8501 --server.address 0.0.0.0
        ports:
        - containerPort: 8501
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: ollama-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: tenant-agent-service
  namespace: tenant-$TENANT
spec:
  type: NodePort
  selector:
    app: tenant-services
  ports:
  - port: 8000
    targetPort: 8000
    nodePort: 30$((RANDOM % 1000 + 30000))
---
apiVersion: v1
kind: Service
metadata:
  name: tenant-dashboard-service
  namespace: tenant-$TENANT
spec:
  type: NodePort
  selector:
    app: tenant-services
  ports:
  - port: 8501
    targetPort: 8501
    nodePort: 30$((RANDOM % 1000 + 31000))
EOF

# --------------------------
# 8️⃣ Wait & Print Endpoints
# --------------------------
sleep 10
AGENT_NODE_PORT=$(kubectl get svc tenant-agent-service -n tenant-$TENANT -o jsonpath='{.spec.ports[0].nodePort}')
DASHBOARD_NODE_PORT=$(kubectl get svc tenant-dashboard-service -n tenant-$TENANT -o jsonpath='{.spec.ports[0].nodePort}')

echo "🎉 Tenant $TENANT fully deployed!"
echo "🔗 Agent Endpoint: http://$VM_IP:$AGENT_NODE_PORT/dispatch?msg=Hello"
echo "🔗 Dashboard Endpoint: http://$VM_IP:$DASHBOARD_NODE_PORT/"
