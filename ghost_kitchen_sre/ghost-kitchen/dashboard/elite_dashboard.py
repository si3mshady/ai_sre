import json, os, time, pandas as pd, plotly.express as px, streamlit as st
from kafka import KafkaConsumer
from kubernetes import client, config
from collections import deque

st.set_page_config(layout="wide", page_title="Elite SRE Console", page_icon="🍳")
st.title("🍳 Elite Ghost Kitchen Control Plane")

if "data" not in st.session_state:
    st.session_state.data = {"orders": deque(maxlen=100), "alerts": deque(maxlen=50), "actions": deque(maxlen=50)}

@st.cache_resource
def get_consumers():
    brokers = os.getenv("BOOTSTRAP_SERVERS", "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092")
    topics = {"orders": "t1_kitchen.orders", "alerts": "t1_kitchen.alerts", "actions": "t1_kitchen.actions"}
    return {k: KafkaConsumer(v, bootstrap_servers=brokers, value_deserializer=lambda x: json.loads(x.decode('utf-8')), consumer_timeout_ms=100) for k, v in topics.items()}

def poll():
    consumers = get_consumers()
    for k, c in consumers.items():
        for msg in c: st.session_state.data[k].appendleft(msg.value)

def get_k8s_events():
    try:
        config.load_incluster_config()
        return [{"Time": e.last_timestamp, "Reason": e.reason, "Message": e.message} for e in client.CoreV1Api().list_namespaced_event("kitchen-sre", limit=15).items]
    except: return []

poll()

tab1, tab2, tab3, tab4, tab5 = st.tabs(["🔥 Live Orders", "🚨 SLO Alerts", "🤖 AI Decisions", "📊 SLO Dashboard", "☸️ Cluster Events"])

with tab1:
    if st.session_state.data["orders"]: st.dataframe(pd.DataFrame(list(st.session_state.data["orders"])))

with tab2:
    if st.session_state.data["alerts"]: st.dataframe(pd.DataFrame(list(st.session_state.data["alerts"])))

with tab3:
    if st.session_state.data["actions"]: st.dataframe(pd.DataFrame(list(st.session_state.data["actions"])))

with tab4:
    if len(st.session_state.data["orders"]) > 5:
        df = pd.DataFrame(list(st.session_state.data["orders"]))
        st.plotly_chart(px.line(df, x=pd.to_datetime(df['timestamp'], unit='s'), y='prep_time_required', color='station', title="Real-time Performance"))

with tab5:
    st.subheader("Live K3s Events (kitchen-sre)")
    events = get_k8s_events()
    if events: st.table(pd.DataFrame(events))

time.sleep(2)
st.rerun()
