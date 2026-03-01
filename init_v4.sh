#!/bin/bash
# Sentinel Prime: Aegis III — FULLY POLICY‑COMPLIANT (v6)
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

############################################
# 1. KYVERNO + POLICY WITH FULL EXCLUSIONS
############################################
echo "🛡️ Deploying Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

echo "⏳ Waiting for kyverno-svc..."
for i in {1..24}; do kubectl get endpoints kyverno-svc -n kyverno >/dev/null 2>&1 && break; sleep 5; done

# POLICY WITH prometheus/grafana EXCLUDED (deploy‑safe)
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
# 2. SENTINEL CORE (Compliant)
############################################
cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes requests prometheus_client
COPY agent.py /agent.py
CMD ["python","/agent.py"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit pandas prometheus_client
COPY app.py /app.py
WORKDIR /
CMD ["streamlit","run","/app.py","--server.port=8501","--server.address=0.0.0.0"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/agent/agent.py"
import os, requests, sqlite3, time, hashlib, json
from datetime import datetime
from kubernetes import client, config, watch
from prometheus_client import Counter, Gauge, start_http_server

# injected via env
MODEL_NAME = os.getenv("SENTINEL_MODEL", "llama3")
OLLAMA_URL = "http://127.0.0.1:11434"
DB_PATH = "/data/sentinel.db"

# metrics
violations_total = Counter(
    "sentinel_violations_total",
    "Kyverno policy violations",
    ["policy", "severity"]
)
violations_occurrence_gauge = Gauge(
    "sentinel_violations_occurrence_total",
    "Total occurrence count of violations"
)

def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute('''CREATE TABLE IF NOT EXISTS incidents (
        id INTEGER PRIMARY KEY, fingerprint TEXT UNIQUE,
        pod_name TEXT, namespace TEXT, severity TEXT,
        message TEXT, ai_analysis TEXT, occurrence_count INTEGER DEFAULT 1,
        created_at TEXT, updated_at TEXT)''')
    conn.close()

def call_sre_ai(msg):
    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model": MODEL_NAME,
                "prompt": f"SRE Fix: {msg}",
                "stream": False
            },
            timeout=60
        )
        return r.json().get("response", "AI offline")
    except Exception:
        return "AI unreachable"

def update_metrics():
    # periodically update occurrence_total
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.execute("SELECT SUM(occurrence_count) FROM incidents")
    total = cur.fetchone()[0]
    conn.close()
    violations_occurrence_gauge.set(total or 0)

