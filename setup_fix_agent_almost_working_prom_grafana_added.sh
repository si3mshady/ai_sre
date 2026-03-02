#!/bin/bash
# Sentinel Prime: v8.0 — THE GOLDEN COPY (REVISION 1)
# ENHANCEMENTS: Fixed Volume Paths, Permissions, and 5-Min AI Timeout
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
MODEL_NAME="${MODEL_NAME:-llama3}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "================ Sentinel v8.0 — THE GOLDEN COPY =============="
echo "[INFO] Using Linux user: $LINUX_USER"
echo "[INFO] Project root: $PROJECT_ROOT"
echo "================================================================"

echo "🧹 Purging Old State..."
kubectl delete ns sentinel 2>/dev/null || true
kubectl delete clusterrolebinding sentinel-agent-rbac-v80 2>/dev/null || true
# Deep clean host data to prevent locked SQLite DBs
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
        message: "CPU/Memory limits required."
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
        message: "'team' label required."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
kubectl apply -f "$PROJECT_ROOT/k8s/policies.yaml"

############################################
# 2. BUILD COMPONENT IMAGES
############################################
# --- AGENT (5 MIN TIMEOUT) ---
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

violations_total = Counter("sentinel_violations_total", "Kyverno violations")

def init_db():
    logger.info(f"📦 Initializing DB at {DB_PATH}")
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute('''CREATE TABLE IF NOT EXISTS incidents (
        id INTEGER PRIMARY KEY, fingerprint TEXT UNIQUE, pod_name TEXT, namespace TEXT,
        severity TEXT, message TEXT, ai_analysis TEXT, occurrence_count INTEGER DEFAULT 1,
        created_at TEXT, updated_at TEXT)''')
    conn.commit(); conn.close()

def call_sre_ai(msg):
    try:
        # TIMEOUT UPDATED TO 300s (5 MINS)
        logger.info(f"🤖 Calling AI for: {msg[:50]}...")
        r = requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL_NAME, "prompt": f"Fix Kyverno violation: {msg}", "stream": False
        }, timeout=300) 
        if r.status_code == 200:
            logger.info("✅ AI Response received.")
            return r.json().get("response", "AI Empty")
        return f"AI Offline (HTTP {r.status_code})"
    except Exception as e: 
        logger.error(f"AI Error: {e}")
        return "AI Connection Error / Timeout"

def watch_events():
    logger.info("📡 Sentinel Watcher Started - Monitoring Cluster Events...")
    config.load_incluster_config()
    v1 = client.CoreV1Api()
    w = watch.Watch()
    
    for event in w.stream(v1.list_event_for_all_namespaces):
        obj = event["object"]
        msg_text = (obj.message or "").lower()
        
        if obj.type == "Warning" and ("kyverno" in msg_text or "policy" in msg_text):
            pod_name = obj.involved_object.name
            ns = obj.involved_object.namespace
            logger.info(f"🚨 VIOLATION DETECTED: {pod_name} in {ns}")
            
            fp = hashlib.md5(f"{pod_name}:{obj.message}".encode()).hexdigest()
            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            
            conn = sqlite3.connect(DB_PATH)
            cur = conn.cursor()
            cur.execute("SELECT occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
            row = cur.fetchone()
            
            if row:
                logger.info(f"🔄 Incrementing count for {pod_name}")
                cur.execute("UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?", (row[0]+1, now, fp))
            else:
                logger.info(f"🆕 New Incident. Requesting AI Remediation...")
                analysis = call_sre_ai(obj.message)
                cur.execute("INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?,?)",
                           (fp, pod_name, ns, "Warning", obj.message, analysis, 1, now, now))
            
            conn.commit(); conn.close()
            violations_total.inc()

if __name__ == "__main__":
    init_db()
    start_http_server(8000)
    while True:
        try:
            watch_events()
        except Exception as e:
            logger.error(f"Watcher crashed, restarting in 5s: {e}")
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
st.set_page_config(layout="wide", page_title="Sentinel v8.0")
st.markdown("<h1 style='color:#00f2ff'>🛰️ Sentinel v8.0 Golden Copy</h1>", unsafe_allow_html=True)

db = "/data/sentinel.db"

if os.path.exists(db):
    try:
        conn = sqlite3.connect(db)
        df = pd.read_sql("SELECT namespace, pod_name, message, ai_analysis, occurrence_count, updated_at FROM incidents ORDER BY updated_at DESC", conn)
        conn.close()
        
        if not df.empty:
            st.metric("Total Kyverno Incidents", len(df))
            st.dataframe(df, use_container_width=True)
            if st.button('Clear Dashboard Cache'):
                st.rerun()
        else:
            st.info("🎯 Database is empty. Waiting for Kyverno violations...")
    except Exception as e:
        st.error(f"Error reading DB: {e}")
else:
    st.warning(f"🔄 Database file not found at {db}. Check volume mounts.")

time.sleep(5)
st.rerun()
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit pandas
COPY app.py /app.py
CMD ["streamlit", "run", "/app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

echo "🔨 Building & Importing Images..."
cd "$PROJECT_ROOT/agent" && sudo docker build -t localhost/sentinel-agent:v8.0 .
cd "$PROJECT_ROOT/app" && sudo docker build -t localhost/sentinel-dashboard:v8.0 .
sudo docker save localhost/sentinel-agent:v8.0 | sudo k3s ctr -n k8s.io images import -
sudo docker save localhost/sentinel-dashboard:v8.0 | sudo k3s ctr -n k8s.io images import -

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
          requests: { cpu: "200m", memory: "256Mi" }
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
          requests: { cpu: "200m", memory: "256Mi" }
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
# 4. FINAL DEPLOYMENT (FIXED VOLUMES)
############################################
cat <<'EOF' > "$PROJECT_ROOT/k8s/sentinel-main.yaml"
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
  name: sentinel-event-watcher-v80
rules:
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sentinel-agent-rbac-v80
subjects:
- kind: ServiceAccount
  name: sentinel-agent-sa
  namespace: sentinel
roleRef:
  kind: ClusterRole
  name: sentinel-event-watcher-v80
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
        image: localhost/sentinel-agent:v8.0
        env:
        - name: SENTINEL_MODEL
          value: "llama3"
        - name: OLLAMA_URL
          value: "http://127.0.0.1:11434"
        resources:
          limits: { cpu: "500m", memory: "512Mi" }
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
  name: sentinel-agent
  namespace: sentinel
spec:
  selector: { app: sentinel-agent }
  ports: [{ port: 8000 }]
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
        image: localhost/sentinel-dashboard:v8.0
        resources:
          limits: { cpu: "500m", memory: "512Mi" }
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
sleep 10
kubectl get pods -n sentinel

echo "✅ Sentinel v8.0 Golden Copy Deployed!"
echo "Dashboard:  http://$VM_IP:30501"
echo "Prometheus: http://$VM_IP:30090"
echo "Grafana:    http://$VM_IP:30300"
echo "------------------------------------------------"
echo "TEST: kubectl run bad-pod --image=nginx"
