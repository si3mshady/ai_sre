import json
import os
import time
import pandas as pd
import plotly.express as px
import streamlit as st
from kafka import KafkaConsumer, KafkaProducer
from kubernetes import client, config
from threading import Thread, Lock
from collections import deque

# --- CONFIG & THEME ---
st.set_page_config(layout="wide", page_title="Sentinel Control Plane", page_icon="🍳")

st.markdown("""
    <style>
    .stApp { background-color: #0e1117; color: #ffffff; }
    [data-testid="stMetricValue"] { font-size: 1.8rem; color: #00ffcc; }
    .agent-thought { 
        background-color: #1e2127; 
        border-left: 5px solid #00ffcc; 
        padding: 15px; 
        margin: 10px 0;
        font-family: 'Courier New', Courier, monospace;
        border-radius: 4px;
    }
    .trace-meta { color: #888; font-size: 0.8rem; margin-bottom: 5px; }
    .node-pill { 
        background-color: #00ffcc22; 
        color: #00ffcc; 
        padding: 2px 8px; 
        border-radius: 10px; 
        font-size: 0.7rem; 
        text-transform: uppercase;
    }
    </style>
    """, unsafe_allow_html=True)

# --- THREAD-SAFE GLOBAL STATE ---
# We use a class to bypass Streamlit's session_state limitations in background threads
class GlobalSREState:
    def __init__(self):
        self.telemetry_history = deque(maxlen=100)
        self.agent_log_history = deque(maxlen=50)
        self.active_alerts = {}
        self.lock = Lock()

# This ensures the state object persists across UI reruns
@st.cache_resource
def get_global_state():
    return GlobalSREState()

sre_state = get_global_state()

# --- KAFKA CONFIG ---
BOOTSTRAP = os.getenv('BOOTSTRAP_SERVERS', 'redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092')

def get_producer():
    return KafkaProducer(
        bootstrap_servers=BOOTSTRAP,
        value_serializer=lambda v: json.dumps(v).encode('utf-8')
    )

# --- THE BACKGROUND CONSUMER ---
def kafka_consumer_thread():
    """Updates the thread-safe sre_state object directly."""
    try:
        consumer = KafkaConsumer(
            't1_kitchen.telemetry',
            't1_kitchen.alerts',
            't1_kitchen.agent_trace',
            bootstrap_servers=BOOTSTRAP,
            group_id='dashboard-v2-group',
            auto_offset_reset='latest',
            value_deserializer=lambda x: json.loads(x.decode('utf-8'))
        )
        
        for msg in consumer:
            topic = msg.topic
            data = msg.value
            
            with sre_state.lock:
                if topic == 't1_kitchen.telemetry':
                    sre_state.telemetry_history.append(data)
                
                elif topic == 't1_kitchen.alerts':
                    station = data.get('station', 'unknown')
                    if data.get('alert_type') == 'SLO_VIOLATION':
                        sre_state.active_alerts[station] = data
                    else:
                        sre_state.active_alerts.pop(station, None)
                
                elif topic == 't1_kitchen.agent_trace':
                    sre_state.agent_log_history.appendleft(data)
    except Exception as e:
        print(f"Consumer Thread Error: {e}")

# Start thread if not already running
if "thread_active" not in st.session_state:
    thread = Thread(target=kafka_consumer_thread, daemon=True)
    thread.start()
    st.session_state.thread_active = True

def send_control_signal(mode):
    producer = get_producer()
    payload = {"command": "SET_TRAFFIC_MODE", "mode": mode, "timestamp": time.time()}
    producer.send('t1_kitchen.control', payload)
    producer.flush()
    st.toast(f"Cluster Mode Switched to {mode}", icon="🚀")

# --- UI LAYOUT ---
st.title("🍳 Sentinel: Autonomous SRE Control Plane")

with st.sidebar:
    st.header("🕹️ Chaos Controller")
    if st.button("🟢 STEADY STATE", use_container_width=True): send_control_signal("STEADY")
    if st.button("🔴 LUNCH RUSH (Chaos)", use_container_width=True): send_control_signal("LUNCH_RUSH")
    if st.button("⚡ BURST MODE", use_container_width=True): send_control_signal("BURST")
    
    st.divider()
    st.subheader("⚠️ Active SLO Breaches")
    with sre_state.lock:
        if not sre_state.active_alerts:
            st.success("All Stations Healthy")
        for station, alert in sre_state.active_alerts.items():
            st.error(f"**{station.upper()}**\np95: {alert.get('p95_prep', 0)}s")

tab_viz, tab_agent, tab_k8s = st.tabs(["📊 Live Telemetry", "🧠 Agent Reasoning", "☸️ Cluster State"])

with tab_viz:
    with sre_state.lock:
        hist = list(sre_state.telemetry_history)
    
    if hist:
        df = pd.DataFrame(hist)
        latest = df.iloc[-1]
        c1, c2, c3 = st.columns(3)
        c1.metric("Station", latest.get('station', 'N/A').upper())
        c2.metric("p95 Latency", f"{latest.get('p95_prep', 0)}s")
        c3.metric("Load", f"{latest.get('order_count', 0)} orders/win")
        
        fig = px.line(df, x='timestamp', y='p95_prep', color='station', 
                      title="Real-time Station Latency", template="plotly_dark")
        fig.add_hline(y=8.0, line_dash="dash", line_color="red", annotation_text="SLO BREACH")
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("🛰️ Waiting for telemetry from Redpanda...")

with tab_agent:
    st.subheader("ReAct Thought Stream")
    with sre_state.lock:
        logs = list(sre_state.agent_log_history)
    
    if not logs:
        st.info("No active remediation traces.")
    for log in logs:
        st.markdown(f"""
            <div class="agent-thought">
                <div class="trace-meta">TRACE: {log.get('trace_id', 'N/A')} | NODE: {log.get('node', 'reasoning')}</div>
                <strong>Thought:</strong> {log.get('message', '...')}
                <br><br>
                <small style="color: #00ffcc;">Action: {log.get('action_taken', 'Awaiting Result')}</small>
            </div>
        """, unsafe_allow_html=True)

with tab_k8s:
    st.subheader("Kubernetes Namespace Status")
    try:
        config.load_incluster_config()
        apps_v1 = client.AppsV1Api()
        deps = apps_v1.list_namespaced_deployment(namespace="kitchen-sre")
        for d in deps.items:
            c1, c2, c3 = st.columns([2, 1, 1])
            c1.write(f"**{d.metadata.name}**")
            ready = d.status.ready_replicas or 0
            spec = d.spec.replicas or 1
            c2.write(f"Replicas: `{ready}/{spec}`")
            c3.progress(ready / spec)
    except Exception:
        st.warning("K8s API unavailable.")

time.sleep(1)
st.rerun()
