import json, os, time, pandas as pd, plotly.express as px, streamlit as st
from kafka import KafkaConsumer
from kubernetes import client, config
from collections import deque

# --- CONFIG & THEME ---
st.set_page_config(layout="wide", page_title="Elite SRE Token Factory", page_icon="🤖")
st.markdown("""
    <style>
    .stApp { background-color: #0e1117; color: #ffffff; }
    [data-testid="stMetricValue"] { font-size: 1.8rem; color: #00ffcc; }
    </style>
    """, unsafe_allow_html=True)

st.title("🍳 Elite Ghost Kitchen Command Center")

# Initialize State
if "data" not in st.session_state:
    st.session_state.data = {
        "orders": deque(maxlen=100),
        "alerts": deque(maxlen=20),
        "actions": deque(maxlen=50)
    }

# --- K8S OPERATORS ---
def get_k8s_clients():
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()
    return client.CoreV1Api(), client.AppsV1Api()

def fetch_k8s_events():
    try:
        core, _ = get_k8s_clients()
        # Fetch last 15 events from the namespace
        events = core.list_namespaced_event(namespace="kitchen-sre")
        sorted_events = sorted(events.items, key=lambda x: x.last_timestamp or x.event_time or 0, reverse=True)
        return [{"Time": e.last_timestamp, "Object": e.involved_object.name, "Reason": e.reason, "Message": e.message} for e in sorted_events[:15]]
    except Exception as e:
        return [{"Error": str(e)}]

def authorize_scale(deployment_name, replicas):
    _, apps = get_k8s_clients()
    mapping = {"fryer": "kitchen-producer", "sushi": "kitchen-agent", "grill": "kitchen-dashboard"}
    real_name = mapping.get(deployment_name, "kitchen-producer")
    try:
        apps.patch_namespaced_deployment_scale(name=real_name, namespace="kitchen-sre", body={"spec": {"replicas": replicas}})
        st.toast(f"🚀 Scaled {real_name} to {replicas}!")
    except Exception as e:
        st.error(f"K8s Error: {e}")

# --- KAFKA CONSUMER LOGIC ---
@st.cache_resource
def get_consumers():
    bootstrap = os.getenv('BOOTSTRAP_SERVERS', 'redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092')
    conf = {
        'bootstrap_servers': bootstrap,
        'value_deserializer': lambda x: json.loads(x.decode('utf-8')),
        'auto_offset_reset': 'latest',
        'consumer_timeout_ms': 50 # Fast timeout for UI responsiveness
    }
    return {
        "orders": KafkaConsumer("t1_kitchen.orders", **conf),
        "actions": KafkaConsumer("t1_kitchen.actions", **conf)
    }

# --- BACKGROUND DATA SYNC ---
consumers = get_consumers()

# Poll Orders
for msg in consumers["orders"]:
    st.session_state.data["orders"].append(msg.value)

# Poll Actions/RAG Insights
for msg in consumers["actions"]:
    # Avoid duplicates
    if not any(a.get('id') == msg.value.get('id') for a in st.session_state.data["actions"]):
        st.session_state.data["actions"].append(msg.value)

# --- TABS ---
tab1, tab2, tab3, tab4, tab5 = st.tabs(["📊 Monitoring", "⚠️ Alerts", "✅ Actions", "📝 K8s Events", "🧠 RAG Insights"])

with tab1:
    st.subheader("Real-time Kitchen Latency")
    if len(st.session_state.data["orders"]) > 0:
        df = pd.DataFrame(list(st.session_state.data["orders"]))
        df['time'] = pd.to_datetime(df['timestamp'], unit='s')
        fig = px.line(df, x='time', y='prep_time_required', color='station', template="plotly_dark")
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("Waiting for order stream... (Checking t1_kitchen.orders)")

with tab3:
    st.subheader("Pending Agent Proposals")
    pending = [a for a in st.session_state.data["actions"] if a["status"] == "AWAITING_AUTH"]
    if not pending:
        st.write("No actions pending authorization.")
    for i, action in enumerate(pending):
        with st.expander(f"Action: {action['type']} for {action['target']}", expanded=True):
            st.write(f"**Reasoning Chain:** {action['reason']}")
            if st.button(f"Approve {action['type']} ##{i}", key=f"btn_{action['id']}"):
                authorize_scale(action['target'], action['value'])
                action["status"] = "AUTHORIZED"
                st.rerun()

with tab4:
    st.subheader("Live Kubernetes Events (kitchen-sre)")
    event_data = fetch_k8s_events()
    st.table(event_data)

with tab5:
    st.subheader("Knowledge Base Reasoning (Token Factory)")
    # RAG logs usually come tucked inside the 'actions' or 'alerts' if the agent is outputting them
    rag_logs = [a for a in st.session_state.data["actions"] if "rag_metrics" in a]
    
    if rag_logs:
        for log in reversed(rag_logs):
            cols = st.columns([1, 4, 1, 1])
            metrics = log.get("rag_metrics", {})
            cols[0].metric("Tokens", metrics.get("total_tokens", 0))
            cols[1].info(f"**Target:** {log['target']} | **Reasoning:** {log['reason']}")
            cols[2].metric("Latency", f"{metrics.get('latency_ms', 0)}ms")
            cols[3].metric("TPS", metrics.get("tokens_per_sec", 0))
            st.divider()
    else:
        st.info("No RAG reasoning logs captured yet. Check Agent logs for 'Read timed out' errors.")

# AUTO-REFRESH SCRIPT
time.sleep(1)
st.rerun()
