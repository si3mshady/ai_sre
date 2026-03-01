#!/bin/bash
# Sentinel: Enterprise Agentic Ops Environment (Production-Ready)
set -e

# ========= CONFIG: EDIT IF NEEDED =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-127.0.0.1}"
MODEL_NAME="${MODEL_NAME:-llama3}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
# =========================================

echo "🛡️ Bootstrapping Sentinel AI Ops Environment..."

############################################
# 1. CORE OPS & DEPENDENCIES
############################################
sudo apt-get update
sudo apt-get install -y curl git python3-pip python3-venv jq netcat-openbsd

# Docker Installation (skip if exists)
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker "$LINUX_USER"
fi

# Helm Installation
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

############################################
# 2. K3s CLUSTER CHECK & PROVISIONING
############################################
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    echo "✅ K3s already detected. Skipping installation."
else
    echo "🚀 Provisioning K3s Control Plane..."
    curl -sfL https://get.k3s.io | sudo sh -
fi

sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Persistent KUBECONFIG
if ! grep -q "KUBECONFIG=/etc/rancher/k3s/k3s.yaml" ~/.bashrc; then
  echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc
fi

# Kyverno Setup
echo "🛡️ Deploying Kyverno Policy Engine..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno \
  -n kyverno --create-namespace \
  --set admissionController.replicas=1

############################################
# 3. KYVERNO POLICIES (Admissions Control)
############################################
cat <<'EOF' > /tmp/sentinel-policies.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sentinel-governance
spec:
  validationFailureAction: enforce
  background: true
  rules:
    - name: require-team-label
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["default"]
      validate:
        message: "Governance Error: Pods in 'default' must have a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
    - name: block-privileged
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["default"]
      validate:
        message: "Security Error: Privileged containers are strictly prohibited."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"
EOF
kubectl apply -f /tmp/sentinel-policies.yaml

############################################
# 4. AGENTIC AI LAYER (OLLAMA)
############################################
if ! command -v ollama &> /dev/null; then
    echo "🧠 Installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh
fi

# Ensure Ollama is running and model is loaded
if ! nc -z localhost 11434 >/dev/null 2>&1; then
  sudo systemctl enable ollama || true
  sudo systemctl start ollama || true
  sleep 5
fi

echo "📥 Pre-loading Model: $MODEL_NAME (Keep-alive enabled)..."
ollama pull "$MODEL_NAME"

############################################
# 5. PROJECT ARCHITECTURE
############################################
mkdir -p "$PROJECT_ROOT/agent"
mkdir -p "$PROJECT_ROOT/app/data"
mkdir -p "$PROJECT_ROOT/k8s"

# --- AGENT SCRIPT ---
cat <<EOF > "$PROJECT_ROOT/agent/agent.py"
import os, requests, sqlite3, json, time
from datetime import datetime
from kubernetes import client, config, watch
from prometheus_client import start_http_server, Counter

KUBECONFIG_PATH = os.getenv("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")
MODEL_NAME = os.getenv("SENTINEL_MODEL", "$MODEL_NAME")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434")
DB_PATH = "/data/sentinel.db"

REMEDIATION_COUNT = Counter("sentinel_ai_remediations", "Total AI analyzed incidents")

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("CREATE TABLE IF NOT EXISTS incidents (id INTEGER PRIMARY KEY, pod_name TEXT, namespace TEXT, message TEXT, ai_analysis TEXT, suggested_patch TEXT, status TEXT, created_at TEXT)")
    conn.close()

def call_llm(msg):
    prompt = f"Context: K8s SRE. Task: Analyze this event: '{msg}'. Provide a JSON response with keys 'explanation' and 'patch' (a kubectl label command for sentinel-ai-remediated=true)."
    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={"model": MODEL_NAME, "prompt": prompt, "stream": False, "keep_alive": -1},
            timeout=120
        )
        return r.json().get("response", "{}")
    except Exception as e:
        return f"Error: {str(e)}"

