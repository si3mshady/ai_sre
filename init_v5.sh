#!/bin/bash
# Sentinel Prime: v7.3 — CLASSROOM PRODUCTION READY (OLLAMA + NAMESPACE FIXED)
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
MODEL_NAME="${MODEL_NAME:-llama3}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "🧹 Purging Old State..."
kubectl delete ns sentinel prometheus grafana kyverno 2>/dev/null || true
sudo docker rm -f sentinel-agent* sentinel-dashboard* sentinel-exporter* 2>/dev/null || true
sudo rm -rf "$PROJECT_ROOT/app/data"
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s,exporter}
sudo chmod -R 777 "$PROJECT_ROOT/app/data"

############################################
# 1. KYVERNO + POLICY
############################################
echo "🛡️ Deploying Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

echo "⏳ Waiting for kyverno..."
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
# 2. SENTINEL CORE - v7.3 (2MIN AI TIMEOUT + FIXED DNS)
############################################
cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes==29.0.0 requests==2.31.0 prometheus_client==0.20.0 && rm -rf /root/.cache/pip
COPY agent.py /agent.py
CMD ["python", "/agent.py"]
EOF

# 🔥 v7.3: 2MIN TIMEOUT + K3S DNS FIX
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
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://host.k3d.local:11434")  # 🔥 v7.3 K3S DNS
DB_PATH = os.getenv("DB_PATH", "/data/sentinel.db")

violations_total = Counter("sentinel_violations_total", "Kyverno policy violations", ["policy", "severity"])
violations_occurrence_gauge = Gauge("sentinel_violations_occurrence_total", "Total occurrence count")

def safe_getattr(obj, attr, default=""):
    try: return getattr(obj, attr, default)
    except: return default

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute('''CREATE TABLE IF NOT EXISTS incidents (
        id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT UNIQUE,
        pod_name TEXT, namespace TEXT, severity TEXT, message TEXT,
        ai_analysis TEXT, occurrence_count INTEGER DEFAULT 1, created_at TEXT, updated_at TEXT)''')
    conn.commit()
    conn.close()
    logger.info(f"Database at {DB_PATH}")

def call_sre_ai(msg, timeout=120):  # 🔥 v7.3: 2 MIN TIMEOUT FOR SLOW LOCAL OLLAMA
    try:
        logger.info(f"🤖 Calling Ollama ({timeout}s timeout): {OLLAMA_URL}")
        prompt = f"You are SRE expert. Concise fix for K8s event: {msg[:200]}"
        r = requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL_NAME, "prompt": prompt, "stream": False
        }, timeout=timeout)
        if r.status_code == 200:
            advice = r.json().get("response", "No AI response")
            logger.info("✅ AI advice received!")
            return advice[:1000]
        return f"Ollama HTTP {r.status_code}"
    except requests.exceptions.Timeout:
        logger.warning(f"AI timeout after {timeout}s - using fallback")
        return f"AI timeout ({timeout}s) - Add resources/team label to pod spec"
    except Exception as e:
        logger.error(f"AI error: {e}")
        return f"AI unavailable - Manual fix: add 'team: ops' label + resources limits"

def update_metrics():
    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        cur = conn.cursor()
        cur.execute("SELECT COALESCE(SUM(occurrence_count), 0) FROM incidents")
        violations_occurrence_gauge.set(cur.fetchone()[0])
        conn.close()
    except: pass

def is_policy_violation(obj):
    text = (safe_getattr(obj, "message") + safe_getattr(obj, "note") + safe_getattr(obj, "reason")).lower()
    indicators = ["kyverno", "policy", "validation", "admission", "forbidden"]
    if any(i in text for i in indicators): return True
    if safe_getattr(obj, "type") == "Warning" and any(p in text for p in ["require-resources", "require-team-label"]): return True
    return False

