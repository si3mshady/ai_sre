#!/bin/bash
# Sentinel Prime: v7.0 — (Actually Running Edition) - [RBAC + Networking + Conflicts FIXED]
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
MODEL_NAME="${MODEL_NAME:-llama3}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# We define the internal OLLAMA_URL here for the Agent to use later
OLLAMA_SERVICE_URL="http://ollama-host.sentinel.svc.cluster.local:11434"

echo "🧹 Purging Old State (Forcing fresh start)..."
kubectl delete ns sentinel prometheus grafana kyverno 2>/dev/null || true
sudo docker rm -f sentinel-agent sentinel-dashboard sentinel-exporter 2>/dev/null || true
sudo rm -rf "$PROJECT_ROOT/app/data"
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s,exporter}
# Important for SQLite writes to function
sudo chmod -R 777 "$PROJECT_ROOT/app/data"

############################################
# 1. KYVERNO + POLICY (UNCHANGED)
############################################
echo "🛡️ Deploying Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

echo "⏳ Waiting for kyverno-svc..."
for i in {1..24}; do kubectl get endpoints kyverno-svc -n kyverno >/dev/null 2>&1 && break; sleep 5; done

# policies remain unchanged for continuity
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
# 2. SENTINEL CORE - THE FOUNDATION (v7.0)
############################################
# Agent Dockerfile
cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes==29.0.0 requests==2.31.0 prometheus_client==0.20.0 && rm -rf /root/.cache/pip
# Using root temporarily to remove DB permission ambiguity
COPY agent.py /agent.py
CMD ["python", "/agent.py"]
EOF

# Agent Python Script (Threaded, SRE Advice, 2min Ollama timeout, WATCHER FIXED for modern lib)
cat <<'EOF' > "$PROJECT_ROOT/agent/agent.py"
#!/usr/bin/env python3
import os, sys, time, requests, sqlite3, hashlib, json
from datetime import datetime
from kubernetes import client, config, watch
from prometheus_client import Counter, Gauge, start_http_server
import logging
import threading

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger(__name__)

MODEL_NAME = os.getenv("SENTINEL_MODEL", "llama3")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")
DB_PATH = os.getenv("DB_PATH", "/data/sentinel.db")

# Prometheus Metrics
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

def call_sre_ai(msg, timeout=120): # 2min timeout
    try:
        logger.info(f"🤖 Calling Ollama at {OLLAMA_URL}")
        prompt = f"You are an expert SRE. Provide concise, actionable fixing advice for this Kubernetes event: {msg[:200]}"
        r = requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL_NAME, "prompt": prompt, "stream": False
        }, timeout=timeout)
        if r.status_code == 200:
            advice = r.json().get("response", "AI returned no response.")
            logger.info("✅ Advice received from AI.")
            return advice[:1000] 
        else:
            return f"Ollama Error (Status: {r.status_code})"
    except requests.exceptions.Timeout:
        return f"AI Timed Out ({timeout}s)"
    except Exception as e:
        logger.error(f"Ollama Call Failed: {e}")
        return f"AI unreachable: {e}"

def update_metrics():
    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        cur = conn.cursor()
        cur.execute("SELECT COALESCE(SUM(occurrence_count), 0) FROM incidents")
        count = cur.fetchone()[0]
        if count is not None:
            violations_occurrence_gauge.set(count)
        conn.close()
    except Exception as e:
        pass # Expected failure pre-first incident

def is_policy_violation(obj):
    msg = (obj.message or "").lower()
    reason = (obj.reason or "").lower()
    
    # Standard Kyverno indicators
    kyverno_indicators = ["kyverno", "policy", "validation", "admission", "forbidden"]
    for indicator in kyverno_indicators:
        if indicator in msg or indicator in reason:
            return True
    
    # Specific guardrail check
    if obj.type == "Warning" and any(policy in msg or policy in reason for policy in ["require-resources", "require-team-label", "sentinel-guardrails"]):
        return True
    
    return False

