#!/bin/bash
set -e

# ============================================================
# Agentic Ghost Kitchen – One-shot Golden Setup Script
# ============================================================

echo "🏗️  Creating Ghost Kitchen directory structure..."
mkdir -p producer flink_jobs agents dashboard flink_libs

# ------------------------------------------------------------
# 1. Order Producer (Python + kafka-python)
# ------------------------------------------------------------
cat <<'EOF' > producer/kitchen_producer.py
from kafka import KafkaProducer
import json, time, random

producer = KafkaProducer(
    bootstrap_servers="redpanda:9092",
    value_serializer=lambda v: json.dumps(v).encode("utf-8"),
)

STATIONS = ["pizza", "sushi", "grill", "fryer"]
MENU = {
    "pizza": ["Margherita", "Pepperoni", "BBQ Chicken"],
    "sushi": ["Spicy Tuna", "California Roll", "Nigiri Set"],
    "grill": ["Burger", "Steak", "Lamb Chops"],
    "fryer": ["Fries", "Wings", "Calamares"],
}

print("🚀 Starting Ghost Kitchen Producer...")
while True:
    station = random.choice(STATIONS)
    item = random.choice(MENU[station])
    prep_time = random.randint(5, 18)

    order = {
        "order_id": f"ORD-{random.randint(1000, 9999)}",
        "station": station,
        "item": item,
        "prep_time_required": prep_time,
        "timestamp": time.time(),
    }
    producer.send("kitchen.orders", order)
    print(f"🔥 [Order Sent] {item} ({prep_time}m) -> {station}")
    time.sleep(random.uniform(0.5, 1.2))
EOF

# ------------------------------------------------------------
# 2. Flink Job (PyFlink + Kafka connector 3.3.0-1.19)
# ------------------------------------------------------------
cat <<'EOF' > flink_jobs/kitchen_flink.py
import json
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types

def monitor_load(event_json: str):
    try:
        event = json.loads(event_json)
        if event.get("prep_time_required", 0) > 12:
            alert = {
                "alert_type": "STATION_OVERLOAD",
                "station": event.get("station"),
                "reason": f"High load: {event['item']} requires {event['prep_time_required']}m",
                "timestamp": event.get("timestamp"),
            }
            return json.dumps(alert)
    except Exception:
        pass
    return None

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)

    kafka_props = {
        "bootstrap.servers": "redpanda:9092",
        "group.id": "flink-monitor",
    }

    consumer = FlinkKafkaConsumer(
        "kitchen.orders",
        SimpleStringSchema(),
        kafka_props,
    )
    consumer.set_start_from_latest()

    stream = env.add_source(consumer)

    alert_stream = (
        stream
        .map(monitor_load, output_type=Types.STRING())
        .filter(lambda x: x is not None)
    )

    producer = FlinkKafkaProducer(
        topic="kitchen.alerts",
        serialization_schema=SimpleStringSchema(),
        producer_config={"bootstrap.servers": "redpanda:9092"},
    )

    alert_stream.add_sink(producer)
    env.execute("Ghost Kitchen Monitor")

if __name__ == "__main__":
    main()
EOF

# ------------------------------------------------------------
# 3. LangGraph Agent (LangGraph + langchain_ollama)
# ------------------------------------------------------------
cat <<'EOF' > agents/kitchen_agent.py
import json
from typing import TypedDict

from kafka import KafkaConsumer, KafkaProducer
from langgraph.graph import StateGraph, END
from langchain_ollama.llms import OllamaLLM  # latest import path [web:20]

class KitchenState(TypedDict):
    alert: dict
    decision: str

def chef_logic(state: KitchenState):
    alert = state["alert"]
    llm = OllamaLLM(
        model="llama3",           # latest base Llama 3 model you have cached
        base_url="http://ollama:11434",
    )
    prompt = (
        f"STATION OVERLOAD: {alert['reason']}. "
        "As AI Head Chef, pick one: RE-ROUTE, PAUSE MENU, or ADD STAFF. "
        "Answer in under 5 words."
    )
    decision = llm.invoke(prompt)
    if isinstance(decision, str):
        decision_text = decision
    else:
        # In case future versions return message objects
        decision_text = getattr(decision, "content", str(decision))
    return {"decision": decision_text}

workflow = StateGraph(KitchenState)
workflow.add_node("chef", chef_logic)
workflow.set_entry_point("chef")
workflow.add_edge("chef", END)
app = workflow.compile()

consumer = KafkaConsumer(
    "kitchen.alerts",
    bootstrap_servers="redpanda:9092",
    value_deserializer=lambda x: json.loads(x.decode("utf-8")),
    consumer_timeout_ms=1000,
)
producer = KafkaProducer(
    bootstrap_servers="redpanda:9092",
    value_serializer=lambda v: json.dumps(v).encode("utf-8"),
)

