#!/bin/bash
# Sentinel Prime: Aegis II - AI-Agentic SRE & Governance
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
MODEL_NAME="${MODEL_NAME:-llama3}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml 
# ==========================

echo "🧹 Purging Old Sentinel State..."
sudo docker rm -f sentinel-agent sentinel-dashboard 2>/dev/null || true
kubectl delete namespace sentinel 2>/dev/null || true
# Clean and reset data directory
sudo rm -rf "$PROJECT_ROOT/app/data"
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s}
sudo chmod -R 777 "$PROJECT_ROOT/app/data"

echo "🛡️ Bootstrapping Kyverno with Advanced Exclusions..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --set admissionController.replicas=1

# 2. DEFINE GOVERNANCE POLICIES (Exempting System Components)
cat <<'EOF' > /tmp/sentinel-policies.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sentinel-guardrails
  annotations:
    policies.kyverno.io/title: "SRE Governance Guardrails"
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
        message: "STRICT GOVERNANCE: CPU/Memory limits required for cluster stability."
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
        message: "STRICT GOVERNANCE: All pods must have a 'team' label for SRE tracking."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
kubectl apply -f /tmp/sentinel-policies.yaml

############################################
# 3. ENHANCED AGENT: THE FORENSIC INVESTIGATOR
############################################
cat <<EOF > "$PROJECT_ROOT/agent/agent.py"
import os, requests, sqlite3, json, time, hashlib
from datetime import datetime
from kubernetes import client, config, watch

MODEL_NAME = os.getenv("SENTINEL_MODEL", "$MODEL_NAME")
# Use the host IP to ensure communication with Ollama on the VM host
OLLAMA_URL = "http://127.0.0.1:11434" 
DB_PATH = "/data/sentinel.db"

