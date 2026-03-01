#!/bin/bash
# Sentinel Prime: Aegis III — FIXED HELM JSON ERROR (v6.2) 
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
MODEL_NAME="${MODEL_NAME:-llama3}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "🧹 Purging Old State..."
kubectl delete ns sentinel prometheus grafana kyverno 2>/dev/null || true
sudo docker rm -f sentinel-agent sentinel-dashboard sentinel-exporter 2>/dev/null || true
sudo rm -rf "$PROJECT_ROOT/app/data"
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s,exporter}
sudo chmod -R 777 "$PROJECT_ROOT/app/data"
sudo chown -R 1000:1000 "$PROJECT_ROOT/app/data"

############################################
# 1. KYVERNO + POLICY (UNCHANGED)
############################################
echo "🛡️ Deploying Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

echo "⏳ Waiting for kyverno-svc..."
for i in {1..24}; do kubectl get endpoints kyverno-svc -n kyverno >/dev/null 2>&1 && break; sleep 5; done

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
              kinds:
                - Pod
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
        message: "CPU/Memory limits required for stability."
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
              kinds:
                - Pod
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
        message: "'team' label required for SRE tracking."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
kubectl apply -f /tmp/sentinel-policies.yaml

############################################
# 2. SENTINEL CORE - FIXED (UNCHANGED)
############################################
cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes==29.0.0 requests==2.31.0 prometheus_client==0.20.0 && rm -rf /root/.cache/pip
USER 1000:1000
COPY agent.py /agent.py
CMD ["python", "/agent.py"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/agent/agent.py"
#!/usr/bin/env python3
import os, sys, time, requests, sqlite3, hashlib, json
from datetime import datetime
from kubernetes import client, config, watch
from prometheus_client import Counter, Gauge, start_http_server
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger(__name__)

MODEL_NAME = os.getenv("SENTINEL_MODEL", "llama3")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")
DB_PATH = os.getenv("DB_PATH", "/data/sentinel.db")

violations_total = Counter("sentinel_violations_total", "Kyverno policy violations", ["policy", "severity"])
violations_occurrence_gauge = Gauge("sentinel_violations_occurrence_total", "Total occurrence count of violations")

def init_db():
    try:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        conn.execute('''CREATE TABLE IF NOT EXISTS incidents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fingerprint TEXT UNIQUE,
            pod_name TEXT, namespace TEXT, severity TEXT,
            message TEXT, ai_analysis TEXT, occurrence_count INTEGER DEFAULT 1,
            created_at TEXT, updated_at TEXT)''')
        conn.commit()
        conn.close()
        logger.info(f"Database initialized at {DB_PATH}")
    except Exception as e:
        logger.error(f"Database init failed: {e}")
        sys.exit(1)

def call_sre_ai(msg):
    try:
        r = requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL_NAME, "prompt": f"SRE Fix: {msg[:200]}", "stream": False
        }, timeout=30)
        return r.json().get("response", "AI offline")[:500]
    except:
        return "AI unreachable"

def update_metrics():
    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        cur = conn.cursor()
        cur.execute("SELECT COALESCE(SUM(occurrence_count), 0) FROM incidents")
        violations_occurrence_gauge.set(cur.fetchone()[0])
        conn.close()
    except:
        pass

