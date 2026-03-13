#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Agentic Ghost Kitchen – Elite SRE Golden Deployment Script
# ============================================================

echo "🏗️  Elite Ghost Kitchen SRE Stack – Initializing..."

# Create project structure
mkdir -p ghost-kitchen/{producer,flink_jobs,agents,dashboard,config,prometheus,grafana,tests}
cd ghost-kitchen

# ------------------------------------------------------------
# Tenant configuration (multi-tenant ready)
# ------------------------------------------------------------
cat <<'EOF' > config/tenant1.yaml
tenant_id: "tenant1"
topic_prefix: "t1_"
stations: 
  - pizza
  - sushi  
  - grill
  - fryer
menu:
  pizza: ["Margherita", "Pepperoni", "BBQ Chicken"]
  sushi: ["Spicy Tuna", "California Roll", "Nigiri Set"]
  grill: ["Burger", "Steak", "Lamb Chops"]
  fryer: ["Fries", "Wings", "Calamares"]
slo_config:
  window_size: 60
  avg_prep_threshold: 10
  p95_prep_threshold: 14
  orders_per_min_threshold: 8
EOF

# ------------------------------------------------------------
# Producer – metrics + tenant config (fixed config path)
# ------------------------------------------------------------
cat <<'EOF' > producer/kitchen_producer.py
import json
import time
import random
import os
import yaml
import logging
import prometheus_client
from kafka import KafkaProducer

from datetime import datetime

# Prometheus metrics
ORDERS_TOTAL = prometheus_client.Counter(
    'kitchen_orders_total',
    'Total orders produced',
    ['station', 'tenant']
)
ORDER_PREP_TIME = prometheus_client.Histogram(
    'kitchen_order_prep_time',
    'Order prep time distribution',
    ['station', 'tenant']
)

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def load_config():
    # match docker-compose mount: ./config:/app/config:ro
    cfg_path = os.getenv("KITCHEN_CONFIG_PATH", "/app/config/tenant1.yaml")
    with open(cfg_path, 'r') as f:
        return yaml.safe_load(f)

config = load_config()
TENANT_ID = config['tenant_id']
TOPIC_PREFIX = config['topic_prefix']
STATIONS = config['stations']
MENU = config['menu']

producer = KafkaProducer(
    bootstrap_servers=os.getenv('BOOTSTRAP_SERVERS', 'redpanda:9092'),
    value_serializer=lambda v: json.dumps(v).encode('utf-8'),
)

# Start Prometheus metrics server
prometheus_client.start_http_server(8000)

print(f"🚀 Starting {TENANT_ID} Kitchen Producer...")
while True:
    station = random.choice(STATIONS)
    item = random.choice(MENU[station])
    prep_time = random.randint(5, 18)

    now_ts = time.time()
    order = {
        'tenant_id': TENANT_ID,
        'order_id': f"ORD-{random.randint(1000,9999)}",
        'station': station,
        'item': item,
        'prep_time_required': prep_time,
        'timestamp': now_ts,  # event-time in seconds
    }

    producer.send(f"{TOPIC_PREFIX}kitchen.orders", order)
    ORDERS_TOTAL.labels(station=station, tenant=TENANT_ID).inc()
    ORDER_PREP_TIME.labels(station=station, tenant=TENANT_ID).observe(prep_time)

    logger.info(f"🔥 [{TENANT_ID}] {item} ({prep_time}m) -> {station}")
    time.sleep(random.uniform(0.5, 1.2))
EOF

# ------------------------------------------------------------
# Flink SLO Monitor – fixed chaining & event-time
# ------------------------------------------------------------
cat <<'EOF' > flink_jobs/slo_monitor.py
import json
import logging
import time

from pyflink.datastream import StreamExecutionEnvironment, TimeCharacteristic
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import TumblingEventTimeWindows
from pyflink.common.time import Time
from pyflink.common.watermark_strategy import WatermarkStrategy

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def parse_order(event_json):
    try:
        return json.loads(event_json)
    except Exception:
        return None

def extract_event_timestamp(event_json, _):
    o = parse_order(event_json)
    if not o:
        return 0
    # event timestamp is in seconds; convert to ms
    return int(o.get("timestamp", 0) * 1000)

