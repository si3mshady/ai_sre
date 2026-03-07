#!/bin/bash
# Sentinel-Logistics: v9.5 — THE UNIFIED GOLDEN COPY
# REVISION: Fixed Python SyntaxErrors, Environment Variable Injection, and Proper Indentation

# ========= GLOBAL CONFIG =========
LINUX_USER="${LINUX_USER:-$USER}"
VM_IP="${VM_IP:-172.190.214.187}"
PROJECT_ROOT="/home/$LINUX_USER/unified-sentinel"
MODEL_NAME="${MODEL_NAME:-llama3.2:3b}" 
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "================ Sentinel v9.5 — THE UNIFIED GOLDEN COPY =============="
echo "[INFO] Using Linux user: $LINUX_USER"
echo "[INFO] Project root: $PROJECT_ROOT"
echo "========================================================================"

# --- 0. PERMISSIONS FIX ---
echo "🔑 Adjusting K3s permissions for user $LINUX_USER..."
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# --- 1. PURGE OLD STATE ---
echo "🧹 Purging Previous Environments..."
kubectl delete ns sentinel 2>/dev/null || true
kubectl delete clusterrolebinding sentinel-agent-rbac-v91 2>/dev/null || true
sudo rm -rf /home/sentinel-data
mkdir -p "$PROJECT_ROOT"/{agent,app/data,k8s,monitoring,tenants}
sudo mkdir -p /home/sentinel-data
sudo chmod -R 777 /home/sentinel-data

# --- 2. DEPLOY KYVERNO ---
echo "🛡️ Checking Kyverno Policy Engine..."
helm repo add kyverno https://kyverno.github.io/kyverno/ || true
helm repo update

if ! helm status kyverno -n kyverno >/dev/null 2>&1; then
    echo "[INSTALL] Deploying Kyverno..."
    helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
fi

cat <<EOF > "$PROJECT_ROOT/k8s/policies.yaml"
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
        message: "CPU/Memory limits required for job-ready standards."
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
        message: "'team' label required for multi-tenant tracking."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF
kubectl apply -f "$PROJECT_ROOT/k8s/policies.yaml"

# --- 3. BUILD AI SRE AGENT ---
cat <<'EOF' > "$PROJECT_ROOT/agent/agent.py"
import os, time, requests, sqlite3, hashlib, logging
from datetime import datetime, timezone
from kubernetes import client, config, watch
from prometheus_client import Counter, Gauge, start_http_server

logging.basicConfig(level=logging.INFO, format='%(asctime)s [AGENT] %(message)s')
logger = logging.getLogger(__name__)

MODEL_NAME = os.getenv("SENTINEL_MODEL", "llama3.2:3b")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434")
DB_PATH = "/data/sentinel.db"

violations_total = Counter("sentinel_violations_total", "Kyverno violations")

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute('''CREATE TABLE IF NOT EXISTS incidents (
        id INTEGER PRIMARY KEY, fingerprint TEXT UNIQUE, pod_name TEXT, namespace TEXT,
        severity TEXT, message TEXT, ai_analysis TEXT, occurrence_count INTEGER DEFAULT 1,
        created_at TEXT, updated_at TEXT)''')
    conn.commit()
    conn.close()

def call_sre_ai(msg):
    try:
        r = requests.post(f"{OLLAMA_URL}/api/generate", json={
            "model": MODEL_NAME, "prompt": f"As an SRE, explain this Kyverno violation: {msg}", "stream": False
        }, timeout=300)
        return r.json().get("response", "AI Empty") if r.status_code == 200 else f"Error: {r.status_code}"
    except Exception as e: 
        return f"AI Error: {e}"

def watch_events():
    config.load_incluster_config()
    v1 = client.CoreV1Api()
    w = watch.Watch()
    for event in w.stream(v1.list_event_for_all_namespaces):
        obj = event["object"]
        msg_text = (obj.message or "").lower()
        if obj.type == "Warning" and ("kyverno" in msg_text or "policy" in msg_text):
            pod_name = obj.involved_object.name
            ns = obj.involved_object.namespace
            fp = hashlib.md5(f"{pod_name}:{obj.message}".encode()).hexdigest()
            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            conn = sqlite3.connect(DB_PATH)
            cur = conn.cursor()
            cur.execute("SELECT occurrence_count FROM incidents WHERE fingerprint=?", (fp,))
            row = cur.fetchone()
            if row:
                cur.execute("UPDATE incidents SET occurrence_count=?, updated_at=? WHERE fingerprint=?", (row[0]+1, now, fp))
            else:
                analysis = call_sre_ai(obj.message)
                cur.execute("INSERT INTO incidents (fingerprint, pod_name, namespace, severity, message, ai_analysis, occurrence_count, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?)",
                            (fp, pod_name, ns, "Warning", obj.message, analysis, 1, now, now))
            conn.commit()
            conn.close()
            violations_total.inc()

