import streamlit as st
from kafka import KafkaConsumer
import json
import pandas as pd
from collections import deque
import time

st.set_page_config(page_title="Construction AI Monitoring", layout="wide")
st.title("Construction AI Monitoring Dashboard")

# Kafka Consumers
analysis_consumer = KafkaConsumer(
    "construction.analysis",
    bootstrap_servers="redpanda:9092",
    value_deserializer=lambda x: json.loads(x.decode()),
    auto_offset_reset="latest"
)

enriched_consumer = KafkaConsumer(
    "construction.enriched",
    bootstrap_servers="redpanda:9092",
    value_deserializer=lambda x: json.loads(x.decode()),
    auto_offset_reset="latest"
)

raw_consumer = KafkaConsumer(
    "construction.events",
    bootstrap_servers="redpanda:9092",
    value_deserializer=lambda x: json.loads(x.decode()),
    auto_offset_reset="latest"
)

# Deques for recent messages
recent_raw = deque(maxlen=50)
recent_enriched = deque(maxlen=50)
recent_analysis = deque(maxlen=50)

# Placeholder for layout
placeholder = st.empty()

# Main loop
while True:
    # Poll Kafka messages
    try:
        raw_msg = next(raw_consumer)
        recent_raw.appendleft(raw_msg.value)
    except StopIteration:
        pass

    try:
        enriched_msg = next(enriched_consumer)
        recent_enriched.appendleft(enriched_msg.value)
    except StopIteration:
        pass

    try:
        analysis_msg = next(analysis_consumer)
        recent_analysis.appendleft(analysis_msg.value)
    except StopIteration:
        pass

    # Responsive layout: three columns
    with placeholder.container():
        col_raw, col_enriched, col_analysis = st.columns([1, 1, 1])

        with col_raw:
            st.subheader("Original Events")
            if recent_raw:
                df_raw = pd.DataFrame(recent_raw)
                st.dataframe(df_raw, height=600, use_container_width=True)

        with col_enriched:
            st.subheader("Enriched Events")
            if recent_enriched:
                df_enriched = pd.DataFrame(recent_enriched)
                st.dataframe(df_enriched, height=600, use_container_width=True)

        with col_analysis:
            st.subheader("AI Event Analysis")
            if recent_analysis:
                df_analysis = pd.DataFrame(recent_analysis)
                st.dataframe(df_analysis, height=600, use_container_width=True)

    time.sleep(0.5)
