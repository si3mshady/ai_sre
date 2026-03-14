import json
import time
from collections import deque
from datetime import datetime

import pandas as pd
import plotly.express as px
import streamlit as st
from kafka import KafkaConsumer

# --- CONFIGURATION ---
KAFKA_BROKER = "redpanda:9092"
TOPICS = {
    "orders": "t1_kitchen.orders",
    "alerts": "t1_kitchen.alerts",
    "actions": "t1_kitchen.actions"
}

st.set_page_config(layout="wide", page_title="Elite Ghost Kitchen SRE", page_icon="🍳")
st.title("🍳 Elite Ghost Kitchen Control Plane")

# --- PERSISTENT STATE ---
# This ensures data persists when st.rerun() is called
if "data" not in st.session_state:
    st.session_state.data = {
        "orders": deque(maxlen=1000),
        "alerts": deque(maxlen=500),
        "actions": deque(maxlen=200)
    }

@st.cache_resource
def get_consumers():
    """Initialize all Kafka consumers once."""
    consumers = {}
    for key, topic in TOPICS.items():
        consumers[key] = KafkaConsumer(
            topic,
            bootstrap_servers=KAFKA_BROKER,
            value_deserializer=lambda x: json.loads(x.decode('utf-8')),
            consumer_timeout_ms=50, # Fast timeout for UI responsiveness
            auto_offset_reset='latest',
            group_id=f"dashboard-v2-global"
        )
    return consumers

def poll_all_consumers(consumers):
    """Background poll to update all deques at once."""
    for key, consumer in consumers.items():
        # Drain the buffer (max 100 messages per poll to avoid UI lag)
        for _ in range(100):
            try:
                msg = next(consumer)
                st.session_state.data[key].appendleft(msg.value)
            except (StopIteration, Exception):
                break

# --- UI ELEMENTS ---
refresh_interval = st.sidebar.slider("Auto-refresh interval (seconds)", 1, 10, 3)
st.sidebar.info(f"Last updated: {datetime.now().strftime('%H:%M:%S')}")

consumers = get_consumers()
poll_all_consumers(consumers)

tab1, tab2, tab3, tab4 = st.tabs([
    "🔥 Live Orders", 
    "🚨 SLO Alerts", 
    "🤖 AI Decisions", 
    "📊 SLO Dashboard"
])

# Helpers for data access
d_orders = st.session_state.data["orders"]
d_alerts = st.session_state.data["alerts"]
d_actions = st.session_state.data["actions"]

with tab1:
    if d_orders:
        df = pd.DataFrame(d_orders)
        cols = [c for c in ['order_id', 'station', 'item', 'prep_time_required'] if c in df.columns]
        st.dataframe(df[cols].head(50), use_container_width=True)
    else:
        st.write("Waiting for orders...")

with tab2:
    if d_alerts:
        df_alerts = pd.DataFrame(d_alerts)
        cols = [c for c in ['station', 'alert_type', 'severity', 'avg_prep_time', 'p95_prep_time'] if c in df_alerts.columns]
        st.dataframe(df_alerts[cols].head(50), use_container_width=True)
    else:
        st.write("No active alerts.")

with tab3:
    if d_actions:
        df_actions = pd.DataFrame(d_actions)
        cols = [c for c in ['station', 'policy', 'action', 'confidence'] if c in df_actions.columns]
        st.dataframe(df_actions[cols].head(50), use_container_width=True)
    else:
        st.write("No AI decisions logged.")

with tab4:
    if len(d_orders) > 2:
        df_orders = pd.DataFrame(d_orders)
        if 'timestamp' in df_orders.columns:
            # Convert timestamp and handle sorting
            df_orders['dt'] = pd.to_datetime(df_orders['timestamp'], unit='s')
            df_plot = df_orders.sort_values('dt').tail(100)

            # High-level Metrics
            m1, m2 = st.columns(2)
            avg_prep = df_plot['prep_time_required'].mean()
            slo_violation = avg_prep > 10

            m1.metric("Avg Prep Time (Window)", f"{avg_prep:.2f}s", delta="-Higher than 10s!" if slo_violation else "Normal", delta_color="inverse")
            m2.metric("Total Events Tracked", len(d_orders))

            # Visualization
            fig = px.line(
                df_plot,
                x='dt',
                y='prep_time_required',
                color='station',
                title="Real-time Station Performance",
                template="plotly_dark"
            )
            st.plotly_chart(fig, use_container_width=True)

# --- AUTO-REFRESH TRIGGER ---
time.sleep(refresh_interval)
st.rerun()
