import json, os, time, pandas as pd, plotly.express as px, streamlit as st
from kafka import KafkaConsumer
from kubernetes import client, config
from collections import deque

st.set_page_config(layout="wide", page_title="Elite SRE Token Factory", page_icon="🤖")
st.title("🍳 Elite Ghost Kitchen Command Center (RAG-Enabled)")

if "data" not in st.session_state:
    st.session_state.data = {
        "orders": deque(maxlen=100),
        "alerts": deque(maxlen=20),
        "actions": deque(maxlen=50) # Increased to store RAG history
    }

# --- K8S OPERATORS ---
def get_k8s_clients():
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()
    return client.CoreV1Api(), client.AppsV1Api()

def authorize_scale(deployment_name, replicas):
    _, apps = get_k8s_clients()
    mapping = {"fryer": "kitchen-producer", "sushi": "kitchen-agent", "grill": "kitchen-dashboard"}
    real_name = mapping.get(deployment_name, "kitchen-producer")
    try:
        apps.patch_namespaced_deployment_scale(name=real_name, namespace="kitchen-sre", body={"spec": {"replicas": replicas}})
        st.toast(f"🚀 Scaled {real_name} to {replicas}!")
    except Exception as e:
        st.error(f"K8s Error: {e}")

# --- TABS ---
tab1, tab2, tab3, tab4, tab5 = st.tabs(["📊 Monitoring", "⚠️ Alerts", "✅ Actions", "📝 K8s Events", "🧠 RAG Insights"])

with tab1:
    st.subheader("Real-time Kitchen Latency")
    if len(st.session_state.data["orders"]) > 0:
        df = pd.DataFrame(list(st.session_state.data["orders"]))
        df['time'] = pd.to_datetime(df['timestamp'], unit='s')
        fig = px.line(df, x='time', y='prep_time_required', color='station', template="plotly_dark")
        st.plotly_chart(fig, use_container_width=True)

with tab3:
    st.subheader("Pending Agent Proposals")
    for i, action in enumerate(list(st.session_state.data["actions"])):
        if action["status"] == "AWAITING_AUTH":
            with st.expander(f"Action: {action['type']} for {action['target']}", expanded=True):
                st.write(f"**Reasoning Chain:** {action['reason']}")
                if st.button(f"Approve {action['type']}", key=f"btn_{i}"):
                    authorize_scale(action['target'], action['value'])
                    action["status"] = "AUTHORIZED"
                    st.rerun()

with tab5:
    st.subheader("Knowledge Base Reasoning (Token Factory)")
    # Filter actions that contain RAG metadata
    rag_logs = [a for a in st.session_state.data["actions"] if "rag_metrics" in a]
    
    if rag_logs:
        for log in reversed(rag_logs):
            cols = st.columns([1, 4, 1, 1])
            cols[0].metric("Tokens", log["rag_metrics"].get("total_tokens", 0))
            cols[1].info(f"**Target:** {log['target']} | **Reasoning:** {log['reason']}")
            cols[2].metric("Latency", f"{log['rag_metrics'].get('latency_ms', 0)}ms")
            cols[3].metric("TPS", log["rag_metrics"].get("tokens_per_sec", 0))
            st.divider()
    else:
        st.info("No RAG reasoning logs captured yet...")


# --- KAFKA CONSUMER SETUP ---
@st.cache_resource
def get_consumer(topic):
    return KafkaConsumer(
        topic,
        bootstrap_servers=os.getenv('BOOTSTRAP_SERVERS', 'redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092'),
        value_deserializer=lambda x: json.loads(x.decode('utf-8')),
        auto_offset_reset='latest',
        consumer_timeout_ms=100  # Crucial: prevents the UI from freezing
    )

# Consume Order Stream
order_consumer = get_consumer("t1_kitchen.orders")
for message in order_consumer:
    st.session_state.data["orders"].append(message.value)
    # We only want to grab a few messages per refresh to keep the UI snappy
    if len(st.session_state.data["orders"]) > 100:
        break

# Consume Actions/RAG Insights (t1_kitchen.actions)
action_consumer = get_consumer("t1_kitchen.actions")
for message in action_consumer:
    # Avoid duplicates if the script reruns
    if message.value not in st.session_state.data["actions"]:
        st.session_state.data["actions"].append(message.value)

# Auto-refresh the UI every 2 seconds to show new data
time.sleep(2)
st.rerun()

# --- BACKGROUND CONSUMER ---
# In a real app, this would be in a separate thread, but for Streamlit 
# we use a quick non-blocking check or a placeholder.
