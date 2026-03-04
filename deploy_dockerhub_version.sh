#!/bin/bash
# Sentinel Prime: v9.0 — THE MASTER GOLDEN COPY (CI/CD ENHANCED)
# TARGET: si3mshady/cicd repo using component-based tags
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
MODEL_NAME="${MODEL_NAME:-llama3}"
DOCKER_USER="si3mshady"
DOCKER_REPO="cicd"
VERSION="v9.0"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "================ Sentinel v9.0 — THE MASTER GOLDEN COPY =============="
echo "[INFO] Using Linux user: $LINUX_USER"
echo "[INFO] Project root: $PROJECT_ROOT"
echo "[INFO] Docker Hub Target: $DOCKER_USER/$DOCKER_REPO"
echo "========================================================================"

echo "🧹 Purging Old State..."
kubectl delete ns sentinel 2>/dev/null || true
kubectl delete clusterrolebinding sentinel-agent-rbac-v90 2>/dev/null || true
sudo rm -rf /home/sentinel-data
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s,monitoring}
sudo mkdir -p /home/sentinel-data
sudo chmod -R 777 /home/sentinel-data

############################################
# 1. KYVERNO + POLICY 
############################################
echo "🛡️ Deploying Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

cat <<'EOF' > "$PROJECT_ROOT/k8s/policies.yaml"
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sentinel-guardrails
spec:
  validationFailureAction: enforce
  background: true
  rules:
    - name: require-resources
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["sentinel", "kube-system", "kyverno"]
      validate:
        message: "CPU/Memory limits required to prevent OOMKilled events."
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    cpu: "?*"
                    memory: "?*"
    - name: require-team-label
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["sentinel", "kube-system", "kyverno"]
      validate:
        message: "'team' label required for SRE accountability."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
kubectl apply -f "$PROJECT_ROOT/k8s/policies.yaml"

############################################
# 2. BUILD AND PUSH COMPONENT IMAGES
############################################
# --- AGENT (WITH SRE KNOWLEDGE BASE) ---
cat <<'EOF' > "$PROJECT_ROOT/agent/agent.py"
import os, time, requests, sqlite3, hashlib, logging
from datetime import datetime, timezone
from kubernetes import client, config, watch
from prometheus_client import Counter, Gauge, start_http_server

logging.basicConfig(level=logging.INFO, format='%(asctime)s [AGENT] %(message)s')
logger = logging.getLogger(__name__)

MODEL_NAME = os.getenv("SENTINEL_MODEL", "llama3")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")
DB_PATH = "/data/sentinel.db"

violations_total = Counter("sentinel_violations_total", "Kyverno and Cluster violations")

def init_db():
    logger.info(f"📦 Initializing DB at {DB_PATH}")
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute('''CREATE TABLE IF NOT EXISTS incidents (
        id INTEGER PRIMARY KEY, fingerprint TEXT UNIQUE, pod_name TEXT, namespace TEXT,
        severity TEXT, message TEXT, ai_analysis TEXT, occurrence_count INTEGER DEFAULT 1,
        created_at TEXT, updated_at TEXT)''')
    conn.commit(); conn.close()

def call_sre_ai(msg, context=""):
    system_prompt = (
        "You are an expert SRE specialized in Kubernetes troubleshooting (2025-2026 trends). "
        "Analyze the following error and provide: 1. Root Cause 2. Surgical Mitigation 3. Best Practice. "
        "Reference specific tools like eBPF for networking, VPA for memory issues, or preStop hooks for 504 errors. "
        f"Context from cluster: {context}"
    )
    
    try:
        logger.info(f"🤖 Analyzing Incident: {msg[:50]}...")
        r = requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL_NAME, 
            "prompt": f"{system_prompt}\n\nIncident: {msg}", 
            "stream": False
        }, timeout=300) 
        if r.status_code == 200:
            return r.json().get("response", "AI Empty")
        return f"AI Offline (HTTP {r.status_code})"
    except Exception as e: 
        logger.error(f"AI Error: {e}")
        return "AI Connection Error / Timeout"