def compute_slo_metrics(orders):
    if not orders:
        return None

    prep_times = [o.get('prep_time_required', 0) for o in orders]
    prep_times = [p for p in prep_times if p is not None]

    if not prep_times:
        return None

    avg_prep = sum(prep_times) / len(prep_times)
    sorted_pts = sorted(prep_times)
    idx = int(0.95 * (len(sorted_pts) - 1))
    p95_prep = sorted_pts[idx]

    station = orders[0].get('station')
    tenant = orders[0].get('tenant_id')
    window_start = orders[0].get('timestamp')

    alert = {
        'tenant_id': tenant,
        'station': station,
        'window_start': window_start,
        'avg_prep_time': avg_prep,
        'p95_prep_time': p95_prep,
        'order_count': len(orders),
        'alert_type': 'SLO_VIOLATION' if avg_prep > 10 or p95_prep > 14 or len(orders) > 8 else 'NORMAL',
        'severity': 'CRITICAL' if avg_prep > 12 or p95_prep > 16 else 'WARNING',
        # keep a processing-time timestamp too, but not for watermarks
        'processed_at': time.time(),
    }
    return alert

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)
    env.set_stream_time_characteristic(TimeCharacteristic.EventTime)

    kafka_props = {
        "bootstrap.servers": "redpanda:9092",
        "group.id": "flink-slo-monitor",
    }

    consumer = FlinkKafkaConsumer(
        topics=['t1_kitchen.orders'],
        deserialization_schema=SimpleStringSchema(),
        properties=kafka_props
    )
    consumer.set_start_from_latest()

    stream = env.add_source(consumer)

    watermark_strategy = (
        WatermarkStrategy
        .for_bounded_out_of_orderness(Time.seconds(20))
        .with_timestamp_assigner(extract_event_timestamp)
    )

    # Station-keyed, event-time windows
    keyed_stream = (
        stream
        .assign_timestamps_and_watermarks(watermark_strategy)
        .key_by(lambda x: (parse_order(x) or {}).get('station', 'unknown'))
    )

    # Aggregate into list of orders per window
    def create_accumulator():
        return []

    def add(value, accumulator):
        o = parse_order(value)
        if o:
            accumulator.append(o)
        return accumulator

    def get_result(accumulator):
        return accumulator

    windowed_stream = keyed_stream.window(
        TumblingEventTimeWindows.of(Time.seconds(60))
    ).aggregate(
        add_function=add,
        create_accumulator=create_accumulator,
        get_result=get_result,
        accumulator_type=Types.PICKLED_BYTE_ARRAY(),
        result_type=Types.PICKLED_BYTE_ARRAY(),
    )

    alert_stream = (
        windowed_stream
        .map(
            lambda orders: json.dumps(compute_slo_metrics(orders)) if compute_slo_metrics(orders) else "",
            output_type=Types.STRING()
        )
        .filter(lambda x: x != "")
    )

    producer = FlinkKafkaProducer(
        topic='t1_kitchen.alerts',
        serialization_schema=SimpleStringSchema(),
        producer_config={"bootstrap.servers": "redpanda:9092"}
    )

    alert_stream.add_sink(producer)

    env.execute("Elite Ghost Kitchen SLO Monitor")

if __name__ == "__main__":
    main()
EOF

# ------------------------------------------------------------
# Multi-agent LangGraph control plane – fixed state usage
# ------------------------------------------------------------
cat <<'EOF' > agents/control_plane.py
import json
import os
import yaml
import logging
import time
from typing import TypedDict

from kafka import KafkaConsumer, KafkaProducer
from langgraph.graph import StateGraph, END
from langchain_ollama import OllamaLLM

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class ControlState(TypedDict, total=False):
    alert: dict
    slo_metrics: dict
    policy_decision: str
    action_plan: str
    confidence: float

def load_config():
    cfg_path = os.getenv("KITCHEN_CONFIG_PATH", "/app/config/tenant1.yaml")
    with open(cfg_path, 'r') as f:
        return yaml.safe_load(f)

config = load_config()

llm = OllamaLLM(
    model="llama3.1",
    base_url="http://ollama:11434",
    temperature=0.1
)

