#!/bin/bash
# Kubernetes Kitchen MVP - GOLDEN SCRIPT v7 (HELM FIXED)
set -e
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

VM_IP=${VM_IP:-$(curl -s ifconfig.me || hostname -I | awk '{print $1}')}
NS_SHARED="shared-services"
NS_TENANT="tenant-kitchen-a"

echo "🍳=== KITCHEN MVP GOLDEN v7 - HELM REPO FIXED ==="
echo "📍 VM IP: $VM_IP | Taint: tenant=logistics-beta"

# 0. CLEANUP
echo "🧹 Cleanup..."
kubectl delete ns $NS_SHARED $NS_TENANT --ignore-not-found || true
sleep 3

# 1. NAMESPACES
echo "🏠 Creating namespaces..."
kubectl create namespace $NS_SHARED || true
kubectl create namespace $NS_TENANT || true
kubectl label namespace $NS_SHARED team=kitchen --overwrite
kubectl label namespace $NS_TENANT team=kitchen --overwrite

# 2. FIX HELM REPO (FORCE CLEAN)
echo "🔧 Fixing Helm repositories..."
helm repo remove redpanda 2>/dev/null || true
rm -rf ~/.cache/helm/repository/*
helm repo update

# 3. OFFICIAL REDPANDA HELM
echo "📦 Installing OFFICIAL Redpanda Helm..."
helm repo add redpanda https://helm.redpanda.com || true
helm repo update

helm upgrade --install redpanda redpanda/redpanda \
  --namespace $NS_SHARED \
  --create-namespace \
  --set replicas=1 \
  --set persistence.enabled=true \
  --set persistence.size=5Gi \
  --set auth=false \
  --set external.enabled=false \
  --set kafkaExternal.nodePort.enabled=true \
  --set adminExternal.nodePort.enabled=true \
  --set rpcExternal.nodePort.enabled=true \
  --set tolerations[0].key=tenant \
  --set tolerations[0].operator=Equal \
  --set tolerations[0].value=logistics-beta \
  --set tolerations[0].effect=NoSchedule \
  --wait --timeout=5m

echo "✅ Redpanda Helm deployed!"

# 4. OTHER COMPONENTS
cat > /tmp/kitchen-simple.yaml << 'EOF'
---
# OLLAMA PVC  
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-pvc
  namespace: shared-services
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 20Gi
---
# OLLAMA DEPLOYMENT
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: shared-services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      tolerations:
      - key: tenant
        operator: Equal
        value: logistics-beta
        effect: NoSchedule
      initContainers:
      - name: init-model
        image: ollama/ollama:latest
        command: ["/bin/sh"]
        args:
        - -c
        - |
          ollama serve &
          sleep 15 && 
          ollama pull llama3.2:3b || true
        volumeMounts:
        - name: storage
          mountPath: /root/.ollama
      containers:
      - name: ollama
        image: ollama/ollama:latest
        ports:
        - containerPort: 11434
        volumeMounts:
        - name: storage
          mountPath: /root/.ollama
        resources:
          requests:
            cpu: "1000m"
            memory: "4Gi"
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: ollama-pvc
---
# OLLAMA SERVICE
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: shared-services
spec:
  selector:
    app: ollama
  ports:
  - port: 11434
    targetPort: 11434
  type: NodePort
---
# PRODUCER CONFIGMAP (HELM SERVICE NAMES)
apiVersion: v1
kind: ConfigMap
metadata:
  name: producer-config
  namespace: tenant-kitchen-a
data:
  producer.py: |
    import subprocess,json,time,random,os
    KAFKA_BROKER="redpanda-kafka-bootstrap.shared-services.svc.cluster.local:9092"
    TOPIC="raw-orders"
    def publish_order():
        order={"order_id":f"ORD-{random.randint(1000,9999)}","timestamp":time.time(),"item_count":random.randint(1,10),"customer":f"cust-{random.randint(100,999)}"}
        cmd=["rpk","topic","produce",TOPIC,"-b",KAFKA_BROKER,"-X","tls.enabled=false","--parse-formats","json"]
        proc=subprocess.Popen(cmd,stdin=subprocess.PIPE,text=True)
        stdout,stderr=proc.communicate(json.dumps(order))
        print(f"✅ Published: {order['order_id']}")
        if stderr: print(f"STDERR: {stderr}")
    while True: publish_order(); time.sleep(random.uniform(3,8))
---
# PRODUCER DEPLOYMENT
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-generator
  namespace: tenant-kitchen-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-generator
  template:
    metadata:
      labels:
        app: order-generator
    spec:
      tolerations:
      - key: tenant
        operator: Equal
        value: logistics-beta
        effect: NoSchedule
      containers:
      - name: producer
        image: python:3.11-slim
        command: ["/bin/bash","-c"]
        args:
        - |
          apt-get update && apt-get install -y curl unzip procps &&
          curl -LO https://github.com/redpanda-data/redpanda/releases/download/v23.3.5/rpk-linux-amd64.zip &&
          unzip rpk-linux-amd64.zip && chmod +x rpk && mv rpk /usr/local/bin/ &&
          python /app/producer.py
        volumeMounts:
        - name: source
          mountPath: /app
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
      volumes:
      - name: source
        configMap:
          name: producer-config
---
# DASHBOARD CONFIGMAP
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-config
  namespace: tenant-kitchen-a
data:
  dashboard.py: |
    import streamlit as st, subprocess, json, pandas as pd
    st.title("🍳 Kitchen Dashboard - OFFICIAL HELM")
    KAFKA_BROKER="redpanda-kafka-bootstrap.shared-services.svc.cluster.local:9092"
    
    col1,col2=st.columns(2)
    with col1:
        if st.button("🔄 Raw Orders"):
            result=subprocess.run([
                "rpk","topic","consume","raw-orders",
                "-b",KAFKA_BROKER,"--num","10",
                "-X","tls.enabled=false"
            ],capture_output=True,text=True,timeout=15)
            orders=[]
            for l in result.stdout.split("\n"):
                if "value:" in l: 
                    try: 
                        value = l.split("value: ")[-1].strip()
                        orders.append(json.loads(value))
                    except: pass
            st.dataframe(pd.DataFrame(orders) if orders else pd.DataFrame({"status": ["No orders"]}))
            if result.stderr: st.error(result.stderr)
    
    with col2:
        if st.button("🔄 Insights"):
            result=subprocess.run([
                "rpk","topic","consume","agent-insights",
                "-b",KAFKA_BROKER,"--num","10",
                "-X","tls.enabled=false"
            ],capture_output=True,text=True,timeout=15)
            st.code(result.stdout)
---
# DASHBOARD DEPLOYMENT
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kitchen-dashboard
  namespace: tenant-kitchen-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kitchen-dashboard
  template:
    metadata:
      labels:
        app: kitchen-dashboard
    spec:
      tolerations:
      - key: tenant
        operator: Equal
        value: logistics-beta
        effect: NoSchedule
      containers:
      - name: dashboard
        image: python:3.11-slim
        command: ["/bin/bash","-c"]
        args:
        - |
          apt-get update && apt-get install -y curl unzip procps &&
          curl -LO https://github.com/redpanda-data/redpanda/releases/download/v23.3.5/rpk-linux-amd64.zip &&
          unzip rpk-linux-amd64.zip && chmod +x rpk && mv rpk /usr/local/bin/ &&
          pip install streamlit pandas &&
          streamlit run /app/dashboard.py --server.port 8501 --server.address 0.0.0.0 --server.headless true
        ports:
        - containerPort: 8501
        volumeMounts:
        - name: source
          mountPath: /app
      volumes:
      - name: source
        configMap:
          name: dashboard-config
---
apiVersion: v1
kind: Service
metadata:
  name: kitchen-dashboard
  namespace: tenant-kitchen-a
spec:
  selector:
    app: kitchen-dashboard
  ports:
  - port: 8501
    targetPort: 8501
  type: NodePort
EOF

kubectl apply -f /tmp/kitchen-simple.yaml

# 5. WAIT + TOPICS + STATUS
echo "⏳ Waiting for Redpanda Helm (2min)..."
sleep 120

echo "📦 Creating topics..."
kubectl exec -n $NS_SHARED redpanda-0 -- rpk topic create raw-orders --partitions 1 || true
kubectl exec -n $NS_SHARED redpanda-0 -- rpk topic create agent-insights --partitions 1 || true

# 6. FINAL STATUS
echo ""
echo "🎉 KITCHEN MVP GOLDEN v7 - OFFICIAL HELM DEPLOYED!"
echo "=================================================="
sleep 5

KAFKA_PORT=$(kubectl get svc -n $NS_SHARED redpanda-kafka-external -o jsonpath='{.spec.ports[0].nodePort}')
OLLAMA_PORT=$(kubectl get svc -n $NS_SHARED ollama -o jsonpath='{.spec.ports[0].nodePort}')
DASH_PORT=$(kubectl get svc -n $NS_TENANT kitchen-dashboard -o jsonpath='{.spec.ports[0].nodePort}')

echo "🔗 ACCESS YOUR SERVICES:"
echo "======================="
echo "📊 DASHBOARD:        http://$VM_IP:$DASH_PORT"
echo "🐙 REDPANDA KAFKA:   $VM_IP:$KAFKA_PORT" 
echo "🤖 OLLAMA API:       http://$VM_IP:$OLLAMA_PORT"
echo ""
kubectl get pods,svc -n $NS_SHARED $NS_TENANT -o wide
echo ""
echo "🔍 MONITOR PRODUCER:"
echo "kubectl logs -f deployment/order-generator -n $NS_TENANT"