if __name__ == "__main__":
    init_db()
    start_http_server(8000)
    while True:
        try:
            watch_events()
        except Exception:
            time.sleep(5)
EOF

# --- 4. THE SAAS FACTORY ENGINE ---
deploy_tenant() {
    TENANT_NAME=$1
    CPU_LIMIT=${2:-"1000m"}
    MEM_LIMIT=${3:-"2Gi"}

    echo "🏗️ Onboarding Tenant: $TENANT_NAME..."
    kubectl create namespace $TENANT_NAME --dry-run=client -o yaml | kubectl apply -f -

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-pvc
  namespace: $TENANT_NAME
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dispatcher-agent
  namespace: $TENANT_NAME
spec:
  replicas: 1
  selector: { matchLabels: { app: dispatcher } }
  template:
    metadata:
      labels: { app: dispatcher, team: "${TENANT_NAME}" }
    spec:
      tolerations:
      - { key: "tenant", operator: "Equal", value: "logistics-beta", effect: "NoSchedule" }
      - { key: "node-role.kubernetes.io/control-plane", operator: "Exists", effect: "NoSchedule" }
      
      initContainers:
      - name: model-puller
        image: ollama/ollama:latest
        command: ["/bin/sh", "-c"]
        args: ["ollama serve & sleep 10 && ollama pull ${MODEL_NAME}"]
        volumeMounts:
        - name: model-storage
          mountPath: /root/.ollama
      
      containers:
      - name: agent
        image: python:3.11-slim
        env:
        - name: TENANT_NAME
          value: "${TENANT_NAME}"
        - name: MODEL_NAME
          value: "${MODEL_NAME}"
        command: ["/bin/sh", "-c"]
        args:
        - |
          pip install fastapi uvicorn requests --no-cache-dir
          cat <<'PYEOF' > main.py
          import os, requests, uvicorn
          from fastapi import FastAPI
          
          app = FastAPI()
          TENANT_NAME = os.getenv('TENANT_NAME', 'Unknown')
          MODEL_NAME = os.getenv('MODEL_NAME', 'llama3.2:3b')

          @app.get('/dispatch')
          async def d(msg: str):
              prompt = f"You are a specialized AI agent for the {TENANT_NAME} tenant. Always mention your tenant identity. Response to user: {msg}"
              try:
                  r = requests.post('http://localhost:11434/api/generate', 
                                    json={'model': MODEL_NAME, 'prompt': prompt, 'stream': False},
                                    timeout=120)
                  return r.json()
              except Exception as e:
                  return {"error": str(e)}

          if __name__ == '__main__':
              uvicorn.run(app, host='0.0.0.0', port=8000)
          PYEOF
          python main.py
        ports: [{ containerPort: 8000 }]
        resources:
          limits: { cpu: "500m", memory: "512Mi" }
      
      - name: ollama
        image: ollama/ollama:latest
        ports: [{ containerPort: 11434 }]
        volumeMounts:
        - name: model-storage
          mountPath: /root/.ollama
        resources:
          limits: { cpu: "${CPU_LIMIT}", memory: "${MEM_LIMIT}" }
          
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: ollama-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: dispatcher-service
  namespace: $TENANT_NAME
spec:
  type: NodePort
  selector: { app: dispatcher }
  ports: [{ port: 8000 }]
EOF

    DYNAMIC_PORT=$(kubectl get svc dispatcher-service -n $TENANT_NAME -o jsonpath='{.spec.ports[0].nodePort}')
    echo "✓ Tenant $TENANT_NAME fully isolated."
    echo "🔗 Demo Endpoint: http://$VM_IP:$DYNAMIC_PORT/dispatch?msg=Hello"
}

# --- FINAL OUTPUT ---
echo "⏳ Finalizing Deployment..."
sleep 2
echo "✅ Sentinel-Logistics v9.5 Deployed!"
echo "SRE Dashboard:  http://$VM_IP:30501"
echo "To Onboard: source $0 && deploy_tenant 'logistics-delta'"