def policy_engine(state: ControlState) -> ControlState:
    """SRE Policy Engine - maps SLO violations to desired state"""
    alert = state.get("alert", {})
    metrics = state.get("slo_metrics") or {
        "avg_prep_time": alert.get("avg_prep_time", 0),
        "p95_prep_time": alert.get("p95_prep_time", 0),
        "order_count": alert.get("order_count", 0),
    }

    prompt = f"""
    SRE Policy Engine Analysis:
    Tenant: {alert.get('tenant_id')}
    Station: {alert.get('station')} 
    Alert: {alert.get('alert_type')} ({alert.get('severity')})
    Metrics: avg_prep={metrics.get('avg_prep_time', 0):.1f}, p95={metrics.get('p95_prep_time', 0):.1f}, orders/min={metrics.get('order_count', 0)}
    
    Choose ONE policy action:
    1. REBALANCE - redistribute load to other stations  
    2. THROTTLE - pause high-prep menu items
    3. SCALE - request additional capacity/staff
    4. INVESTIGATE - needs human review
    
    Respond with ONLY the policy name (REBALANCE|THROTTLE|SCALE|INVESTIGATE):
    """

    decision = llm.invoke(prompt).strip().upper()
    valid_policies = ['REBALANCE', 'THROTTLE', 'SCALE', 'INVESTIGATE']
    policy = next((p for p in valid_policies if p in decision), 'INVESTIGATE')

    confidence = 0.9 if policy != 'INVESTIGATE' else 0.7

    return {
        "alert": alert,
        "slo_metrics": metrics,
        "policy_decision": policy,
        "confidence": confidence,
    }

def action_generator(state: ControlState) -> ControlState:
    """Action Generator - translates policy to concrete commands"""
    policy = state.get("policy_decision", "INVESTIGATE")
    alert = state.get("alert", {})
    station = alert.get("station", "unknown")

    actions = {
        "REBALANCE": f"Redirect 30% {station} orders to grill station",
        "THROTTLE": f"Pause {station} high-prep items (>12m)",
        "SCALE": f"Request 2x capacity for {station}",
        "INVESTIGATE": f"Escalate {station} SLO violation to SRE oncall"
    }

    return {
        "alert": alert,
        "slo_metrics": state.get("slo_metrics", {}),
        "policy_decision": policy,
        "action_plan": actions.get(policy, "MONITOR"),
        "confidence": state.get("confidence", 0.7),
    }

# LangGraph workflow
workflow = StateGraph(ControlState)
workflow.add_node("policy_engine", policy_engine)
workflow.add_node("action_generator", action_generator)
workflow.add_edge("policy_engine", "action_generator")
workflow.set_entry_point("policy_engine")
workflow.add_edge("action_generator", END)

app = workflow.compile()

# Kafka consumers/producers
consumer = KafkaConsumer(
    't1_kitchen.alerts',
    bootstrap_servers=os.getenv("BOOTSTRAP_SERVERS", "redpanda:9092"),
    value_deserializer=lambda x: json.loads(x.decode('utf-8')),
    consumer_timeout_ms=1000,
    group_id='control-plane'
)

producer = KafkaProducer(
    bootstrap_servers=os.getenv("BOOTSTRAP_SERVERS", "redpanda:9092"),
    value_serializer=lambda v: json.dumps(v).encode('utf-8')
)

print("🤖 Elite SRE Control Plane Online...")
while True:
    for msg in consumer:
        alert = msg.value
        result = app.invoke({
            "alert": alert,
            "slo_metrics": {
                "avg_prep_time": alert.get('avg_prep_time', 0),
                "p95_prep_time": alert.get('p95_prep_time', 0),
                "order_count": alert.get('order_count', 0)
            }
        })

        action = {
            **alert,
            "policy": result.get("policy_decision"),
            "action": result.get("action_plan"),
            "confidence": result.get("confidence", 0.7),
            "timestamp": time.time()
        }

        producer.send('t1_kitchen.actions', action)
        logger.info(f"✅ [{action.get('station')}] {action.get('policy')} -> {str(action.get('action'))[:50]}...")
EOF

# ------------------------------------------------------------
# Streamlit Dashboard – non-blocking polling
# ------------------------------------------------------------
cat <<'EOF' > dashboard/elite_dashboard.py
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
EOF

