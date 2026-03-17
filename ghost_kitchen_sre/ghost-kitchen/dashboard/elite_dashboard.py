import json, os, time, pandas as pd, plotly.express as px, streamlit as st
from kafka import KafkaConsumer, KafkaProducer
from kubernetes import client, config
from collections import deque

st.set_page_config(layout="wide", page_title="Elite SRE Console", page_icon="🍳")
st.title("🍳 Elite Ghost Kitchen Command Center")

# --- CONFIGURATION & SYNC ---
# This whitelist ensures we only try to scale what actually exists
MANAGED_DEPLOYMENTS = ["kitchen-agent", "kitchen-producer", "kitchen-dashboard"]

if "data" not in st.session_state:
    st.session_state.data = {"orders": deque(maxlen=50), "alerts": deque(maxlen=20), "actions": deque(maxlen=20)}

# --- K8S OPERATORS ---
def get_k8s_clients():
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()
    return client.CoreV1Api(), client.AppsV1Api()

def authorize_scale(deployment_name, replicas):
    _, apps = get_k8s_clients()
    try:
        # Safety check: Verify deployment exists before patching
        apps.read_namespaced_deployment(name=deployment_name, namespace="kitchen-sre")
        
        apps.patch_namespaced_deployment_scale(
            name=deployment_name, 
            namespace="kitchen-sre", 
            body={"spec": {"replicas": replicas}}
        )
        st.success(f"✅ Authorized: Scaled {deployment_name} to {replicas}")
        st.toast(f"Scaled {deployment_name}", icon="🚀")
    except client.exceptions.ApiException as e:
        if e.status == 404:
            st.error(f"❌ Deployment '{deployment_name}' not found in cluster!")
        else:
            st.error(f"🔥 K8s Error: {e.reason}")

def authorize_delete(pod_name):
    core, _ = get_k8s_clients()
    try:
        core.delete_namespaced_pod(name=pod_name, namespace="kitchen-sre")
        st.toast(f"🛡️ Authorized: Removed rogue pod {pod_name}", icon="🔥")
    except Exception as e:
        st.error(f"Could not delete pod: {e}")

def scan_security_risks():
    core, _ = get_k8s_clients()
    try:
        pods = core.list_namespaced_pod(namespace="kitchen-sre")
        for pod in pods.items:
            # Logic for detecting unauthorized pods
            if pod.metadata.labels.get("security") == "bad-pod" or "bad" in pod.metadata.name:
                if not any(a.get('target') == pod.metadata.name for a in st.session_state.data["actions"]):
                    st.session_state.data["actions"].appendleft({
                        "id": pod.metadata.uid,
                        "type": "DELETE_ROGUE_POD",
                        "target": pod.metadata.name,
                        "status": "AWAITING_AUTH",
                        "reason": "Security Policy Violation: Unauthorized Workload"
                    })
    except: pass

# --- DATA POLLING ---
@st.cache_resource
def get_kafka_io():
    brokers = os.getenv("BOOTSTRAP_SERVERS", "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092")
    c = KafkaConsumer(
        bootstrap_servers=brokers, 
        value_deserializer=lambda x: json.loads(x.decode('utf-8')), 
        consumer_timeout_ms=100
    )
    c.subscribe(["t1_kitchen.orders", "t1_kitchen.alerts"])
    return c

def poll():
    consumer = get_kafka_io()
    for msg in consumer:
        if msg.topic == "t1_kitchen.orders": 
            st.session_state.data["orders"].appendleft(msg.value)
        if msg.topic == "t1_kitchen.alerts":
            alert = msg.value
            station = alert['station']
            
            # SYNC LOGIC: Only create actions for real deployments
            # If Flink says 'fryer', but we want to scale 'kitchen-producer', map it here
            target_deployment = station if station in MANAGED_DEPLOYMENTS else None
            
            if target_deployment:
                action_id = f"scale-{target_deployment}-{int(time.time())}"
                # Avoid duplicate actions for same target
                if not any(a.get('id') == action_id for a in st.session_state.data["actions"]):
                    st.session_state.data["actions"].appendleft({
                        "id": action_id,
                        "type": "SCALE_DEPLOYMENT",
                        "target": target_deployment,
                        "value": alert['suggested_replicas'],
                        "status": "AWAITING_AUTH",
                        "reason": f"Latency Spike: P95 {alert['p95_prep_time']}s"
                    })
    scan_security_risks()

poll()

# --- DASHBOARD LAYOUT ---
tab1, tab2, tab3, tab4 = st.tabs(["🔥 Real-time Orders", "🚨 SLO Monitoring", "🕹️ Authorization Queue", "☸️ K3s Event Sink"])

with tab1:
    if st.session_state.data["orders"]: 
        st.dataframe(pd.DataFrame(list(st.session_state.data["orders"])), use_container_width=True)

with tab2:
    if st.session_state.data["alerts"]: 
        st.table(pd.DataFrame(list(st.session_state.data["alerts"])))

with tab3:
    st.subheader("Human-in-the-Loop Actions")
    actions_list = list(st.session_state.data["actions"])
    if not actions_list:
        st.info("No actions pending authorization.")
    
    for i, action in enumerate(actions_list):
        if action["status"] == "AWAITING_AUTH":
            with st.expander(f"{action['type']} for {action['target']}", expanded=True):
                col1, col2 = st.columns([3, 1])
                col1.write(f"**Reason:** {action['reason']}")
                if action["type"] == "SCALE_DEPLOYMENT":
                    if col2.button(f"Approve: Scale to {action['value']}", key=f"btn_scale_{i}"):
                        authorize_scale(action['target'], action['value'])
                        action["status"] = "AUTHORIZED"
                        st.rerun()
                else:
                    if col2.button("Approve: Delete Pod", key=f"btn_del_{i}", type="primary"):
                        authorize_delete(action['target'])
                        action["status"] = "AUTHORIZED"
                        st.rerun()

with tab4:
    st.subheader("Cluster-wide Events (kitchen-sre)")
    try:
        core, _ = get_k8s_clients()
        events_raw = core.list_namespaced_event("kitchen-sre", limit=15).items
        events = [{"Time": e.last_timestamp, "Type": e.type, "Reason": e.reason, "Object": e.involved_object.name, "Message": e.message} for e in events_raw]
        if events: 
            st.table(pd.DataFrame(events))
        else:
            st.write("No recent events.")
    except Exception as e: 
        st.error(f"K8s Connection Error: {e}")

time.sleep(2)
st.rerun()