def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS incidents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fingerprint TEXT UNIQUE,
            pod_name TEXT,
            namespace TEXT,
            severity TEXT,
            message TEXT,
            ai_analysis TEXT,
            occurrence_count INTEGER DEFAULT 1,
            created_at TEXT,
            updated_at TEXT
        )
    """)
    conn.close()

def call_sre_ai(event_msg):
    prompt = f"""
    [AUTHORITY: SENIOR SRE AGENT]
    An automated governance violation occurred in the Kubernetes Cluster.
    
    VIOLATION TRACE: {event_msg}

    TASK:
    1. Analyze the violation and identify the missing configuration.
    2. Provide the exact 'kubectl patch' or YAML snippet to remediate.
    3. Explain the risk of ignoring this policy in a production DoD-grade environment.
    
    Format: Professional, technical, and concise.
    """
    # Extended timeout and retry logic for local LLM warming
    for i in range(3):
        try:
            r = requests.post(f"{OLLAMA_URL}/api/generate",
                json={"model": MODEL_NAME, "prompt": prompt, "stream": False},
                timeout=180)
            return r.json().get("response", "Analysis failed.")
        except Exception as e:
            if i == 2: return f"AI Core Offline after retries: {str(e)}"
            time.sleep(5)

def main():
    init_db()
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()
        
    v1 = client.CoreV1Api()
    print("📡 AEGIS AGENT: Monitoring System Ingress...")
    w = watch.Watch()
    
    for event in w.stream(v1.list_event_for_all_namespaces):
        obj = event["object"]
        msg = obj.message or ""
        
        # Filter for Policy Violations
        if obj.type == "Warning" and any(x in msg.lower() for x in ["denied", "kyverno", "forbidden"]):
            # Logic to extract the actual offending resource name from the Kyverno message
            target_pod = obj.involved_object.name
            namespace = obj.involved_object.namespace or "admission"
            
            fingerprint = hashlib.md5(f"{msg}{target_pod}".encode()).hexdigest()
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            
            conn = sqlite3.connect(DB_PATH)
            cur = conn.cursor()
            cur.execute("SELECT id FROM incidents WHERE fingerprint = ?", (fingerprint,))
            existing = cur.fetchone()
            
            if existing:
                cur.execute("UPDATE incidents SET occurrence_count = occurrence_count + 1, updated_at = ? WHERE id = ?", (now, existing[0]))
            else:
                print(f"🧠 Consulting AI for incident: {target_pod}...")
                analysis = call_sre_ai(msg)
                cur.execute("INSERT INTO incidents (fingerprint, pod_name, namespace, severity, message, ai_analysis, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                            (fingerprint, target_pod, namespace, obj.type, msg, analysis, now, now))
            
            conn.commit()
            conn.close()
            print(f"🚨 Incident Logged: {target_pod}")

if __name__ == "__main__":
    main()
EOF

############################################
# 4. DOD-STYLE DASHBOARD (AUTO-REFRESH)
############################################
cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st
import sqlite3, os, pandas as pd
from datetime import datetime

st.set_page_config(page_title="SENTINEL PRIME | AEGIS", layout="wide")

# DOD/STRATCOM Visual Theme
st.markdown("""
    <style>
    @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap');
    .stApp { background: #020508; color: #00f2ff; font-family: 'Share Tech Mono', monospace; }
    .metric-card { background: #0a0f14; border: 1px solid #00f2ff; padding: 20px; border-radius: 2px; text-align: center; box-shadow: 0 0 10px #00f2ff33; }
    .violation-card { border: 1px solid #ff003c; background: #120205; padding: 20px; margin-bottom: 15px; border-left: 10px solid #ff003c; }
    .ai-box { background: #000d0d; border: 1px dashed #00f2ff; padding: 15px; color: #a3fdff; margin-top: 10px; }
    </style>
""", unsafe_allow_html=True)

# Auto-Refresh Script (every 15 seconds)
st.markdown("<script>setInterval(function(){ window.location.reload(); }, 15000);</script>", unsafe_allow_html=True)

st.sidebar.title("🛡️ AEGIS COMMAND")
st.sidebar.subheader(f"SYSTEM TIME: {datetime.now().strftime('%H:%M:%S')}")
if st.sidebar.button("MANUAL SCAN"):
    st.rerun()

st.markdown("<h1 style='text-align: center; letter-spacing: 5px;'>🛰️ SENTINEL PRIME : STRATCOM</h1>", unsafe_allow_html=True)
st.markdown("<p style='text-align: center; color: #666;'>CLASSIFIED // SRE GOVERNANCE LEVEL 4</p>", unsafe_allow_html=True)

db = "/app/data/sentinel.db"
if os.path.exists(db):
    conn = sqlite3.connect(db)
    df = pd.read_sql_query("SELECT * FROM incidents ORDER BY updated_at DESC", conn)
    
    # KPIs
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("THREATS", len(df))
    c2.metric("TOTAL BLOCKS", df['occurrence_count'].sum() if not df.empty else 0)
    c3.metric("INTEGRITY", "OPTIMAL")
    c4.metric("AI-AGENT", "ACTIVE")

    if not df.empty:
        st.markdown("### 📡 THREAT OVERVIEW")
        st.bar_chart(df.set_index('pod_name')['occurrence_count'])

    st.markdown("### 🚨 LIVE INTERCEPT LOG")
    for _, row in df.iterrows():
        with st.container():
            st.markdown(f"""
            <div class="violation-card">
                <div style="display:flex; justify-content:space-between;">
                    <span style="font-size:1.2em; font-weight:bold;">BLOCK: {row['pod_name']}</span>
                    <span style="color:#ff003c;">HITS: {row['occurrence_count']}</span>
                </div>
                <p style="font-size:0.8em; color:#888;">NS: {row['namespace']} | TIMESTAMP: {row['updated_at']}</p>
                <code style="color:#ff9eae; background:none;">{row['message']}</code>
                <div class="ai-box">
                    <b style="color:#00f2ff;">🤖 AI ADVISORY:</b><br>
                    {row['ai_analysis']}
                </div>
            </div>
            """, unsafe_allow_html=True)
    conn.close()
else:
    st.info("Awaiting initial telemetry stream...")
EOF

# --- BUILD & DEPLOY ---
cat <<'EOF' > "$PROJECT_ROOT/agent/Dockerfile"
FROM python:3.10-slim
RUN pip install kubernetes requests
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
    matchLabels: { app: dashboard }
  template:
    metadata:
      labels: { app: dashboard, team: sentinel-ops }
    spec:
      containers:
      - name: dashboard
        image: sentinel-dashboard:v1
        resources: 
          limits: { cpu: "500m", memory: "512Mi" }
        ports: [{ containerPort: 8501 }]
        volumeMounts: [{ name: data, mountPath: /app/data }]
      volumes: [{ name: data, hostPath: { path: $PROJECT_ROOT/app/data } }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sentinel-agent
  namespace: sentinel
spec:
  replicas: 1
  selector:
    matchLabels: { app: agent }
  template:
    metadata:
      labels: { app: agent, team: sentinel-ops }
    spec:
      hostNetwork: true
      containers:
      - name: agent
        image: sentinel-agent:v1
        resources: 
          limits: { cpu: "500m", memory: "512Mi" }
        volumeMounts: [{ name: data, mountPath: /data }]
      volumes: [{ name: data, hostPath: { path: $PROJECT_ROOT/app/data } }]
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

echo "🔨 Hardening Aegis Systems..."
cd "$PROJECT_ROOT/agent" && sudo docker build -t sentinel-agent:v1 .
cd "$PROJECT_ROOT/app" && sudo docker build -t sentinel-dashboard:v1 .
sudo docker save sentinel-agent:v1 | sudo k3s ctr -n k8s.io images import -
sudo docker save sentinel-dashboard:v1 | sudo k3s ctr -n k8s.io images import -

# Perms
kubectl create clusterrolebinding sentinel-admin --clusterrole=cluster-admin --serviceaccount=sentinel:default --overwrite 2>/dev/null || true

echo "🚀 Deploying..."
kubectl apply -f "$PROJECT_ROOT/k8s/sentinel.yaml"

echo "✅ AEGIS ONLINE"
echo "🔗 COMMAND CENTER: http://$VM_IP:30501"