# ------------------------------------------------------------
# Prometheus config – fixed scrape targets
# ------------------------------------------------------------
cat <<'EOF' > prometheus/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'kitchen-producer'
    static_configs:
      - targets: ['kitchen-producer:8000']
EOF

# ------------------------------------------------------------
# Flink Dockerfile – no markdown URLs
# ------------------------------------------------------------
cat <<'EOF' > Dockerfile.flink
FROM flink:1.19

USER root
RUN apt-get update && apt-get install -y python3 python3-pip wget && \
    pip3 install kafka-python pyflink && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Kafka connectors
RUN wget -O /opt/flink/lib/flink-connector-kafka-3.3.0-1.19.jar \
    https://repo1.maven.org/maven2/org/apache/flink/flink-connector-kafka/3.3.0-1.19/flink-connector-kafka-3.3.0-1.19.jar && \
    wget -O /opt/flink/lib/kafka-clients-3.5.1.jar \
    https://repo1.maven.org/maven2/org/apache/kafka/kafka-clients/3.5.1/kafka-clients-3.5.1.jar

USER flink
WORKDIR /opt/flink
EOF

# ------------------------------------------------------------
# Docker Compose – fixed volumes, ports, resources
# ------------------------------------------------------------
cat <<'EOF' > docker-compose.yml
version: "3.9"

networks:
  kitchen-net:
    driver: bridge

volumes:
  redpanda_data:
  flink_data:
  grafana_data:
  prometheus_data:
  ollama_data:

services:
  redpanda:
    image: docker.redpanda.com/redpandadata/redpanda:v25.3.10
    command:
      - redpanda start
      - --kafka-addr=internal://0.0.0.0:9092,external://0.0.0.0:19092
      - --advertise-kafka-addr=internal://redpanda:9092,external://localhost:19092
      - --pandaproxy-addr=internal://0.0.0.0:8082,external://0.0.0.0:18082
      - --advertise-pandaproxy-addr=internal://redpanda:8082,external://localhost:18082
      - --mode=dev-container
    ports:
      - "19092:19092"
      - "18082:18082"
      - "9644:9644"
    volumes:
      - redpanda_data:/var/lib/redpanda/data
    networks:
      - kitchen-net
    healthcheck:
      test: ["CMD", "rpk", "cluster", "health"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 1g

  redpanda-console:
    image: docker.redpanda.com/redpandadata/console:latest
    ports:
      - "8080:8080"
    environment:
      CONFIG_FILEPATH: /tmp/config.yml
    depends_on:
      redpanda:
        condition: service_healthy
    networks:
      - kitchen-net

  ollama:
    image: ollama/ollama:latest
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    networks:
      - kitchen-net
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 10s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 2g

  kitchen-producer:
    build: 
      context: .
      dockerfile: Dockerfile.producer
    volumes:
      - ./producer:/app
      - ./config:/app/config:ro
    environment:
      - TENANT_ID=tenant1
      - BOOTSTRAP_SERVERS=redpanda:9092
      - KITCHEN_CONFIG_PATH=/app/config/tenant1.yaml
    depends_on:
      redpanda:
        condition: service_healthy
    networks:
      - kitchen-net
    expose:
      - "8000"
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: 512m

  flink-jobmanager:
    build:
      context: .
      dockerfile: Dockerfile.flink
    ports:
      - "8081:8081"
    volumes:
      - flink_data:/opt/flink/data
      - ./flink_jobs:/opt/flink/jobs:ro
    environment:
      - JOB_MANAGER_RPC_ADDRESS=flink-jobmanager
    networks:
      - kitchen-net
    command: jobmanager

  flink-taskmanager:
    build:
      context: .
      dockerfile: Dockerfile.flink
    depends_on:
      - flink-jobmanager
    environment:
      - JOB_MANAGER_RPC_ADDRESS=flink-jobmanager
    networks:
      - kitchen-net
    command: taskmanager

  kitchen-agent:
    build:
      context: .
      dockerfile: Dockerfile.agent
    volumes:
      - ./agents:/app
      - ./config:/app/config:ro
    environment:
      - BOOTSTRAP_SERVERS=redpanda:9092
      - KITCHEN_CONFIG_PATH=/app/config/tenant1.yaml
    depends_on:
      ollama:
        condition: service_healthy
      redpanda:
        condition: service_healthy
    networks:
      - kitchen-net

  dashboard:
    build:
      context: .
      dockerfile: Dockerfile.dashboard
    ports:
      - "8501:8501"
    volumes:
      - ./dashboard:/app
    depends_on:
      - redpanda
    networks:
      - kitchen-net
    command: streamlit run elite_dashboard.py --server.port 8501 --server.address 0.0.0.0

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus:/etc/prometheus
      - prometheus_data:/prometheus
    ports:
      - "9090:9090"
    networks:
      - kitchen-net

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    # IMPORTANT: set admin password via environment / .env, not hardcoded
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=${GF_ADMIN_PASSWORD:-change_me}
    networks:
      - kitchen-net
EOF

# ------------------------------------------------------------
# Service Dockerfiles
# ------------------------------------------------------------
cat <<'EOF' > Dockerfile.producer
FROM python:3.11-slim
RUN pip install kafka-python pyyaml prometheus-client
WORKDIR /app
COPY producer/*.py ./
EOF

cat <<'EOF' > Dockerfile.agent
FROM python:3.11-slim
RUN pip install kafka-python langgraph langchain-ollama pyyaml
WORKDIR /app
COPY agents/*.py ./
EOF

cat <<'EOF' > Dockerfile.dashboard
FROM python:3.11-slim
RUN pip install streamlit pandas kafka-python plotly
WORKDIR /app
COPY dashboard/*.py ./
EOF

# ------------------------------------------------------------
# Startup script – fixed Flink path & Ollama pull
# ------------------------------------------------------------
cat <<'EOF' > start.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Starting Elite Ghost Kitchen Stack..."

# Start core infra
docker compose up -d redpanda redpanda-console prometheus grafana

echo "⏳ Waiting for Redpanda..."
sleep 20

# Start Ollama & application services
docker compose up -d ollama
echo "⏳ Waiting for Ollama..."
sleep 15

# Pull model inside running Ollama container (no race)
OLLAMA_CONTAINER=$(docker ps --filter "name=ollama" --format "{{.ID}}")
if [[ -n "${OLLAMA_CONTAINER}" ]]; then
  echo "📥 Pulling llama3.1:8b model inside Ollama..."
  docker exec "${OLLAMA_CONTAINER}" ollama pull llama3.1:8b
fi

docker compose up -d kitchen-producer flink-jobmanager flink-taskmanager kitchen-agent dashboard

# Submit Flink job (from /opt/flink, use bin/flink)
echo "🚀 Submitting Flink SLO Monitor job..."
docker exec flink-jobmanager bin/flink run -py /opt/flink/jobs/slo_monitor.py

echo "✅ Elite Stack Ready!"
echo ""
echo "📊 Access Points:"
echo "   Streamlit Dashboard: http://localhost:8501"
echo "   Redpanda Console:    http://localhost:8080" 
echo "   Flink UI:            http://localhost:8081"
echo "   Prometheus:          http://localhost:9090"
echo "   Grafana:             http://localhost:3000 (admin / \$GF_ADMIN_PASSWORD)"
echo ""
echo "📝 Flink job submitted. Check Flink UI for status."
EOF

chmod +x start.sh

echo "✅ Elite Ghost Kitchen SRE Stack Created!"
echo ""
echo "🚀 DEPLOYMENT:"
echo "   ./start.sh"
echo ""
echo "📊 DASHBOARDS:"
echo "   Main:     http://localhost:8501"
echo "   Kafka:    http://localhost:8080" 
echo "   Flink:    http://localhost:8081"
echo "   Grafana:  http://localhost:3000"
echo "   Prometheus: http://localhost:9090"
echo ""
echo "🎯 FEATURES:"
echo "   ✅ Multi-tenant architecture"
echo "   ✅ Windowed SLI/SLO alerting (Flink, event-time)"
echo "   ✅ LangGraph AI control plane"
echo "   ✅ Prometheus + Grafana observability"
echo "   ✅ Production-grade Docker Compose"
echo "   ✅ SRE interview-ready demo"
EOF