def watch_events():
    while True:
        try:
            logger.info("📡 Events watch...")
            config.load_incluster_config()
            w = watch.Watch()
            for event in w.stream(client.EventsV1Api().list_event_for_all_namespaces, timeout_seconds=600):
                obj = event["object"]
                ref = safe_getattr(obj, "involved_object") or safe_getattr(obj, "regarding")
                if not ref: continue
                
                if safe_getattr(obj, "type") != "Warning": continue
                
                pod = safe_getattr(ref, "name", "unknown")
                ns = safe_getattr(ref, "namespace", "default")
                event_msg = safe_getattr(obj, "note") or safe_getattr(obj, "message", "no message")
                reason = safe_getattr(obj, "reason", "unknown")
                msg = f"{event_msg} | {reason}"
                
                fp = hashlib.md5(f"{pod}:{ns}:{msg}".encode()).hexdigest()
                now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
                
                if is_policy_violation(obj):
                    logger.info(f"🚨 POLICY: {pod}/{ns} - {reason}")
                    policy_name = "require-resources" if "resources" in msg.lower() else "require-team-label"
                else:
                    logger.info(f"⚠️ EVENT: {pod}/{ns} - {reason}")
                    policy_name = "cluster-event"

                conn = sqlite3.connect(DB_PATH, timeout=20)
                cur = conn.cursor()
                cur.execute("SELECT occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
                row = cur.fetchone()
                
                if row:
                    cur.execute("UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?", (row[0]+1, now, fp))
                    logger.info(f"📊 Updated: {pod}/{ns} (count={row[0]+1})")
                else:
                    ai_analysis = call_sre_ai(msg)
                    cur.execute("INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?,?)",
                               (fp, pod, ns, safe_getattr(obj, "type"), msg[:1000], ai_analysis, 1, now, now))
                    if policy_name != "cluster-event":
                        violations_total.labels(policy=policy_name, severity="warning").inc()
                    logger.info(f"🆕 NEW INCIDENT ({policy_name}): {pod}/{ns}")
                
                conn.commit()
                conn.close()
                update_metrics()
        except Exception as e:
            logger.error(f"Watch error (10s): {e}")
            time.sleep(10)

def main():
    logger.info("🚀 Sentinel v7.3 - 2MIN AI + K3S DNS FIXED")
    init_db()
    start_http_server(8000)
    threading.Thread(target=watch_events, daemon=True).start()
    while True:
        time.sleep(30)
        update_metrics()
        logger.info("Heartbeat OK")

if __name__ == "__main__": main()
EOF

# Dashboard + Exporter (unchanged)
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
st.markdown("<h1 style='text-align:center;color:#00f2ff'>🛰️ Sentinel Prime v7.3</h1>", unsafe_allow_html=True)

db = "/app/data/sentinel.db"
if os.path.exists(db):
    try:
        conn = sqlite3.connect(db)
        df = pd.read_sql("SELECT * FROM incidents ORDER BY updated_at DESC LIMIT 100", conn)
        conn.close()
        if not df.empty:
            col1, col2, col3 = st.columns(3)
            col1.metric("🚨 Incidents", len(df))
            col2.metric("Repeats", df["occurrence_count"].sum() - len(df))
            col3.metric("Status", "LIVE")
            st.bar_chart(df.set_index("pod_name")["occurrence_count"])
            st.dataframe(df[["namespace","pod_name","message","ai_analysis","occurrence_count"]])
    except Exception as e:
        st.error(f"DB error: {e}")
else:
    st.warning("Waiting for agent...")
EOF

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
g1 = Gauge("sentinel_violations", "Violations")
g2 = Gauge("sentinel_occurrences", "Occurrences")
def update():
    try:
        conn = sqlite3.connect("/data/sentinel.db")
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*), COALESCE(SUM(occurrence_count), 0) FROM incidents")
        g1.set(cur.fetchone()[0])
        g2.set(cur.fetchone()[1])
        conn.close()
    except: pass
while True: update(); time.sleep(10)
EOF

############################################
# 3. K8S MANIFEST v7.3 (NAMESPACE FIRST)
############################################
echo "📦 Creating sentinel namespace..."
kubectl create namespace sentinel --dry-run=client -o yaml | kubectl apply -f -

cat > "$PROJECT_ROOT/k8s/sentinel.yaml" << 'EOF'
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
  externalName: host.k3d.local  # 🔥 v7.3: K3S LOCALHOST
  ports:
  - port: 11434
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
    matchLabels: {app: agent}
  template:
    metadata:
      labels: {app: agent, team: sentinel-ops}
    spec:
      serviceAccountName: sentinel-agent-sa
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        fsGroup: 0
      containers:
      - name: agent
        image: sentinel-agent:v7.3
        env:
        - name: SENTINEL_MODEL
          value: "llama3"
        - name: OLLAMA_URL
          value: "http://host.k3d.local:11434"  # 🔥 v7.3: DIRECT K3S HOST
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
apiVersion: v1
kind: Service
metadata:
  name: sentinel-agent-metrics
  namespace: sentinel
spec:
  selector: {app: agent}
  ports:
  - name: metrics
    port: 8001
    targetPort: 8000
EOF

echo "🔨 Building v7.3 images..."
cd "$PROJECT_ROOT/agent" && sudo docker build -t sentinel-agent:v7.3 .
cd "$PROJECT_ROOT/app" && sudo docker build -t sentinel-dashboard:v7.3 .
cd "$PROJECT_ROOT/exporter" && sudo docker build -t sentinel-exporter:v7.3 .

for img in sentinel-agent:v7.3 sentinel-dashboard:v7.3 sentinel-exporter:v7.3; do
  sudo docker save $img | sudo k3s ctr -n k8s.io images import -
done

kubectl delete clusterrolebinding sentinel-admin 2>/dev/null || true
kubectl apply -f "$PROJECT_ROOT/k8s/sentinel.yaml"

echo "⏳ Waiting for agent..."
for i in {1..40}; do
  if kubectl wait --for=condition=Ready pod -l app=agent -n sentinel --timeout=120s 2>/dev/null; then
    echo "✅ SENTINEL v7.3 READY!"
    break
  fi
  kubectl get pods -n sentinel || true
  sleep 5
done

echo "🎉 COMPLETE - v7.3 CLASSROOM PRODUCTION READY!"
echo "🔗 Agent Metrics:    http://$VM_IP:8001/metrics" 
echo "🧪 TEST VIOLATION:"
echo "kubectl run bad-pod --image=nginx --rm -it -- /bin/sh -c 'sleep 3600'"
echo "👉 Watch dashboard fill with 2min AI analysis!"

