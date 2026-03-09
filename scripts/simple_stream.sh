#!/usr/bin/env bash
set -e

echo "======================================"
echo "Redpanda + Streamlit Lab Deployment"
echo "======================================"

########################################
# FIX KUBECONFIG FOR k3s
########################################

if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    chmod 644 /etc/rancher/k3s/k3s.yaml
    echo "Using k3s kubeconfig: $KUBECONFIG"
else
    export KUBECONFIG=$HOME/.kube/config
fi

########################################
# VERIFY CLUSTER
########################################

echo ""
echo "[STEP 1] Checking Kubernetes cluster..."

kubectl cluster-info >/dev/null
kubectl get nodes

########################################
# VARIABLES
########################################

NAMESPACE="redpanda"
RELEASE="redpanda"
TOPIC="demo-events"

########################################
# CLEANUP
########################################

echo ""
echo "[STEP 2] Cleaning old installs..."

helm uninstall $RELEASE -n $NAMESPACE 2>/dev/null || true
kubectl delete namespace $NAMESPACE 2>/dev/null || true

sleep 4

########################################
# CREATE NAMESPACE
########################################

echo ""
echo "[STEP 3] Creating namespace..."

kubectl create namespace $NAMESPACE

########################################
# HELM REPO
########################################

echo ""
echo "[STEP 4] Updating Helm repos..."

helm repo add redpanda https://charts.redpanda.com 2>/dev/null || true
helm repo update

########################################
# VALUES FILE
########################################

echo ""
echo "[STEP 5] Creating Helm values..."

cat <<EOF > redpanda-values.yaml
external:
  enabled: true
  service:
    enabled: true
    type: NodePort

statefulset:
  replicas: 3

resources:
  cpu:
    cores: 1

storage:
  persistentVolume:
    enabled: false
EOF

########################################
# INSTALL REDPANDA
########################################

echo ""
echo "[STEP 6] Installing Redpanda..."

helm install redpanda redpanda/redpanda \
-n $NAMESPACE \
-f redpanda-values.yaml \
--kubeconfig $KUBECONFIG

########################################
# WAIT FOR PODS
########################################

echo ""
echo "[STEP 7] Waiting for Redpanda pods..."

kubectl wait \
--for=condition=ready pod \
-l app.kubernetes.io/name=redpanda \
-n $NAMESPACE \
--timeout=300s

########################################
# GET BROKER
########################################

echo ""
echo "[STEP 8] Discovering broker endpoint..."

NODEPORT=$(kubectl get svc -n $NAMESPACE redpanda-external -o jsonpath='{.spec.ports[1].nodePort}')
NODEIP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
BROKER="$NODEIP:$NODEPORT"

echo "Broker endpoint: $BROKER"

########################################
# CREATE TOPIC
########################################

echo ""
echo "[STEP 9] Creating topic..."

kubectl exec -n $NAMESPACE redpanda-0 -- \
rpk topic create $TOPIC || true

########################################
# INSTALL PYTHON DEPENDENCIES
########################################

echo ""
echo "[STEP 10] Installing Python dependencies..."

pip install kafka-python streamlit pandas

########################################
# CREATE PRODUCER
########################################

echo ""
echo "[STEP 11] Generating producer..."

cat <<EOF > producer.py
from kafka import KafkaProducer
import json,time,random

BROKER="$BROKER"
TOPIC="$TOPIC"

producer = KafkaProducer(
 bootstrap_servers=[BROKER],
 value_serializer=lambda v: json.dumps(v).encode()
)

print("Producer connected to",BROKER)

while True:

 event={
  "temperature":random.randint(20,40),
  "cpu":random.randint(0,100),
  "memory":random.randint(0,100),
  "time":time.time()
 }

 producer.send(TOPIC,event)

 print("sent",event)

 time.sleep(1)
EOF

########################################
# CREATE STREAMLIT DASHBOARD
########################################

echo ""
echo "[STEP 12] Generating Streamlit dashboard..."

cat <<EOF > dashboard.py
import streamlit as st
from kafka import KafkaConsumer
import json
import pandas as pd

BROKER="$BROKER"
TOPIC="$TOPIC"

st.title("Redpanda Streaming Dashboard")

consumer=KafkaConsumer(
 TOPIC,
 bootstrap_servers=[BROKER],
 value_deserializer=lambda x:json.loads(x.decode()),
 auto_offset_reset="latest"
)

data=[]

placeholder=st.empty()

for msg in consumer:

 event=msg.value
 data.append(event)

 df=pd.DataFrame(data)

 with placeholder.container():

  st.subheader("Latest Event")
  st.json(event)

  st.line_chart(df[["temperature","cpu","memory"]])
EOF

########################################
# START PRODUCER
########################################

echo ""
echo "[STEP 13] Starting producer..."

python producer.py &

########################################
# START STREAMLIT
########################################

echo ""
echo "[STEP 14] Starting Streamlit dashboard..."

streamlit run dashboard.py &

sleep 5

########################################
# DONE
########################################

echo ""
echo "======================================"
echo "LAB READY"
echo "======================================"

echo ""
echo "Broker:"
echo "$BROKER"

echo ""
echo "Dashboard:"
echo "http://localhost:8501"

echo ""
echo "Producer running and sending events."
