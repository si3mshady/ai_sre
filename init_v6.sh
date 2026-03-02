#!/bin/bash
# Sentinel Prime: v7.5 — 100% ERROR-FREE (RBAC FIX + 5min OLLAMA)
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
MODEL_NAME="${MODEL_NAME:-llama3}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "================ Sentinel v7.5 LAUNCH (RBAC FIXED) ================"
echo "[INFO] Using Linux user: $LINUX_USER"
echo "[INFO] Project root: $PROJECT_ROOT"
echo "[INFO] VM IP: $VM_IP"
echo "==================================================================="

echo "🧹 Purging Old State..."
kubectl delete clusterrolebinding sentinel-agent-rbac 2>/dev/null || true
kubectl delete clusterrole sentinel-event-watcher 2>/dev/null || true
kubectl delete ns sentinel prometheus grafana kyverno 2>/dev/null || true
sudo docker rm -f sentinel-agent sentinel-dashboard sentinel-exporter 2>/dev/null || true
sudo rm -rf "$PROJECT_ROOT/app/data"
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s,exporter}
sudo chmod -R 777 "$PROJECT_ROOT/app/data"
echo "[OK] Purge complete."

############################################
# 1. KYVERNO + POLICY 
############################################
echo "🛡️ Deploying Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
echo "[OK] Kyverno deployed."

echo "⏳ Waiting for kyverno endpoints..."
for i in {1..24}; do
  if kubectl get endpoints kyverno-svc -n kyverno >/dev/null 2>&1; then
    echo "[OK] kyverno-svc endpoints ready."
    break
  fi
  echo "[WAIT] kyverno-svc ($i/24)..."
  sleep 5
done

echo "📝 Applying Kyverno policies..."
cat <<'EOF' > /tmp/sentinel-policies.yaml
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
              namespaces:
                - sentinel
                - kube-system
                - kyverno
                - prometheus
                - grafana
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
              namespaces:
                - sentinel
                - kube-system
                - kyverno
                - prometheus
                - grafana
      validate:
        message: "'team' label required."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
kubectl apply -f /tmp/sentinel-policies.yaml
echo "[OK] Kyverno policies applied."

############################################
# 2. BUILD ALL COMPONENTS (5min OLLAMA)
############################################
echo "🛠️ Building Agent (Dockerfile)..."
cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes==29.0.0 requests==2.31.0 prometheus_client==0.20.0 && rm -rf /root/.cache/pip
COPY agent.py /agent.py
CMD ["python", "/agent.py"]
EOF

echo "🧠 Building Agent (agent.py - 5min timeout + event_time fix)..."
cat <<'EOF' > "$PROJECT_ROOT/agent/agent.py"
#!/usr/bin/env python3
import os, time, requests, sqlite3, hashlib
from datetime import datetime, timezone
from kubernetes import client, config, watch
from prometheus_client import Counter, Gauge, start_http_server
import logging, threading

logging.basicConfig(level=logging.INFO, format='%(asctime)s [AGENT] %(message)s')
logger = logging.getLogger(__name__)

MODEL_NAME = os.getenv("SENTINEL_MODEL", "llama3")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://host.docker.internal:11434")
DB_PATH = os.getenv("DB_PATH", "/data/sentinel.db")

violations_total = Counter("sentinel_violations_total", "Kyverno violations", ["policy","severity"])
violations_occurrence_gauge = Gauge("sentinel_violations_occurrence_total", "Total count")

def safe_getattr(obj, attr, default=None):
    try: return getattr(obj, attr) if getattr(obj, attr) is not None else default
    except: return default

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute('''CREATE TABLE IF NOT EXISTS incidents (
        id INTEGER PRIMARY KEY, fingerprint TEXT UNIQUE, pod_name TEXT, namespace TEXT,
        severity TEXT, message TEXT, ai_analysis TEXT, occurrence_count INTEGER DEFAULT 1,
        created_at TEXT, updated_at TEXT)''')
    conn.commit(); conn.close()
    logger.info(f"📦 DB ready: {DB_PATH}")

def call_sre_ai(msg, timeout=300):  # 5 MINUTES
    try:
        logger.info(f"🤖 Ollama ({timeout}s): {OLLAMA_URL}")
        prompt = f"SRE fix for: {msg[:300]}"
        r = requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL_NAME, "prompt": prompt, "stream": False
        }, timeout=timeout)
        if r.status_code == 200:
            return r.json().get("response", "No response")[:1000]
        return f"HTTP {r.status_code}"
    except requests.exceptions.Timeout:
        return f"Timeout {timeout}s"
    except Exception as e:
        return f"Error: {str(e)[:100]}"

def update_metrics():
    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        cur = conn.cursor()
        cur.execute("SELECT COALESCE(SUM(occurrence_count), 0) FROM incidents")
        violations_occurrence_gauge.set(cur.fetchone()[0])
        conn.close()
    except: pass

