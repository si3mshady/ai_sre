#!/bin/bash
# Sentinel Prime: v7.2 — (CLASSROOM PRODUCTION READY) - [FULL EventsV1Event FIXED]
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
MODEL_NAME="${MODEL_NAME:-llama3}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

OLLAMA_SERVICE_URL="http://ollama-host.sentinel.svc.cluster.local:11434"

echo "🧹 Purging Old State..."
kubectl delete ns sentinel prometheus grafana kyverno 2>/dev/null || true
sudo docker rm -f sentinel-agent sentinel-dashboard sentinel-exporter 2>/dev/null || true
sudo rm -rf "$PROJECT_ROOT/app/data"
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s,exporter}
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
# 2. SENTINEL CORE - v7.2 (FULL EventsV1Event SAFETY)
############################################
cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes==29.0.0 requests==2.31.0 prometheus_client==0.20.0 && rm -rf /root/.cache/pip
COPY agent.py /agent.py
CMD ["python", "/agent.py"]
EOF

# 🔥 FIXED v7.2: BULLETPROOF EventsV1Event HANDLING
cat <<'EOF' > "$PROJECT_ROOT/agent/agent.py"
#!/usr/bin/env python3
import os, sys, time, requests, sqlite3, hashlib
from datetime import datetime
from kubernetes import client, config, watch
from prometheus_client import Counter, Gauge, start_http_server
import logging, threading

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger(__name__)

MODEL_NAME = os.getenv("SENTINEL_MODEL", "llama3")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")
DB_PATH = os.getenv("DB_PATH", "/data/sentinel.db")

violations_total = Counter("sentinel_violations_total", "Kyverno policy violations", ["policy", "severity"])
violations_occurrence_gauge = Gauge("sentinel_violations_occurrence_total", "Total occurrence count of violations")

def safe_getattr(obj, attr, default=""):
    """Safely get attribute from EventsV1Event objects"""
    try:
        return getattr(obj, attr, default)
    except:
        return default

def init_db():
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

def call_sre_ai(msg, timeout=120):
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
        return f"Ollama Error (Status: {r.status_code})"
    except requests.exceptions.Timeout:
        return f"AI Timed Out ({timeout}s)"
    except Exception as e:
        return f"AI unreachable: {e}"

def update_metrics():
    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        cur = conn.cursor()
        cur.execute("SELECT COALESCE(SUM(occurrence_count), 0) FROM incidents")
        count = cur.fetchone()[0]
        violations_occurrence_gauge.set(count or 0)
        conn.close()
    except:
        pass

def is_policy_violation(obj):
    msg = safe_getattr(obj, "message", "").lower()
    note = safe_getattr(obj, "note", "").lower()
    reason = safe_getattr(obj, "reason", "").lower()
    
    kyverno_indicators = ["kyverno", "policy", "validation", "admission", "forbidden"]
    for indicator in kyverno_indicators:
        if indicator in msg or indicator in note or indicator in reason:
            return True
    
    policies = ["require-resources", "require-team-label", "sentinel-guardrails"]
    event_type = safe_getattr(obj, "type", "")
    if event_type == "Warning" and any(policy in msg or policy in note or policy in reason for policy in policies):
        return True
    return False