def watch_events():
    logger.info("📡 Sentinel Watcher Active - Monitoring Workload Lifecycle, Networking, and Policies...")
    config.load_incluster_config()
    v1 = client.CoreV1Api()
    w = watch.Watch()
    
    critical_keywords = [
        "kyverno", "policy", "oomkilled", "crashloopbackoff", 
        "failedscheduling", "errimagepull", "backoff", "unhealthy"
    ]
    
    for event in w.stream(v1.list_event_for_all_namespaces):
        obj = event["object"]
        msg_text = (obj.message or "").lower()
        reason = (obj.reason or "").lower()
        
        if obj.type == "Warning" and any(k in msg_text or k in reason for k in critical_keywords):
            pod_name = obj.involved_object.name
            ns = obj.involved_object.namespace
            context = f"Reason: {obj.reason}, Object: {obj.involved_object.kind}"
            
            logger.info(f"🚨 INCIDENT DETECTED: [{obj.reason}] on {pod_name}")
            
            fp = hashlib.md5(f"{pod_name}:{obj.reason}:{obj.message}".encode()).hexdigest()
            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            
            conn = sqlite3.connect(DB_PATH)
            cur = conn.cursor()
            cur.execute("SELECT occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
            row = cur.fetchone()
            
            if row:
                cur.execute("UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?", (row[0]+1, now, fp))
            else:
                analysis = call_sre_ai(obj.message, context)
                cur.execute("INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?,?)",
                           (fp, pod_name, ns, obj.type, obj.message, analysis, 1, now, now))
            
            conn.commit(); conn.close()
            violations_total.inc()

if __name__ == "__main__":
    init_db()
    start_http_server(8000)
    while True:
        try:
            watch_events()
        except Exception as e:
            logger.error(f"Watcher crashed: {e}")
            time.sleep(5)
EOF

cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes requests prometheus_client
COPY agent.py /agent.py
CMD ["python", "-u", "/agent.py"]
EOF

# --- DASHBOARD ---
cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st, sqlite3, pandas as pd, os, time
st.set_page_config(layout="wide", page_title="Sentinel v9.0")
st.markdown("<h1 style='color:#00f2ff'>🛰️ Sentinel v9.0 Master Copy</h1>", unsafe_allow_html=True)

db = "/data/sentinel.db"

if os.path.exists(db):
    try:
        conn = sqlite3.connect(db)
        df = pd.read_sql("SELECT occurrence_count, namespace, pod_name, message, ai_analysis, updated_at FROM incidents ORDER BY updated_at DESC", conn)
        conn.close()
        
        if not df.empty:
            st.metric("Total Resolved/Analyzed Incidents", len(df))
            st.table(df)
            if st.button('Refresh Data'):
                st.rerun()
        else:
            st.info("🎯 Monitoring active. No critical cluster events detected yet.")
    except Exception as e:
        st.error(f"Error reading DB: {e}")
else:
    st.warning(f"🔄 Database not found. Ensure /home/sentinel-data is writable.")

time.sleep(10)
st.rerun()
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit pandas
COPY app.py /app.py
CMD ["streamlit", "run", "/app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

echo "🔨 Building Master Images..."
# Pointing both components to the verified 'cicd' repository with unique tags
sudo docker build -t $DOCKER_USER/$DOCKER_REPO:agent-$VERSION "$PROJECT_ROOT/agent"
sudo docker build -t $DOCKER_USER/$DOCKER_REPO:dashboard-$VERSION "$PROJECT_ROOT/app"

echo "🚀 Pushing to Docker Hub: $DOCKER_USER/$DOCKER_REPO..."
sudo docker push $DOCKER_USER/$DOCKER_REPO:agent-$VERSION
sudo docker push $DOCKER_USER/$DOCKER_REPO:dashboard-$VERSION

############################################
# 3. NATIVE MONITORING
############################################
echo "📊 Preparing Native Monitoring Manifests..."
cat <<'EOF' > "$PROJECT_ROOT/k8s/monitoring.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: sentinel
data:
  prometheus.yml: |
    global:
      scrape_interval: 5s
    scrape_configs:
      - job_name: 'sentinel-agent'
        static_configs:
          - targets: ['sentinel-agent:8000']
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: sentinel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
        team: sentinel-ops
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        args: ["--config.file=/etc/prometheus/prometheus.yml"]
        resources:
          limits: { cpu: "500m", memory: "512Mi" }
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
      volumes:
      - name: config
        configMap:
          name: prometheus-config
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: sentinel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
        team: sentinel-ops
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        resources:
          limits: { cpu: "500m", memory: "512Mi" }
        ports:
        - containerPort: 3000
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: sentinel
spec:
  selector: { app: prometheus }
  ports: [{ port: 9090, nodePort: 30090 }]
  type: NodePort
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: sentinel
spec:
  selector: { app: grafana }
  ports: [{ port: 3000, nodePort: 30300 }]
  type: NodePort
EOF

############################################
# 4. FINAL DEPLOYMENT (USING DOCKER HUB IMAGES)
############################################
cat <<EOF > "$PROJECT_ROOT/k8s/sentinel-main.yaml"
apiVersion: v1
kind: Namespace
metadata:
  name: sentinel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sentinel-agent-sa
  namespace: sentinel
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sentinel-event-watcher-v90
rules:
- apiGroups: [""]
  resources: ["events", "pods", "services", "nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sentinel-agent-rbac-v90
subjects:
- kind: ServiceAccount
  name: sentinel-agent-sa
  namespace: sentinel
roleRef:
  kind: ClusterRole
  name: sentinel-event-watcher-v90
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sentinel-agent
  namespace: sentinel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sentinel-agent
  template:
    metadata:
      labels:
        app: sentinel-agent
        team: sentinel-ops
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: sentinel-agent-sa
      containers:
      - name: agent
        image: $DOCKER_USER/$DOCKER_REPO:agent-$VERSION
        imagePullPolicy: Always
        env:
        - name: SENTINEL_MODEL
          value: "$MODEL_NAME"
        - name: OLLAMA_URL
          value: "http://127.0.0.1:11434"
        volumeMounts:
        - name: data-vol
          mountPath: /data
      volumes:
      - name: data-vol
        hostPath:
          path: /home/sentinel-data
          type: Directory
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
      app: dashboard
  template:
    metadata:
      labels:
        app: dashboard
        team: sentinel-ops
    spec:
      containers:
      - name: dashboard
        image: $DOCKER_USER/$DOCKER_REPO:dashboard-$VERSION
        imagePullPolicy: Always
        ports:
        - containerPort: 8501
        volumeMounts:
        - name: data-vol
          mountPath: /data
      volumes:
      - name: data-vol
        hostPath:
          path: /home/sentinel-data
          type: Directory
---
apiVersion: v1
kind: Service
metadata:
  name: sentinel-dashboard
  namespace: sentinel
spec:
  type: NodePort
  selector: { app: dashboard }
  ports: [{ port: 8501, nodePort: 30501 }]
EOF

echo "🚀 Applying All Manifests..."
kubectl apply -f "$PROJECT_ROOT/k8s/sentinel-main.yaml"
kubectl apply -f "$PROJECT_ROOT/k8s/monitoring.yaml"

echo "⏳ Waiting for pods..."
sleep 15
kubectl get pods -n sentinel

echo "✅ Sentinel v9.0 Master Copy Deployed!"
echo "Dashboard:  http://$VM_IP:30501"
echo "Prometheus: http://$VM_IP:30090"
echo "Grafana:    http://$VM_IP:30300"
echo "------------------------------------------------"
echo ">>> TEST 1 (Policy): kubectl run bad-pod --image=nginx"
echo ">>> TEST 2 (OOM): kubectl run oom-pod --image=polinux/stress --restart=Never -- /usr/local/bin/stress --vm 1 --vm-bytes 2G"
echo ">>> TEST 3 (Image): kubectl run bad-img --image=nginx:doesnotexist"
