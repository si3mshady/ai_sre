import json
import time
from collections import deque
from datetime import datetime

import pandas as pd
import plotly.express as px
import streamlit as st
from kafka import KafkaConsumer

st.set_page_config(layout="wide", page_title="Elite Ghost Kitchen SRE")
st.title("🍳 Elite Ghost Kitchen Control Plane")

@st.cache_resource
def get_consumer(topic):
    return KafkaConsumer(
        topic,
        bootstrap_servers="redpanda:9092",
        value_deserializer=lambda x: json.loads(x.decode('utf-8')),
        consumer_timeout_ms=100,
        group_id=f"dashboard-{topic}"
    )

orders = deque(maxlen=1000)
alerts = deque(maxlen=500)
actions = deque(maxlen=200)

order_cons = get_consumer("t1_kitchen.orders")
alert_cons = get_consumer("t1_kitchen.alerts")
action_cons = get_consumer("t1_kitchen.actions")

refresh_interval = st.sidebar.slider("Auto-refresh interval (seconds)", 1, 10, 3)

tab1, tab2, tab3, tab4 = st.tabs(
    ["Live Orders", "SLO Alerts", "AI Decisions", "SLO Dashboard"]
)

def poll_consumer(consumer, target_deque, max_messages=200):
    count = 0
    while True:
        try:
            msg = next(consumer)
        except StopIteration:
            break
        target_deque.appendleft(msg.value)
        count += 1
        if count >= max_messages:
            break

with tab1:
    st.subheader("🔥 Live Orders")
    if st.button("Refresh Orders"):
        poll_consumer(order_cons, orders)
    if orders:
        df = pd.DataFrame(orders)
        cols = [c for c in ['order_id', 'station', 'item', 'prep_time_required'] if c in df.columns]
        st.dataframe(df[cols].head(20), use_container_width=True)

with tab2:
    st.subheader("🚨 Real-time SLO Alerts")
    if st.button("Refresh Alerts"):
        poll_consumer(alert_cons, alerts)
    if alerts:
        df_alerts = pd.DataFrame(alerts)
        cols = [c for c in ['station', 'alert_type', 'severity', 'avg_prep_time', 'p95_prep_time'] if c in df_alerts.columns]
        st.dataframe(df_alerts[cols].head(20), use_container_width=True)

with tab3:
    st.subheader("🤖 AI Control Plane Decisions")
    if st.button("Refresh Decisions"):
        poll_consumer(action_cons, actions)
    if actions:
        df_actions = pd.DataFrame(actions)
        cols = [c for c in ['station', 'policy', 'action', 'confidence'] if c in df_actions.columns]
        st.dataframe(df_actions[cols].head(20), use_container_width=True)

with tab4:
    st.subheader("📊 SLO Metrics Dashboard")
    # periodically bring in some orders data
    poll_consumer(order_cons, orders, max_messages=100)

    if len(orders) > 10:
        df_orders = pd.DataFrame(orders)
        if 'timestamp' in df_orders.columns:
            df_orders['timestamp'] = pd.to_datetime(df_orders['timestamp'], unit='s')

            fig = px.line(
                df_orders.sort_values('timestamp').tail(200),
                x='timestamp',
                y='prep_time_required',
                color='station',
                title="Prep Time Over Time"
            )
            st.plotly_chart(fig, use_container_width=True)

            window = df_orders.sort_values('timestamp').tail(50)
            slo_status = window['prep_time_required'].mean() > 10
            st.metric(
                "Current SLO Status",
                "VIOLATING" if slo_status else "HEALTHY",
                delta="SLO breach detected" if slo_status else "All good"
            )

# Simple auto-refresh using Streamlit's rerun pattern
time.sleep(refresh_interval)
st.experimental_rerun()