print("👨‍🍳 AI Chef Online...")
while True:
    for msg in consumer:
        result = app.invoke({"alert": msg.value})
        action = {
            "alert": msg.value.get("reason", ""),
            "decision": result["decision"],
        }
        producer.send("kitchen.actions", action)
        print(f"✅ Decision: {result['decision']}")
EOF

# ------------------------------------------------------------
# 4. Streamlit Dashboard
# ------------------------------------------------------------
cat <<'EOF' > dashboard/streamlit_app.py
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
EOF

# ------------------------------------------------------------
# 5. Flink Dockerfile with Kafka connector JARs
# ------------------------------------------------------------
cat <<'EOF' > Dockerfile.flink
FROM flink:1.19-scala_2.12

USER root

RUN apt-get update && apt-get install -y python3 python3-pip wget && \
    ln -s /usr/bin/python3 /usr/bin/python && \
    pip3 install --no-cache-dir apache-flink kafka-python && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Kafka connector 3.3.0-1.19 matches Flink 1.19.x [web:12][web:15]
RUN wget -O /opt/flink/lib/flink-connector-kafka-3.3.0-1.19.jar \
    https://repo1.maven.org/maven2/org/apache/flink/flink-connector-kafka/3.3.0-1.19/flink-connector-kafka-3.3.0-1.19.jar && \
    wget -O /opt/flink/lib/kafka-clients-3.5.1.jar \
    https://repo1.maven.org/maven2/org/apache/kafka/kafka-clients/3.5.1/kafka-clients-3.5.1.jar

USER flink
WORKDIR /opt/flink/jobs
EOF

# ------------------------------------------------------------
# 6. Docker Compose – Redpanda, Flink, Ollama, Agent, Dashboard
# ------------------------------------------------------------
cat <<'EOF' > docker-compose.yml
version: "3.9"

networks:
  kitchen-net:

services:
  redpanda:
    image: docker.redpanda.com/redpandadata/redpanda:v25.3.10
    command:
      - redpanda
      - start
      - --mode
      - dev-container
      - --kafka-addr
      - internal://0.0.0.0:9092,external://0.0.0.0:19092
      - --advertise-kafka-addr
      - internal://redpanda:9092,external://localhost:19092
    ports:
      - "19092:19092"
    networks:
      - kitchen-net

  ollama:
    container_name: ollama
    image: ollama/ollama
    command: serve
    ports:
      - "11435:11434"
    volumes:
      - ~/.ollama:/root/.ollama
    networks:
      - kitchen-net
    healthcheck:
      test: ["CMD-SHELL", "ollama list | grep -q 'llama3'"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s

  kitchen-producer:
    image: python:3.11-slim
    volumes:
      - ./producer:/app
    working_dir: /app
    command: >
      sh -c "pip install --no-cache-dir kafka-python &&
             python kitchen_producer.py"
    depends_on:
      - redpanda
    networks:
      - kitchen-net

  flink-jobmanager:
    build:
      context: .
      dockerfile: Dockerfile.flink
    container_name: flink-jobmanager
    command: jobmanager
    ports:
      - "8081:8081"
    environment:
      - JOB_MANAGER_RPC_ADDRESS=flink-jobmanager
    volumes:
      - ./flink_jobs:/opt/flink/jobs
    networks:
      - kitchen-net

  flink-taskmanager:
    build:
      context: .
      dockerfile: Dockerfile.flink
    container_name: flink-taskmanager
    command: taskmanager
    depends_on:
      - flink-jobmanager
    environment:
      - JOB_MANAGER_RPC_ADDRESS=flink-jobmanager
    networks:
      - kitchen-net

  kitchen-agent:
    image: python:3.11-slim
    volumes:
      - ./agents:/app
    working_dir: /app
    command: >
      sh -c "pip install --no-cache-dir kafka-python langgraph langchain-community langchain-ollama &&
             python kitchen_agent.py"
    depends_on:
      ollama:
        condition: service_healthy
      redpanda:
        condition: service_started
    networks:
      - kitchen-net

  dashboard:
    image: python:3.11-slim
    volumes:
      - ./dashboard:/app
    working_dir: /app
    command: >
      sh -c "pip install --no-cache-dir kafka-python streamlit pandas &&
             streamlit run streamlit_app.py --server.port 8501 --server.address 0.0.0.0"
    ports:
      - "8501:8501"
    depends_on:
      - redpanda
    networks:
      - kitchen-net
EOF

echo "✅ Golden Ghost Kitchen setup complete!"
echo "🚀 1) Start stack: docker-compose up -d"
echo "🛠️ 2) Submit Flink job:"
echo "       docker exec -it flink-jobmanager ./bin/flink run -py /opt/flink/jobs/kitchen_flink.py"
echo "📊 3) Open dashboard: http://localhost:8501"
echo "🤖 4) Ensure 'llama3' is pulled in your local Ollama cache before starting (ollama pull llama3)."

