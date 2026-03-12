import streamlit as st
from kafka import KafkaConsumer
import json

st.title("Construction AI Monitoring")

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

analysis_placeholder = st.empty()
flink_placeholder = st.empty()

while True:

    analysis_msg = next(analysis_consumer)
    enriched_msg = next(enriched_consumer)

    analysis = analysis_msg.value
    enriched = enriched_msg.value

    with analysis_placeholder.container():

        st.subheader("AI Event Analysis")

        col1, col2 = st.columns(2)

        with col1:
            st.markdown("### Event")
            st.json(analysis["event"])

        with col2:
            st.markdown("### AI Safety Reasoning")
            st.write(analysis["analysis"])

    with flink_placeholder.container():

        st.subheader("Flink Stream Enrichment")

        st.json(enriched)
