import json
import time
from collections import deque

import pandas as pd
import streamlit as st
from kafka import KafkaConsumer

st.set_page_config(layout="wide")
st.title("🍳 Agentic Ghost Kitchen Control")

def get_cons(topic: str) -> KafkaConsumer:
    return KafkaConsumer(
        topic,
        bootstrap_servers="redpanda:9092",
        value_deserializer=lambda x: json.loads(x.decode("utf-8")),
        consumer_timeout_ms=100,
    )

order_cons = get_cons("kitchen.orders")
action_cons = get_cons("kitchen.actions")

orders = deque(maxlen=20)
actions = deque(maxlen=20)

ui = st.empty()

while True:
    for m in order_cons:
        orders.appendleft(m.value)
    for m in action_cons:
        actions.appendleft(m.value)

    with ui.container():
        c1, c2 = st.columns(2)
        with c1:
            st.subheader("Live Orders")
            if orders:
                df = pd.DataFrame(orders)
                cols = [c for c in ["order_id", "item", "station"] if c in df.columns]
                if cols:
                    st.table(df[cols])
        with c2:
            st.subheader("🤖 AI Chef Decisions")
            if actions:
                for a in list(actions):
                    st.warning(f"**Alert:** {a.get('alert','')}\n\n**Decision:** {a.get('decision','')}")
    time.sleep(1)
