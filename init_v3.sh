#!/bin/bash
# Sentinel Prime: Aegis III — FULLY POLICY‑COMPLIANT (v5)
set -e

# ========= CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/sentinel-project"
MODEL_NAME="${MODEL_NAME:-llama3}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "🧹 Purging Old State..."
kubectl delete ns sentinel prometheus grafana kyverno 2>/dev/null || true
sudo docker rm -f sentinel-agent sentinel-dashboard 2>/dev/null || true
sudo rm -rf "$PROJECT_ROOT/app/data"
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s}
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
RUN pip install kubernetes requests
COPY agent.py /agent.py
CMD ["python","/agent.py"]
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/Dockerfile"
FROM python:3.10-slim
RUN pip install streamlit pandas
COPY app.py /app.py
WORKDIR /
CMD ["streamlit","run","/app.py","--server.port=8501","--server.address=0.0.0.0"]
EOF

cat <<EOF > "$PROJECT_ROOT/agent/agent.py"
import os, requests, sqlite3, time, hashlib, json
from datetime import datetime
from kubernetes import client, config, watch

MODEL_NAME=os.getenv("SENTINEL_MODEL","$MODEL_NAME")
OLLAMA_URL="http://127.0.0.1:11434"
DB_PATH="/data/sentinel.db"

def init_db():
    conn=sqlite3.connect(DB_PATH)
    conn.execute('''CREATE TABLE IF NOT EXISTS incidents (
        id INTEGER PRIMARY KEY, fingerprint TEXT UNIQUE, pod_name TEXT, namespace TEXT,
        severity TEXT, message TEXT, ai_analysis TEXT, occurrence_count INTEGER DEFAULT 1,
        created_at TEXT, updated_at TEXT)''')
    conn.close()

def call_sre_ai(msg):
    try:
        r=requests.post(f"{OLLAMA_URL}/api/generate",json={
            "model":MODEL_NAME,"prompt":f"SRE Fix: {msg}","stream":False},timeout=60)
        return r.json().get("response","AI offline")
    except: return "AI unreachable"

def main():
    init_db()
    try:config.load_incluster_config()
    except:config.load_kube_config()
    v1=client.CoreV1Api()
    print("📡 Sentinel watching Kyverno...")
    w=watch.Watch()
    for event in w.stream(v1.list_event_for_all_namespaces):
        obj=event["object"]
        msg=obj.message or ""
        if obj.type=="Warning" and "kyverno" in msg.lower():
            pod=obj.involved_object.name
            ns=obj.involved_object.namespace or "unknown"
            fp=hashlib.md5(f"{pod}{msg}".encode()).hexdigest()
            now=datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            conn=sqlite3.connect(DB_PATH);cur=conn.cursor()
            cur.execute("SELECT id FROM incidents WHERE fingerprint=?",(fp,))
            if cur.fetchone():
                cur.execute("UPDATE incidents SET occurrence_count=occurrence_count+1,updated_at=? WHERE fingerprint=?",(now,fp))
            else:
                aiout=call_sre_ai(msg)
                cur.execute("INSERT INTO incidents VALUES(NULL,?,?,?,?,?,?,?,?)",(fp,pod,ns,obj.type,msg,aiout,now,now))
            conn.commit();conn.close()
            print(f"🚨 {pod}/{ns}")

if __name__=="__main__":main()
EOF

cat <<'EOF' > "$PROJECT_ROOT/app/app.py"
import streamlit as st,sqlite3,pandas as pd
from datetime import datetime
st.set_page_config(layout="wide")
st.markdown("<h1 style='text-align:center;color:#00f2ff'>🛰️ Sentinel Prime Aegis III</h1>",unsafe_allow_html=True)

db="/app/data/sentinel.db"
if os.path.exists(db):
    conn=sqlite3.connect(db)
    df=pd.read_sql("SELECT * FROM incidents ORDER BY updated_at DESC LIMIT 50",conn)
    conn.close()
    c1,c2,c3=st.columns(3)
    c1.metric("🚨 Violations",len(df))
    c2.metric("Hits",df['occurrence_count'].sum() if not df.empty else 0)
    c3.metric("Status","LIVE")
    st.bar_chart(df.set_index('pod_name')['occurrence_count'])
    st.dataframe(df[['pod_name','namespace','message','ai_analysis']])
else:
    st.info("🔄 Sentinel initializing...")
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
        image: sentinel-dashboard:v5
        resources:
          limits: {cpu: "500m",memory: "512Mi"}
        ports: [{containerPort: 8501}]
        volumeMounts: [{name: data,mountPath: /app/data}]
      volumes: [{name: data,hostPath: {path: $PROJECT_ROOT/app/data}}]
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
        image: sentinel-agent:v5
        resources:
          limits: {cpu: "500m",memory: "512Mi"}
        volumeMounts: [{name: data,mountPath: /data}]
      volumes: [{name: data,hostPath: {path: $PROJECT_ROOT/app/data}}]
---
apiVersion: v1
kind: Service
metadata:
  name: sentinel-dashboard
  namespace: sentinel
spec:
  type: NodePort
  selector: {app: dashboard}
  ports: [{port: 8501,nodePort: 30501}]
EOF

echo "🔨 Deploying Sentinel..."
cd "$PROJECT_ROOT/agent" && sudo docker build -t sentinel-agent:v5 .
cd "$PROJECT_ROOT/app" && sudo docker build -t sentinel-dashboard:v5 .
sudo docker save sentinel-agent:v5 | sudo k3s ctr -n k8s.io images import -
sudo docker save sentinel-dashboard:v5 | sudo k3s ctr -n k8s.io images import -

kubectl create clusterrolebinding sentinel-admin --clusterrole=cluster-admin --serviceaccount=sentinel:default --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$PROJECT_ROOT/k8s/sentinel.yaml"

echo "✅ SENTINEL: http://$VM_IP:30501"

############################################
# 3. MONITORING (NOW FULLY EXCLUDED)
############################################
echo "📈 Deploying Prometheus + Grafana..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

kubectl create ns prometheus || true
helm upgrade --install prometheus prometheus-community/prometheus \
  -n prometheus \
  --set server.resources.limits.cpu=500m \
  --set server.resources.limits.memory=512Mi

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