def watch_events():
    while True:
        try:
            logger.info("📡 Reconnecting to cluster events...")
            config.load_incluster_config()
            events_api = client.EventsV1Api()
            w = watch.Watch()
            
            # Use list_event_for_all_namespaces
            # FIXED: compatibility issue by providing timeout_seconds in stream call
            for event in w.stream(events_api.list_event_for_all_namespaces, timeout_seconds=600):
                obj = event["object"]
                
                # Broad capture of all warning events
                if obj.type == "Warning":
                    pod = obj.involved_object.name or "unknown"
                    ns = obj.involved_object.namespace or "unknown"
                    msg = f"{obj.message} | Reason: {obj.reason}"
                    
                    # Generate fingerprint
                    fp = hashlib.md5(f"{pod}:{ns}:{msg}".encode()).hexdigest()
                    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
                    
                    if is_policy_violation(obj):
                        logger.info(f"🚨 POLICY VIOLATION CAPTURED: {pod}/{ns} - {msg[:100]}")
                        policy_name = "require-resources" if any(x in msg.lower() for x in ["resources", "cpu", "memory"]) else "require-team-label"
                    else:
                        logger.info(f"⚠️ CLUSTER EVENT CAPTURED: {pod}/{ns} - {msg[:100]}")
                        policy_name = "cluster-event"

                    conn = sqlite3.connect(DB_PATH, timeout=20) # Long timeout for DB write
                    cur = conn.cursor()
                    cur.execute("SELECT id, occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
                    row = cur.fetchone()
                    
                    if row:
                        cur.execute("UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?", 
                                   (row[1] + 1, now, fp))
                        logger.info(f"📊 Updated existing incident in DB: {pod}/{ns} (count={row[1]+1})")
                    else:
                        aiout = call_sre_ai(msg)
                        cur.execute("INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?,?)",
                                   (fp, pod, ns, obj.type, msg[:1000], aiout, 1, now, now))
                        
                        # Increment metric only for policy violations
                        if policy_name != "cluster-event":
                            violations_total.labels(policy=policy_name, severity="warning").inc()
                            
                        logger.info(f"🆕 NEW incident written to DB ({policy_name}): {pod}/{ns}")
                    
                    update_metrics()
                    conn.commit()
                    conn.close()
                    
        except Exception as e:
            logger.error(f"Critical watch loop error (reconnecting in 10s): {e}")
            time.sleep(10) # Wait before attempting to reconnect

def main():
    logger.info("🚀 Sentinel Agent v7.0 - RBAC FIXED + STABLE NETWORKING...")
    init_db()
    # Ensure metrics server is running on the *correct* port (containerPort: 8000)
    start_http_server(8000)
    logger.info("✅ Metrics server on :8000")
    
    # Start event watching in background thread
    event_thread = threading.Thread(target=watch_events, daemon=True)
    event_thread.start()
    
    # Keep main thread alive for metrics and heartbeat
    while True:
        time.sleep(30)
        update_metrics()
        logger.info("Heartbeat OK")

if __name__ == "__main__":
    main()
EOF

# Dashboard Dockerfile (UNCHANGED)
cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit==1.36.0 pandas==2.2.2 prometheus_client==0.20.0 && rm -rf /root/.cache/pip
# Using root temporarily to remove permission ambiguity
COPY app.py /app.py
EXPOSE 8501
CMD ["streamlit", "run", "/app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

# Dashboard Python Script (v7.0 updates to metrics)
cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st, sqlite3, pandas as pd, os
from datetime import datetime

st.set_page_config(layout="wide")
st.markdown("<h1 style='text-align:center;color:#00f2ff'>🛰️ Sentinel Prime v7.0</h1>", unsafe_allow_html=True)

db = "/app/data/sentinel.db"
if os.path.exists(db):
    try:
        conn = sqlite3.connect(db)
        df = pd.read_sql("SELECT * FROM incidents ORDER BY updated_at DESC LIMIT 100", conn)
        conn.close()
        
        if not df.empty:
            col1, col2, col3 = st.columns(3)
            col1.metric("🚨 Total Incidents", len(df))
            col2.metric("Hits (Repeats)", df["occurrence_count"].sum() - len(df))
            col3.metric("Status", "LIVE")
            
            st.subheader("Recent Activity (Incidents vs. Repetitions)")
            chart_data = df.copy()
            chart_data['reps'] = chart_data['occurrence_count'] - 1
            st.bar_chart(chart_data.set_index("pod_name")[["reps"]], color="#ff4b4b")
            
            st.subheader("Details")
            st.dataframe(df[["namespace","pod_name","severity","message","ai_analysis","occurrence_count"]], use_container_width=True)
        else:
            st.info("🔄 No incidents detected yet. Deploy workloads or trigger events!")
    except Exception as e:
        st.error(f"Error reading database: {e}")
else:
    st.warning(f"🔄 Waiting for database to be initialized at {db}...")
EOF

# Exporter Dockerfile (UNCHANGED)
cat <<'EOF' > "$PROJECT_ROOT/exporter/Dockerfile"
FROM python:3.10-slim
RUN pip install prometheus_client==0.20.0 && rm -rf /root/.cache/pip
# Using root temporarily to remove permission ambiguity
COPY exporter.py /exporter.py
CMD ["python", "/exporter.py"]
EOF

# Exporter Python Script (UNCHANGED)
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
    except Exception as e:
        pass

while True:
    update()
    time.sleep(10)
EOF

############################################
# 3. KUBERNETES MANIFEST (GOLDEN CLUSTER v7.0)
############################################
# This manifest creates the precise RBAC and networking configuration required.
cat > "$PROJECT_ROOT/k8s/sentinel.yaml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: sentinel
---
# FIXED v7.0: DEDICATED SERVICE ACCOUNT (Kyverno compliance)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sentinel-agent-sa
  namespace: sentinel
---
# FIXED v7.0: HARDENED RBAC FOR EVENTS ACCESS
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sentinel-event-watcher
rules:
- apiGroups: [""] # Core API group
  resources: ["events"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["events.k8s.io"] # Dedicated Events API group (fixes 403)
  resources: ["events"]
  verbs: ["get", "list", "watch"]
---
# FIXED v7.0: BIND DEDICATED SA TO THE NEW ROLE
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sentinel-agent-rbac
subjects:
- kind: ServiceAccount
  name: sentinel-agent-sa
  namespace: sentinel
roleRef:
  kind: ClusterRole
  name: sentinel-event-watcher
  apiGroup: rbac.authorization.k8s.io
---
# FIXED v7.0: Egress Service to VM Host (Stable Ollama Networking)
apiVersion: v1
kind: Service
metadata:
  name: ollama-host
  namespace: sentinel
spec:
  type: ExternalName
  externalName: host.k3d.internal # Maps inside k3s to the host VM
  ports:
  - port: 11434
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
        runAsUser: 0
        runAsGroup: 0
        fsGroup: 0
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
        volumeMounts:
        - name: data
          mountPath: /app/data
      volumes:
      - name: data
        hostPath:
          path: ${PROJECT_ROOT}/app/data
          type: DirectoryOrCreate
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sentinel-agent
  namespace: sentinel
spec:
  replicas: 1
  # FIXED v7.0: Recreate strategy prevents hanging upgrades/port conflicts
  strategy:
    type: Recreate
  selector:
    matchLabels: 
      app: agent
  template:
    metadata:
      labels: 
        app: agent
        team: sentinel-ops
    spec:
      # FIXED v7.0: Use the dedicated ServiceAccount
      serviceAccountName: sentinel-agent-sa
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        fsGroup: 0
      containers:
      - name: agent
        image: sentinel-agent:v6
        env:
        - name: SENTINEL_MODEL
          value: "${MODEL_NAME}"
        # FIXED v7.0: Point to the ExternalName Service
        - name: OLLAMA_URL
          value: "${OLLAMA_SERVICE_URL}"
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
          timeoutSeconds: 5
      # Removed hostNetwork: true (fixing port conflicts and pending state)
      volumes:
      - name: data
        hostPath:
          path: ${PROJECT_ROOT}/app/data
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
        runAsUser: 0
        runAsGroup: 0
        fsGroup: 0
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
          path: ${PROJECT_ROOT}/app/data
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

# Remove BROAD permissions, replace with precision RBAC (Kyverno compliant)
kubectl delete clusterrolebinding sentinel-admin 2>/dev/null || true

# Apply the Golden Manifest
kubectl apply -f "$PROJECT_ROOT/k8s/sentinel.yaml"

echo "⏳ Waiting for pods (2min timeout)..."
for i in {1..40}; do
  if kubectl wait --for=condition=Ready pod -l app=agent -n sentinel --timeout=120s 2>/dev/null; then
    echo "✅ SENTINEL v7.0 READY: http://$VM_IP:30501"
    break
  fi
  kubectl get pods -n sentinel -o wide || true
  sleep 5
done

############################################
# 3. PROMETHEUS + GRAFANA (UNCHANGED)
############################################
echo "📈 Deploying Monitoring..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

helm uninstall prometheus -n prometheus || true
helm uninstall grafana -n grafana || true
kubectl delete ns prometheus grafana || true

kubectl create ns prometheus
kubectl create ns grafana

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

echo "🎉 ✅ COMPLETE - v7.0 GOLDEN EDITION (Actual Cluster Events)!"
echo "🔗 Sentinel Dashboard: http://$VM_IP:30501"
echo "📊 Grafana:            http://$VM_IP:30502 (admin/sentinel123)"
echo "📡 Prometheus:         Use port 30900 (configure svc to expose)"
echo ""
echo "✅ FIXED:"
echo "  • RBAC 403 Forbidden (Patched ClusterRole for Events)."
echo "  • Port Conflict (PENDING) (Removed hostNetwork, added Service Discovery)."
echo "  • Ollama Connectivity (ADDED ExternalName Service mapping)."
echo "  • SQLite Writes (Threaded DB access + extended timeouts)."
echo ""