def watch_events():
    while True:
        try:
            logger.info("📡 Connecting to cluster events...")
            config.load_incluster_config()
            events_api = client.EventsV1Api()
            w = watch.Watch()
            
            for event in w.stream(events_api.list_event_for_all_namespaces, timeout_seconds=600):
                obj = event["object"]
                
                # 🔥 v7.2: BULLETPROOF reference extraction
                ref = safe_getattr(obj, "involved_object", None) or safe_getattr(obj, "regarding", None)
                if not ref:
                    continue
                
                # 🔥 v7.2: BULLETPROOF attribute extraction
                severity = safe_getattr(obj, "type", "")
                if severity != "Warning":
                    continue
                
                pod = safe_getattr(ref, "name", "unknown")
                ns = safe_getattr(ref, "namespace", "unknown")
                
                # 🔥 v7.2: Try note first, then message (EventsV1Event standard)
                event_msg = safe_getattr(obj, "note", None)
                if not event_msg:
                    event_msg = safe_getattr(obj, "message", "no message")
                reason = safe_getattr(obj, "reason", "no reason")
                
                msg = f"{event_msg} | Reason: {reason}"
                fp = hashlib.md5(f"{pod}:{ns}:{msg}".encode()).hexdigest()
                now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
                
                if is_policy_violation(obj):
                    logger.info(f"🚨 POLICY VIOLATION: {pod}/{ns} - {msg[:100]}")
                    policy_name = "require-resources" if any(x in msg.lower() for x in ["resources", "cpu", "memory"]) else "require-team-label"
                else:
                    logger.info(f"⚠️ CLUSTER EVENT: {pod}/{ns} - {msg[:100]}")
                    policy_name = "cluster-event"

                conn = sqlite3.connect(DB_PATH, timeout=20)
                cur = conn.cursor()
                cur.execute("SELECT id, occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
                row = cur.fetchone()
                
                if row:
                    cur.execute("UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?", 
                               (row[1] + 1, now, fp))
                    logger.info(f"📊 Updated: {pod}/{ns} (count={row[1]+1})")
                else:
                    aiout = call_sre_ai(msg)
                    cur.execute("INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?,?)",
                               (fp, pod, ns, severity, msg[:1000], aiout, 1, now, now))
                    
                    if policy_name != "cluster-event":
                        violations_total.labels(policy=policy_name, severity="warning").inc()
                        
                    logger.info(f"🆕 NEW INCIDENT ({policy_name}): {pod}/{ns}")
                
                conn.commit()
                conn.close()
                update_metrics()
                
        except Exception as e:
            logger.error(f"Watch error (retry 10s): {e}")
            time.sleep(10)

def main():
    logger.info("🚀 Sentinel Agent v7.2 — CLASSROOM PRODUCTION READY")
    init_db()
    start_http_server(8000)
    logger.info("✅ Metrics server on :8000")
    
    event_thread = threading.Thread(target=watch_events, daemon=True)
    event_thread.start()
    
    while True:
        time.sleep(30)
        update_metrics()
        logger.info("Heartbeat OK")

if __name__ == "__main__":
    main()
EOF

# Dashboard (unchanged but v7.2 tagged)
cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit==1.36.0 pandas==2.2.2 prometheus_client==0.20.0 && rm -rf /root/.cache/pip
COPY app.py /app.py
EXPOSE 8501
CMD ["streamlit", "run", "/app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st, sqlite3, pandas as pd, os
st.set_page_config(layout="wide")
st.markdown("<h1 style='text-align:center;color:#00f2ff'>🛰️ Sentinel Prime v7.2</h1>", unsafe_allow_html=True)

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
            
            st.subheader("Recent Activity")
            chart_data = df.copy()
            chart_data['reps'] = chart_data['occurrence_count'] - 1
            st.bar_chart(chart_data.set_index("pod_name")[["reps"]], color="#ff4b4b")
            
            st.subheader("Details")
            st.dataframe(df[["namespace","pod_name","severity","message","ai_analysis","occurrence_count"]], use_container_width=True)
        else:
            st.info("🔄 No incidents yet. Deploy workloads!")
    except Exception as e:
        st.error(f"Database error: {e}")
else:
    st.warning("🔄 Waiting for agent...")
EOF

# Exporter (unchanged)
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

############################################
# 3. K8S MANIFEST v7.2 (v7.2 image tags)
############################################
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
apiVersion: v1
kind: Service
metadata:
  name: ollama-host
  namespace: sentinel
spec:
  type: ExternalName
  externalName: host.k3d.internal
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
        image: sentinel-dashboard:v7.2
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
          path: /home/*/*/sentinel-project/app/data
          type: DirectoryOrCreate
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sentinel-agent
  namespace: sentinel
spec:
  replicas: 1
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
      serviceAccountName: sentinel-agent-sa
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        fsGroup: 0
      containers:
      - name: agent
        image: sentinel-agent:v7.2
        env:
        - name: SENTINEL_MODEL
          value: "llama3"
        - name: OLLAMA_URL
          value: "http://ollama-host.sentinel.svc.cluster.local:11434"
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
          path: /home/*/*/sentinel-project/app/data
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
        image: sentinel-exporter:v7.2
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
          path: /home/*/*/sentinel-project/app/data
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

echo "🔨 Building v7.2 images..."
cd "$PROJECT_ROOT/agent" && sudo docker build -t sentinel-agent:v7.2 .
cd "$PROJECT_ROOT/app" && sudo docker build -t sentinel-dashboard:v7.2 .
cd "$PROJECT_ROOT/exporter" && sudo docker build -t sentinel-exporter:v7.2 .

sudo docker save sentinel-agent:v7.2 | sudo k3s ctr -n k8s.io images import -
sudo docker save sentinel-dashboard:v7.2 | sudo k3s ctr -n k8s.io images import -
sudo docker save sentinel-exporter:v7.2 | sudo k3s ctr -n k8s.io images import -

kubectl delete clusterrolebinding sentinel-admin 2>/dev/null || true
kubectl apply -f "$PROJECT_ROOT/k8s/sentinel.yaml"

echo "⏳ Waiting for pods..."
for i in {1..40}; do
  if kubectl wait --for=condition=Ready pod -l app=agent -n sentinel --timeout=120s 2>/dev/null; then
    echo "✅ SENTINEL v7.2 READY: http://$VM_IP:30501"
    break
  fi
  kubectl get pods -n sentinel -o wide || true
  sleep 5
done

############################################
# PROMETHEUS + GRAFANA
############################################
echo "📈 Deploying Monitoring..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

helm uninstall prometheus -n prometheus prometheus-stack -n prometheus || true
helm uninstall grafana -n grafana || true
kubectl delete ns prometheus grafana 2>/dev/null || true

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

helm upgrade --install prometheus prometheus-community/prometheus -n prometheus --create-namespace -f /tmp/prom-values.yaml

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

helm upgrade --install grafana grafana/grafana -n grafana --create-namespace -f /tmp/grafana-values.yaml

echo "🎉 ✅ COMPLETE - v7.2 CLASSROOM PRODUCTION READY!"
echo "🔗 Dashboard: http://$VM_IP:30501"
echo "📊 Grafana:  http://$VM_IP:30502 (admin/sentinel123)"
echo ""
echo "✅ FIXED: FULL EventsV1Event COMPATIBILITY (involved_object/regarding/note/message)"
echo "🧪 TEST: kubectl run test-pod --image=nginx --rm -it --restart=Never -- /bin/sh -c 'sleep 3600'"
echo "🧪 Then delete without resources: kubectl delete pod test-pod --force"

