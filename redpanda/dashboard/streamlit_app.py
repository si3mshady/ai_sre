import streamlit as st
from kafka import KafkaConsumer
import json

st.title("Construction AI Monitoring")

consumer=KafkaConsumer(
 "construction.analysis",
 bootstrap_servers="redpanda:9092",
 value_deserializer=lambda x: json.loads(x.decode())
)

placeholder=st.empty()

for msg in consumer:

 data=msg.value

 with placeholder.container():

  st.subheader("Latest Event")
  st.json(data["event"])

  st.subheader("AI Analysis")
  st.write(data["analysis"])
