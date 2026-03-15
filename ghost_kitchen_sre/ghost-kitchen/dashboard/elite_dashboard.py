import json
import os
import time
import logging
from collections import deque
from datetime import datetime

import pandas as pd
import plotly.express as px
import streamlit as st
from kafka import KafkaConsumer

# --- LOGGING CONFIGURATION ---
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("Dashboard")

# --- CONFIGURATION ---
KAFKA_BROKER = os.getenv("BOOTSTRAP_SERVERS", "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092")
TOPICS = {
    "orders": "t1_kitchen.orders",
    "alerts": "t1_kitchen.alerts",
    "actions": "t1_kitchen.actions"
}

st.set_page_config(layout="wide", page_title="Elite Ghost Kitchen SRE", page_icon="🍳")
st.title("🍳 Elite Ghost Kitchen Control Plane")

# --- PERSISTENT STATE ---
if "data" not in st.session_state:
    logger.info("Initializing session state deques...")
    st.session_state.data = {
        "orders": deque(maxlen=1000),
        "alerts": deque(maxlen=500),
        "actions": deque(maxlen=200)
    }

@st.cache_resource(show_spinner=False) # Spinner often causes NoSessionContext on hang
def get_consumers():
    """Initialize all Kafka consumers once."""
    logger.info(f"Connecting to Kafka Broker: {KAFKA_BROKER}")
    consumers = {}
    for key, topic in TOPICS.items():
        try:
            logger.info(f"Registering consumer for topic: {topic}")
            consumers[key] = KafkaConsumer(
                topic,
                bootstrap_servers=KAFKA_BROKER,
                value_deserializer=lambda x: json.loads(x.decode('utf-8')),
                consumer_timeout_ms=100,
                auto_offset_reset='latest',
                group_id="dashboard-v3-global",
                session_timeout_ms=10000,
                request_timeout_ms=15000 # Stop it from hanging the UI forever
            )
            logger.info(f"✅ Consumer {key} connected.")
        except Exception as e:
            logger.error(f"❌ Failed to connect to {topic}: {e}")
            st.error(f"Kafka Error ({key}): {e}")
    return consumers

def poll_all_consumers(consumers):
    """Background poll to update all deques at once."""
    counts = {k: 0 for k in TOPICS.keys()}
    for key, consumer in consumers.items():
        try:
            # Poll specifically for messages
            messages = consumer.poll(timeout_ms=50)
            for tp, msgs in messages.items():
                for msg in msgs:
                    st.session_state.data[key].appendleft(msg.value)
                    counts[key] += 1
        except Exception as e:
            logger.error(f"Poll error on {key}: {e}")
            break
    
    if any(counts.values()):
        logger.info(f"Processed: {counts}")

# --- UI ELEMENTS ---
refresh_interval = st.sidebar.slider("Auto-refresh interval (seconds)", 1, 10, 3)
st.sidebar.info(f"Last updated: {datetime.now().strftime('%H:%M:%S')}")

# Execution context
try:
    current_consumers = get_consumers()
    poll_all_consumers(current_consumers)
except Exception as e:
    logger.critical(f"Main loop crash: {e}")
    st.error(f"Critical Dashboard Error: {e}")

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
        df_orders = pd.DataFrame(list(d_orders))
        if 'timestamp' in df_orders.columns:
            df_orders['dt'] = pd.to_datetime(df_orders['timestamp'], unit='s')
            df_plot = df_orders.sort_values('dt').tail(100)

            m1, m2 = st.columns(2)
            avg_prep = df_plot['prep_time_required'].mean()
            slo_violation = avg_prep > 10

            m1.metric("Avg Prep Time (Window)", f"{avg_prep:.2f}s", delta="-HIGH" if slo_violation else "Normal", delta_color="inverse")
            m2.metric("Total Events Tracked", len(d_orders))

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
logger.debug("Rerunning Streamlit UI...")
st.rerun()