def main_loop():
    init_db()
    start_http_server(8000)
    config.load_kube_config(config_file=KUBECONFIG_PATH)
    v1 = client.CoreV1Api()
    print("📡 Sentinel Agent Watching for Cluster Events...")
    w = watch.Watch()
    for event in w.stream(v1.list_namespaced_event, namespace="default"):
        obj = event["object"]
        if obj.type == "Warning" and "kyverno" not in obj.source.component:
            analysis = call_llm(obj.message)
            conn = sqlite3.connect(DB_PATH)
            conn.execute("INSERT INTO incidents (pod_name, namespace, message, ai_analysis, status, created_at) VALUES (?,?,?,?,?,?)",
                        (obj.involved_object.name, obj.involved_object.namespace, obj.message, analysis, "ANALYZED", datetime.now().isoformat()))
            conn.commit()
            conn.close()
            REMEDIATION_COUNT.inc()

if __name__ == "__main__":
    main_loop()
EOF

# --- DASHBOARD SCRIPT ---
cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st
import sqlite3, os, pandas as pd

st.set_page_config(page_title="Sentinel AI", layout="wide")

st.markdown("""
    <style>
    .stApp { background-color: #0b0e14; color: #ffffff; }
    [data-testid="stHeader"] { background: rgba(0,0,0,0); }
    .reportview-container .main { background: #0b0e14; }
    .st-emotion-cache-1kyx7v6 { 
        background-color: #161b22; 
        border: 1px solid #00ff41; 
        border-radius: 10px; 
        padding: 20px; 
        box-shadow: 0 0 10px rgba(0, 255, 65, 0.2);
    }
    h1 { color: #00ff41; font-family: 'Courier New', monospace; text-shadow: 0 0 10px #00ff41; }
    h2, h3 { color: #00ff41 !important; }
    .incident-card { 
        background: #1c2128; 
        border-left: 5px solid #ff4b4b; 
        padding: 15px; 
        margin: 10px 0; 
        border-radius: 4px; 
    }
    .stDataFrame { border: 1px solid #30363d; }
    </style>
""", unsafe_allow_html=True)

st.title("🛡️ SENTINEL: AUTONOMOUS GOVERNANCE")

db = "/app/data/sentinel.db"
if os.path.exists(db):
    conn = sqlite3.connect(db)
    df = pd.read_sql_query("SELECT * FROM incidents ORDER BY created_at DESC", conn)
    st.subheader("📊 Cluster Event Intelligence")
    st.dataframe(df, use_container_width=True)
    conn.close()
else:
    st.info("📡 System standing by. Waiting for cluster events...")

if st.button("Manual Log Refresh"):
    st.rerun()
EOF

# Build Dockerfiles
cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes requests prometheus_client
COPY agent.py /agent.py
CMD ["python", "/agent.py"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit pandas
COPY app.py /app.py
WORKDIR /
CMD ["streamlit", "run", "/app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

# --- K8S DEPLOYMENT ---
cat <<EOF > "$PROJECT_ROOT/k8s/sentinel.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: sentinel
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sentinel-dashboard
  namespace: sentinel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sentinel-dashboard
  template:
    metadata:
      labels:
        app: sentinel-dashboard
    spec:
      containers:
      - name: dashboard
        image: sentinel-dashboard:latest
        ports:
        - containerPort: 8501
        volumeMounts:
        - name: data
          mountPath: /app/data
      volumes:
      - name: data
        hostPath:
          path: $PROJECT_ROOT/app/data
---
apiVersion: v1
kind: Service
metadata:
  name: sentinel-dashboard
  namespace: sentinel
spec:
  type: NodePort
  selector:
    app: sentinel-dashboard
  ports:
  - port: 8501
    nodePort: 30501
EOF

echo "✅ CONFIGURATION COMPLETE."
echo "-------------------------------------------------------"
echo "RUN THESE COMMANDS TO FINALIZE:"
echo "1. cd $PROJECT_ROOT/agent && sudo docker build -t sentinel-agent:latest ."
echo "2. cd $PROJECT_ROOT/app && sudo docker build -t sentinel-dashboard:latest ."
echo "3. sudo k3s ctr images import <(sudo docker save sentinel-agent:latest)"
echo "4. sudo k3s ctr images import <(sudo docker save sentinel-dashboard:latest)"
echo "5. kubectl apply -f $PROJECT_ROOT/k8s/sentinel.yaml"
echo "-------------------------------------------------------"
