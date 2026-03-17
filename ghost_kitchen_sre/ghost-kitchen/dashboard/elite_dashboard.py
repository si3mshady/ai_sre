import json, os, time, pandas as pd, streamlit as st
from kafka import KafkaConsumer
from kubernetes import client, config
from collections import deque

st.set_page_config(layout="wide", page_title="Elite SRE Console", page_icon="🍳")
st.title("🍳 Elite Ghost Kitchen Command Center")

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
    # Map station names to your 3 REAL deployments
    mapping = {
        "fryer": "kitchen-producer",
        "sushi": "kitchen-agent",
        "grill": "kitchen-dashboard"
    }
    real_name = mapping.get(deployment_name, "kitchen-producer")
    
    try:
        apps.patch_namespaced_deployment_scale(
            name=real_name, 
            namespace="kitchen-sre", 
            body={"spec": {"replicas": replicas}}
        )
        st.toast(f"🚀 Scaled {real_name} to {replicas}")
    except Exception as e:
        st.error(f"K8s Error: {e}")

# --- DATA POLLING ---
@st.cache_resource
def get_kafka_io():
    brokers = os.getenv("BOOTSTRAP_SERVERS", "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092")
    return KafkaConsumer(
        bootstrap_servers=brokers, 
        value_deserializer=lambda x: json.loads(x.decode('utf-8')), 
        consumer_timeout_ms=100
    )

def poll():
    consumer = get_kafka_io()
    consumer.subscribe(["t1_kitchen.orders", "t1_kitchen.alerts"])
    for msg in consumer:
        if msg.topic == "t1_kitchen.orders":
            st.session_state.data["orders"].appendleft(msg.value)
        if msg.topic == "t1_kitchen.alerts":
            alert = msg.value
            # All alerts now show up in the UI again
            action_id = f"scale-{alert['station']}-{int(time.time())}"
            st.session_state.data["actions"].appendleft({
                "id": action_id,
                "type": "SCALE_DEPLOYMENT",
                "target": alert['station'],
                "value": alert['suggested_replicas'],
                "status": "AWAITING_AUTH",
                "reason": f"P95 Latency: {alert['p95_prep_time']}s"
            })

poll()

# --- LAYOUT ---
tab1, tab2, tab3 = st.tabs(["🔥 Orders", "🕹️ Authorization Queue", "☸️ Events"])

with tab1:
    if st.session_state.data["orders"]: 
        st.dataframe(pd.DataFrame(list(st.session_state.data["orders"])), use_container_width=True)

with tab2:
    st.subheader("Human-in-the-Loop Actions")
    for i, action in enumerate(list(st.session_state.data["actions"])):
        if action["status"] == "AWAITING_AUTH":
            with st.expander(f"Action for {action['target']}", expanded=True):
                col1, col2 = st.columns([3, 1])
                col1.write(f"**Targeting Station:** {action['target']} | **Reason:** {action['reason']}")
                if col2.button(f"Approve Scale ({action['value']})", key=f"btn_{i}"):
                    authorize_scale(action['target'], action['value'])
                    action["status"] = "AUTHORIZED"
                    st.rerun()

with tab3:
    try:
        core, _ = get_k8s_clients()
        events = [{"Reason": e.reason, "Object": e.involved_object.name, "Message": e.message} 
                  for e in core.list_namespaced_event("kitchen-sre", limit=10).items]
        st.table(pd.DataFrame(events))
    except: st.write("Waiting for cluster events...")

time.sleep(2)
st.rerun()
