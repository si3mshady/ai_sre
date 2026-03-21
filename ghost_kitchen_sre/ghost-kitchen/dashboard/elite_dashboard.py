import json
import os
import time
import pandas as pd
import plotly.express as px
import streamlit as st
from kafka import KafkaConsumer, KafkaProducer
from kubernetes import client, config
from threading import Thread
from collections import deque

# --- CONFIG & THEME ---
st.set_page_config(layout="wide", page_title="Sentinel Control Plane", page_icon="🍳")

# Professional SRE Dark Theme
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

# --- STATE MANAGEMENT (Persistent across Streamlit reruns) ---
if "telemetry_history" not in st.session_state:
    st.session_state.telemetry_history = deque(maxlen=100)
if "agent_log_history" not in st.session_state:
    st.session_state.agent_log_history = deque(maxlen=50)
if "active_alerts" not in st.session_state:
    st.session_state.active_alerts = {}

# --- KAFKA CONFIG ---
BOOTSTRAP = os.getenv('BOOTSTRAP_SERVERS', 'redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092')

def get_producer():
    return KafkaProducer(
        bootstrap_servers=BOOTSTRAP,
        value_serializer=lambda v: json.dumps(v).encode('utf-8')
    )

# --- THE BACKGROUND CONSUMER (The Live Feed) ---
def kafka_consumer_thread():
    """
    This thread runs forever, pulling REAL data from Redpanda.
    It updates st.session_state, which the main UI then renders.
    """
    consumer = KafkaConsumer(
        't1_kitchen.telemetry',  # From Flink (Aggregated Metrics)
        't1_kitchen.alerts',     # From Flink (Sustained Breaches)
        't1_kitchen.agent_trace',# From Control Plane (ReAct Thoughts)
        bootstrap_servers=BOOTSTRAP,
        group_id='dashboard-v2-group',
        auto_offset_reset='latest',
        value_deserializer=lambda x: json.loads(x.decode('utf-8'))
    )
    
    for msg in consumer:
        topic = msg.topic
        data = msg.value
        
        if topic == 't1_kitchen.telemetry':
            # Add to deque for plotting
            st.session_state.telemetry_history.append(data)
        
        elif topic == 't1_kitchen.alerts':
            station = data.get('station', 'unknown')
            if data.get('alert_type') == 'SLO_VIOLATION':
                st.session_state.active_alerts[station] = data
            else:
                # If alert_type is 'NORMAL', clear the alert from the dash
                st.session_state.active_alerts.pop(station, None)
        
        elif topic == 't1_kitchen.agent_trace':
            # This is the "Reasoning" data from your LangGraph Agent
            st.session_state.agent_log_history.appendleft(data)

# Ensure the consumer only starts once
if "consumer_started" not in st.session_state:
    thread = Thread(target=kafka_consumer_thread, daemon=True)
    thread.start()
    st.session_state.consumer_started = True

# --- ACTION: TRIGGER MODES ---
def send_control_signal(mode):
    """Writes a command to the control topic for the Producer to pick up."""
    producer = get_producer()
    payload = {
        "command": "SET_TRAFFIC_MODE",
        "mode": mode,
        "timestamp": time.time()
    }
    producer.send('t1_kitchen.control', payload)
    producer.flush()
    st.toast(f"Cluster Mode Switched to {mode}", icon="🚀")

# --- UI LAYOUT ---
st.title("🍳 Sentinel: Autonomous SRE Control Plane")

# SIDEBAR: The Chaos Controller
with st.sidebar:
    st.header("🕹️ Chaos Controller")
    st.write("Trigger different traffic modes and observe the Agent's ReAct loop.")
    
    if st.button("🟢 STEADY STATE", use_container_width=True):
        send_control_signal("STEADY")
    
    if st.button("🔴 LUNCH RUSH (Chaos)", use_container_width=True):
        send_control_signal("LUNCH_RUSH")
    
    if st.button("⚡ BURST MODE", use_container_width=True):
        send_control_signal("BURST")
    
    st.divider()
    
    st.subheader("⚠️ Active SLO Breaches")
    if not st.session_state.active_alerts:
        st.success("All Stations Healthy")
    for station, alert in st.session_state.active_alerts.items():
        st.error(f"**{station.upper()}**\np95: {alert['p95_prep']}s (Threshold: 8s)")

# MAIN TABS
tab_viz, tab_agent, tab_k8s = st.tabs(["📊 Live Telemetry", "🧠 Agent Reasoning", "☸️ Cluster State"])

with tab_viz:
    if st.session_state.telemetry_history:
        # Convert deque to DataFrame for Plotly
        df = pd.DataFrame(list(st.session_state.telemetry_history))
        
        # Top Metrics Row
        m1, m2, m3 = st.columns(3)
        latest = df.iloc[-1]
        m1.metric("Station", latest['station'].upper())
        m2.metric("p95 Latency", f"{latest['p95_prep']}s")
        m3.metric("Load", f"{latest['order_count']} orders/win")
        
        # THE GRAPH (This is what you're asking for)
        # Plotting p95_prep over time, colored by station
        fig = px.line(
            df, 
            x='timestamp', 
            y='p95_prep', 
            color='station', 
            title="Real-time Station Latency (Source: Redpanda)",
            template="plotly_dark"
        )
        # Add a static red line at the 8s SLO breach point
        fig.add_hline(y=8.0, line_dash="dash", line_color="red", annotation_text="SLO BREACH")
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("🛰️ Waiting for telemetry from Flink/Redpanda... (Ensure Producer is running)")

with tab_agent:
    st.subheader("ReAct Thought Stream")
    st.write("Live internal reasoning from the LangGraph Agent.")
    
    if not st.session_state.agent_log_history:
        st.info("No active remediation traces. System is nominal.")
    
    for log in st.session_state.agent_log_history:
        with st.container():
            st.markdown(f"""
            <div class="agent-thought">
                <div class="trace-meta">
                    TRACE: {log.get('trace_id', 'N/A')} | 
                    ITERATION: {log.get('iteration_count', 0)} | 
                    <span class="node-pill">{log.get('node', 'reasoning')}</span>
                </div>
                <strong>Thought:</strong> {log.get('message', 'Processing logic...')}
                <br><br>
                <small style="color: #00ffcc;">Action Taken: {log.get('action_result', 'Awaiting Action')}</small>
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
            c2.write(f"Replicas: `{d.status.ready_replicas}/{d.spec.replicas}`")
            # Visual health indicator
            health = d.status.ready_replicas / d.spec.replicas if d.spec.replicas > 0 else 0
            c3.progress(health)
    except Exception as e:
        st.warning("K8s API restricted or unavailable. Showing local telemetry only.")

# --- RERUN LOOP ---
# Streamlit reruns the script to update the UI
time.sleep(1) 
st.rerun()