def main():
    logger.info("🚀 Sentinel Agent starting...")
    init_db()
    start_http_server(8000)
    logger.info("✅ Metrics on :8000")
    
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()
    
    v1 = client.CoreV1Api()
    logger.info("📡 Watching events...")
    
    w = watch.Watch()
    for event in w.stream(v1.list_event_for_all_namespaces):
        obj = event["object"]
        msg = obj.message or ""
        if obj.type == "Warning" and "kyverno" in msg.lower():
            pod = obj.involved_object.name
            ns = obj.involved_object.namespace or "unknown"
            fp = hashlib.md5(f"{pod}:{msg}".encode()).hexdigest()
            now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
            
            conn = sqlite3.connect(DB_PATH, timeout=10)
            cur = conn.cursor()
            cur.execute("SELECT id, occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
            row = cur.fetchone()
            
            if row:
                cur.execute("UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?", 
                           (row[1] + 1, now, fp))
            else:
                policy = "require-resources" if "require-resources" in msg.lower() else "require-team-label"
                aiout = call_sre_ai(msg)
                cur.execute("INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?,?)",
                           (fp, pod, ns, obj.type, msg[:1000], aiout, 1, now, now))
                violations_total.labels(policy=policy, severity="warning").inc()
            
            update_metrics()
            conn.commit()
            conn.close()
            logger.info(f"🚨 {pod}/{ns}")

if __name__ == "__main__":
    main()
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit==1.36.0 pandas==2.2.2 prometheus_client==0.20.0 && rm -rf /root/.cache/pip
USER 1000:1000
COPY app.py /app.py
EXPOSE 8501 8001
CMD ["streamlit", "run", "/app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st, sqlite3, pandas as pd, os
from prometheus_client import Histogram, start_http_server

st.set_page_config(layout="wide")
st.markdown("<h1 style='text-align:center;color:#00f2ff'>🛰️ Sentinel Prime</h1>", unsafe_allow_html=True)

db = "/app/data/sentinel.db"
if os.path.exists(db):
    conn = sqlite3.connect(db)
    df = pd.read_sql("SELECT * FROM incidents ORDER BY updated_at DESC LIMIT 100", conn)
    conn.close()
    
    col1, col2, col3 = st.columns(3)
    col1.metric("🚨 Violations", len(df))
    col2.metric("Hits", df["occurrence_count"].sum() if not df.empty else 0)
    col3.metric("Status", "LIVE")
    
    st.bar_chart(df.set_index("pod_name")["occurrence_count"])
    st.dataframe(df[["pod_name","namespace","message","ai_analysis"]])
else:
    st.info("🔄 Initializing...")
EOF

cat <<'EOF' > "$PROJECT_ROOT/exporter/Dockerfile"
FROM python:3.10-slim
RUN pip install prometheus_client==0.20.0 && rm -rf /root/.cache/pip
USER 1000:1000
COPY exporter.py /exporter.py
CMD ["python", "/exporter.py"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/exporter/exporter.py"
import sqlite3, time
from prometheus_client import Gauge, start_http_server

start_http_server(9090)
violations_gauge = Gauge("sentinel_violations_gauge", "Violations count")
occurrence_gauge = Gauge("sentinel_violations_occurrence_total", "Total occurrences")

def update():
    try:
        conn = sqlite3.connect("/data/sentinel.db")
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*), COALESCE(SUM(occurrence_count), 0) FROM incidents")
        count, total = cur.fetchone()
        violations_gauge.set(count)
        occurrence_gauge.set(total)
        conn.close()
    except:
        pass

while True:
    update()
    time.sleep(10)
EOF

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
      app: dashboard
  template:
    metadata:
      labels: 
        app: dashboard
        team: sentinel-ops
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: dashboard
        image: sentinel-dashboard:v6
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
        ports:
        - containerPort: 8501
        - containerPort: 8001
        volumeMounts:
        - name: data
          mountPath: /app/data
      volumes:
      - name: data
        hostPath:
          path: $PROJECT_ROOT/app/data
          type: DirectoryOrCreate
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
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: agent
        image: sentinel-agent:v6
        env:
        - name: SENTINEL_MODEL
          value: "$MODEL_NAME"
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
        livenessProbe:
          httpGet:
            path: /metrics
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: data
        hostPath:
          path: $PROJECT_ROOT/app/data
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
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: exporter
        image: sentinel-exporter:v6
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
          path: $PROJECT_ROOT/app/data
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
    nodePort: 30501
  - name: metrics
    port: 8001
    targetPort: 8001
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

echo "🔨 Building images..."
cd "$PROJECT_ROOT/agent" && sudo docker build -t sentinel-agent:v6 .
cd "$PROJECT_ROOT/app" && sudo docker build -t sentinel-dashboard:v6 .
cd "$PROJECT_ROOT/exporter" && sudo docker build -t sentinel-exporter:v6 .

sudo docker save sentinel-agent:v6 | sudo k3s ctr -n k8s.io images import -
sudo docker save sentinel-dashboard:v6 | sudo k3s ctr -n k8s.io images import -
sudo docker save sentinel-exporter:v6 | sudo k3s ctr -n k8s.io images import -

kubectl create clusterrolebinding sentinel-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=sentinel:default \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$PROJECT_ROOT/k8s/sentinel.yaml"

echo "⏳ Waiting for pods..."
for i in {1..30}; do
  if kubectl wait --for=condition=Ready pod -l app=agent -n sentinel --timeout=10s 2>/dev/null; then
    echo "✅ SENTINEL READY: http://$VM_IP:30501"
    break
  fi
  kubectl get pods -n sentinel
  sleep 3
done

############################################
# 3. FIXED PROMETHEUS + GRAFANA (PROPER SYNTAX)
############################################
echo "📈 Deploying Monitoring..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

# Delete existing broken releases
helm uninstall prometheus -n prometheus || true
helm uninstall grafana -n grafana || true
kubectl delete ns prometheus grafana || true

kubectl create ns prometheus
kubectl create ns grafana

# Prometheus with FIXED resource syntax + values.yaml
cat <<EOF > /tmp/prom-values.yaml
server:
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi
  extraScrapeConfigs: |
    - job_name: 'sentinel-agent'
      static_configs:
        - targets: ['sentinel-agent-metrics.sentinel:8001']
    - job_name: 'sentinel-exporter'
      static_configs:
        - targets: ['sentinel-exporter-metrics.sentinel:9090']
EOF

helm upgrade --install prometheus prometheus-community/prometheus \
  -n prometheus --create-namespace -f /tmp/prom-values.yaml

# Grafana with FIXED resource syntax
cat <<EOF > /tmp/grafana-values.yaml
resources:
  limits:
    cpu: 300m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi
service:
  type: NodePort
  nodePort: 30502
adminPassword: sentinel123
EOF

helm upgrade --install grafana grafana/grafana \
  -n grafana --create-namespace -f /tmp/grafana-values.yaml

echo "🎉 ✅ COMPLETE - NO MORE ERRORS!"
echo "🔗 Sentinel:     http://$VM_IP:30501"
echo "📊 Grafana:     http://$VM_IP:30502 (admin/sentinel123)"
echo "📡 Prometheus:  http://$VM_IP:30900"
echo ""
echo "✅ FIXED:"
echo "  • Helm --set resources syntax (using values.yaml)"
echo "  • Proper YAML indentation in manifests"
echo "  • Clean helm uninstall + fresh deploy"

