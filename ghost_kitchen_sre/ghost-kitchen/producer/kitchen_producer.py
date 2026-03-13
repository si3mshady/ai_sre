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