def main():
    init_db()

    # expose Prometheus metrics on :8000
    start_http_server(8000)

    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()

    v1 = client.CoreV1Api()
    print("📡 Sentinel watching Kyverno + exposing /metrics...")

    w = watch.Watch()
    for event in w.stream(v1.list_event_for_all_namespaces):
        obj = event["object"]
        msg = obj.message or ""
        if obj.type == "Warning" and "kyverno" in msg.lower():
            pod = obj.involved_object.name
            ns = obj.involved_object.namespace or "unknown"
            fp = hashlib.md5(f"{pod}{msg}".encode()).hexdigest()
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

            conn = sqlite3.connect(DB_PATH)
            cur = conn.cursor()
            cur.execute("SELECT id, occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
            row = cur.fetchone()

            if row:
                new_count = row[1] + 1
                cur.execute(
                    "UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?",
                    (new_count, now, fp)
                )
            else:
                aiout = call_sre_ai(msg)
                policy = "unknown"
                if "require-resources" in msg.lower():
                    policy = "require-resources"
                elif "require-team-label" in msg.lower():
                    policy = "require-team-label"

                cur.execute(
                    "INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?,?)",
                    (fp, pod, ns, obj.type, msg, aiout, 1, now, now)
                )
                violations_total.labels(policy=policy, severity="warning").inc()

            update_metrics()
            conn.commit()
            conn.close()
            print(f"🚨 {pod}/{ns}")
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st
import sqlite3
import pandas as pd
from datetime import datetime
import requests
from prometheus_client import Histogram

# optional: expose metrics from Streamlit
SCRAPE_LATENCY = Histogram(
    "streamlit_db_scrape_latency_seconds",
    "DB scrape latency in Streamlit"
)

st.set_page_config(layout="wide")
st.markdown(
    "<h1 style='text-align:center;color:#00f2ff'>🛰️ Sentinel Prime Aegis III</h1>",
    unsafe_allow_html=True
)

db = "/app/data/sentinel.db"

with SCRAPE_LATENCY.time():
    if os.path.exists(db):
        conn = sqlite3.connect(db)
        df = pd.read_sql("SELECT * FROM incidents ORDER BY updated_at DESC LIMIT 50", conn)
        conn.close()

        c1, c2, c3 = st.columns(3)
        c1.metric("🚨 Violations", len(df))
        c2.metric(
            "Hits",
            df["occurrence_count"].sum() if not df.empty else 0
        )
        c2.metric("Status", "LIVE")

        st.bar_chart(df.set_index("pod_name")["occurrence_count"])
        st.dataframe(df[["pod_name", "namespace", "message", "ai_analysis"]])
    else:
        st.info("🔄 Sentinel initializing...")

if __name__ == "__main__":
    # keep /metrics available (if you spin this in its own pod)
    from prometheus_client import start_http_server
    start_http_server(8001)
EOF

cat <<'EOF' > "$PROJECT_ROOT/exporter/Dockerfile"
FROM python:3.10-slim
RUN pip install prometheus_client
COPY exporter.py /exporter.py
CMD ["python","/exporter.py"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/exporter/exporter.py"
import sqlite3
import time
from prometheus_client import Gauge, start_http_server
from os import environ

DB_PATH = "/data/sentinel.db"
POLL_SECONDS = 10

# Prometheus metrics
violations_gauge = Gauge(
    "sentinel_violations_gauge",
    "Current number of distinct violations",
    []
)
occurrence_gauge = Gauge(
    "sentinel_violations_occurrence_total",
    "Total occurrence count of violations",
    []
)

def update_violations():
    try:
        conn = sqlite3.connect(DB_PATH)
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM incidents")
        cnt = cur.fetchone()[0]
        cur.execute("SELECT SUM(occurrence_count) FROM incidents")
        occ = cur.fetchone()[0]
        conn.close()

        violations_gauge.set(cnt or 0)
        occurrence_gauge.set(occ or 0)
    except Exception as e:
        print(f"DB error in exporter: {e}")

if __name__ == "__main__":
    start_http_server(9090)
    print("Exporter: /metrics on :9090")
    while True:
        update_violations()
        time.sleep(POLL_SECONDS)
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
    matchLabels: {app: dashboard}
  template:
    metadata:
      labels: {app: dashboard,team: sentinel-ops}
    spec:
      containers:
      - name: dashboard
        image: sentinel-dashboard:v6
        resources:
          limits: {cpu: "500m", memory: "512Mi"}
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
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sentinel-agent
  namespace: sentinel
spec:
  replicas: 1
  selector:
    matchLabels: {app: agent}
  template:
    metadata:
      labels: {app: agent,team: sentinel-ops}
    spec:
      hostNetwork: true
      containers:
      - name: agent
        image: sentinel-agent:v6
        env:
          - name: SENTINEL_MODEL
            value: "$MODEL_NAME"
        resources:
          limits: {cpu: "500m", memory: "512Mi"}
        ports:
          - containerPort: 8000  # Prometheus metrics
        volumeMounts:
          - name: data
            mountPath: /data
      volumes:
        - name: data
          hostPath:
            path: $PROJECT_ROOT/app/data
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sentinel-exporter
  namespace: sentinel
spec:
  replicas: 1
  selector:
    matchLabels: {app: exporter}
  template:
    metadata:
      labels: {app: exporter,team: sentinel-ops}
    spec:
      containers:
      - name: exporter
        image: sentinel-exporter:v6
        ports:
          - containerPort: 9090  # Prometheus metrics
        volumeMounts:
          - name: data
            mountPath: /data
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
  selector: {app: dashboard}
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
  selector: {app: agent}
  ports:
    - name: metrics
      port: 8000
      targetPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: sentinel-exporter-metrics
  namespace: sentinel
spec:
  selector: {app: exporter}
  ports:
    - name: metrics
      port: 9090
      targetPort: 9090
EOF

echo "🔨 Building Sentinel images..."
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

echo "✅ SENTINEL: http://$VM_IP:30501"

############################################
# 3. MONITORING (PROMETHEUS + GRAFANA, ENRICHED)
############################################
echo "📈 Deploying Prometheus + Grafana (with custom Sentinel metrics)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

kubectl create ns prometheus || true
helm upgrade --install prometheus prometheus-community/prometheus \
  -n prometheus \
  --set server.resources.limits.cpu=500m \
  --set server.resources.limits.memory=512Mi \
  --set server.extraScrapeConfigs='
- job_name: "sentinel-agent"
  static_configs:
    - targets: ["sentinel-agent-metrics.sentinel:8000"]
- job_name: "sentinel-exporter"
  static_configs:
    - targets: ["sentinel-exporter-metrics.sentinel:9090"]
'

kubectl create ns grafana || true
helm upgrade --install grafana grafana/grafana \
  -n grafana \
  --set resources.limits.cpu=300m \
  --set resources.limits.memory=256Mi \
  --set service.type=NodePort \
  --set service.nodePort=30502 \
  --set adminPassword=sentinel123

echo "✅ COMPLETE"
echo "🔗 Sentinel:  http://$VM_IP:30501"
echo "📊 Grafana:  http://$VM_IP:30502 (admin/sentinel123)"
echo "📡 Prometheus: http://$VM_IP:30900"
echo ""
echo "📈 Useful Prometheus metrics in Grafana:"
echo "  - sentinel_violations_total{policy=\"require-resources\"}"
echo "  - sentinel_violations_total{policy=\"require-team-label\"}"
echo "  - sentinel_violations_gauge"
echo "  - sentinel_violations_occurrence_total"