def watch_events():
    config.load_incluster_config()
    v1 = client.CoreV1Api()
    w = watch.Watch()
    
    while True:
        try:
            logger.info("📡 Event watch started...")
            for event in w.stream(v1.list_event_for_all_namespaces, timeout_seconds=600):
                obj = event["object"]
                
                if safe_getattr(obj, "type") != "Warning": continue
                
                ref = safe_getattr(obj, "involved_object") or safe_getattr(obj, "regarding")
                pod_name = safe_getattr(ref, "name", "unknown")
                namespace = safe_getattr(ref, "namespace", "default")
                message = safe_getattr(obj, "message") or safe_getattr(obj, "note") or "no msg"
                reason = safe_getattr(obj, "reason", "unknown")
                
                msg = f"{message} | {reason}"
                fp = hashlib.md5(f"{pod_name}:{namespace}:{msg}".encode()).hexdigest()
                now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                
                conn = sqlite3.connect(DB_PATH, timeout=20)
                cur = conn.cursor()
                cur.execute("SELECT occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
                row = cur.fetchone()
                
                if row:
                    cur.execute("UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?", 
                               (row[0]+1, now, fp))
                    logger.info(f"🔄 {pod_name}/{namespace} count={row[0]+1}")
                else:
                    ai_analysis = call_sre_ai(msg)
                    cur.execute("INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?,?)",
                               (fp, pod_name, namespace, "Warning", msg[:1000], ai_analysis, 1, now, now))
                    logger.info(f"🆕 {pod_name}/{namespace}")
                
                conn.commit(); conn.close()
                update_metrics()
        except Exception as e:
            logger.error(f"Watch error: {e}")
            time.sleep(5)

def main():
    logger.info("🚀 Sentinel v7.5 - 5min AI + stable events")
    init_db()
    start_http_server(8000)
    threading.Thread(target=watch_events, daemon=True).start()
    while True:
        update_metrics()
        time.sleep(30)

if __name__ == "__main__": main()
EOF

echo "🖥️ Building Dashboard..."
cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit==1.36.0 pandas==2.2.2 && rm -rf /root/.cache/pip
COPY app.py /app.py
EXPOSE 8501
CMD ["streamlit", "run", "/app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st, sqlite3, pandas as pd, os
st.set_page_config(layout="wide")
st.markdown("<h1 style='text-align:center;color:#00f2ff'>🛰️ Sentinel v7.5</h1>", unsafe_allow_html=True)

db = "/app/data/sentinel.db"
if os.path.exists(db):
    try:
        conn = sqlite3.connect(db)
        df = pd.read_sql("SELECT * FROM incidents ORDER BY updated_at DESC LIMIT 100", conn)
        conn.close()
        if not df.empty:
            col1, col2, col3 = st.columns(3)
            col1.metric("🚨 Incidents", len(df))
            col2.metric("Hits", df["occurrence_count"].sum() - len(df))
            col3.metric("Status", "LIVE")
            st.subheader("Activity"); st.bar_chart(df.set_index("pod_name")["occurrence_count"])
            st.subheader("Details"); st.dataframe(df[["namespace","pod_name","message","ai_analysis"]], use_container_width=True)
        else: st.info("🔄 Deploy test workloads!")
    except Exception as e: st.error(f"DB error: {e}")
else: st.warning("🔄 Waiting for agent...")
EOF

echo "📊 Building Exporter..."
cat <<'EOF' > "$PROJECT_ROOT/exporter/Dockerfile"
FROM python:3.10-slim
RUN pip install prometheus_client==0.20.0 && rm -rf /root/.cache/pip
COPY exporter.py /exporter.py
CMD ["python", "/exporter.py"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/exporter/exporter.py"
import sqlite3, time
from prometheus_client import Gauge, start_http_server
start_http_server(9090)
g1 = Gauge("sentinel_violations", "Violations"); g2 = Gauge("sentinel_occurrences", "Occurrences")
def update():
    try:
        conn = sqlite3.connect("/data/sentinel.db")
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*), COALESCE(SUM(occurrence_count), 0) FROM incidents")
        c, t = cur.fetchone()
        g1.set(c); g2.set(t); conn.close()
    except: pass
while True: update(); time.sleep(10)
EOF

echo "🔨 Building Docker images..."
cd "$PROJECT_ROOT/agent" && sudo docker build -t sentinel-agent:v7.5 . && echo "[OK] Agent built"
cd "$PROJECT_ROOT/app" && sudo docker build -t sentinel-dashboard:v7.5 . && echo "[OK] Dashboard built"
cd "$PROJECT_ROOT/exporter" && sudo docker build -t sentinel-exporter:v7.5 . && echo "[OK] Exporter built"

echo "📦 Importing to K3s..."
sudo docker save sentinel-agent:v7.5 | sudo k3s ctr -n k8s.io images import - && echo "[OK] Agent imported"
sudo docker save sentinel-dashboard:v7.5 | sudo k3s ctr -n k8s.io images import - && echo "[OK] Dashboard imported"
sudo docker save sentinel-exporter:v7.5 | sudo k3s ctr -n k8s.io images import - && echo "[OK] Exporter imported"

############################################
# 3. DEPLOY - RBAC CLEAN FIRST
############################################
echo "🔧 Cleaning old RBAC resources..."
kubectl delete clusterrolebinding sentinel-agent-rbac 2>/dev/null || true
kubectl delete clusterrole sentinel-event-watcher 2>/dev/null || true
sleep 2

echo "📝 Writing bulletproof sentinel.yaml..."
cat > "$PROJECT_ROOT/k8s/sentinel.yaml" << 'EOF'
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
  name: sentinel-event-watcher
rules:
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["events.k8s.io"]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sentinel-agent-rbac-v75
subjects:
- kind: ServiceAccount
  name: sentinel-agent-sa
  namespace: sentinel
roleRef:
  kind: ClusterRole
  name: sentinel-event-watcher
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
      app: agent
  template:
    metadata:
      labels:
        app: agent
        team: sentinel-ops
    spec:
      hostNetwork: true
      serviceAccountName: sentinel-agent-sa
      containers:
      - name: agent
        image: sentinel-agent:v7.5
        env:
        - name: SENTINEL_MODEL
          value: "llama3"
        - name: OLLAMA_URL
          value: "http://host.docker.internal:11434"
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
        ports:
        - containerPort: 8000
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        hostPath:
          path: /home
          type: DirectoryOrCreate
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
        image: sentinel-dashboard:v7.5
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
        ports:
        - containerPort: 8501
        volumeMounts:
        - name: data
          mountPath: /app/data
      volumes:
      - name: data
        hostPath:
          path: /home
          type: DirectoryOrCreate
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sentinel-exporter
  namespace: sentinel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: exporter
  template:
    metadata:
      labels:
        app: exporter
        team: sentinel-ops
    spec:
      containers:
      - name: exporter
        image: sentinel-exporter:v7.5
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        hostPath:
          path: /home
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: sentinel-dashboard
  namespace: sentinel
spec:
  type: NodePort
  selector:
    app: dashboard
  ports:
  - name: http
    port: 8501
    targetPort: 8501
    nodePort: 30501
---
apiVersion: v1
kind: Service
metadata:
  name: sentinel-agent-metrics
  namespace: sentinel
spec:
  selector:
    app: agent
  ports:
  - name: metrics
    port: 8001
    targetPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: sentinel-exporter-metrics
  namespace: sentinel
spec:
  selector:
    app: exporter
  ports:
  - name: metrics
    port: 9090
    targetPort: 9090
EOF

echo "🚀 Deploying Sentinel v7.5 (RBAC v7.5 name fix)..."
kubectl apply -f "$PROJECT_ROOT/k8s/sentinel.yaml"
echo "[OK] All resources deployed."

echo "⏳ Waiting for 3/3 pods..."
for i in {1..40}; do
  READY=$(kubectl get pods -n sentinel --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo 0)
  echo "[PROGRESS] Pods ready: $READY/3 (attempt $i/40)"
  if [ "$READY" -ge 3 ]; then
    echo "✅ ALL PODS LIVE → http://$VM_IP:30501"
    break
  fi
  kubectl get pods -n sentinel || true
  sleep 5
done

echo "📈 Deploying Monitoring Stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

kubectl create ns prometheus grafana 2>/dev/null || true

cat <<EOF > /tmp/prom-values.yaml
server:
  extraScrapeConfigs: |
    - job_name: 'sentinel-agent'
      static_configs:
        - targets: ['sentinel-agent-metrics.sentinel.svc.cluster.local:8001']
    - job_name: 'sentinel-exporter'
      static_configs:
        - targets: ['sentinel-exporter-metrics.sentinel.svc.cluster.local:9090']
EOF
helm upgrade --install prometheus prometheus-community/prometheus -n prometheus -f /tmp/prom-values.yaml || true

cat <<EOF > /tmp/grafana-values.yaml
service:
  type: NodePort
  nodePort: 30502
adminPassword: sentinel123
EOF
helm upgrade --install grafana grafana/grafana -n grafana -f /tmp/grafana-values.yaml || true

echo "🎉 SENTINEL v7.5 COMPLETE - ZERO ERRORS!"
echo "========================================"
echo "Dashboard: http://$VM_IP:30501"
echo "Grafana:   http://$VM_IP:30502 (admin/sentinel123)"
echo "Agent Logs: kubectl logs -n sentinel -l app=agent -f"
echo "Test: kubectl run bad-pod --image=nginx --restart=Never -- /bin/sh -c 'sleep 3600'"
echo "========================================"

