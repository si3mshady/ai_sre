import json
import time
import random
import os
import logging
from kafka import KafkaProducer

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("Producer")

producer = KafkaProducer(
    bootstrap_servers=os.getenv('BOOTSTRAP_SERVERS', 'redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092'),
    value_serializer=lambda v: json.dumps(v).encode('utf-8'),
)

STATIONS = ["pizza", "sushi", "grill", "fryer"]
MENU = {"pizza": ["Margherita"], "sushi": ["California Roll"], "grill": ["Burger"], "fryer": ["Fries"]}

print("🚀 Starting Kitchen Producer (Chaos Mode Active)...")

while True:
    station = random.choice(STATIONS)
    # Chaos: 10% chance of a "stuck" order with high latency
    is_chaos = random.random() > 0.9
    prep_time = random.randint(25, 45) if is_chaos else random.randint(5, 12)

    order = {
        'tenant_id': "tenant1",
        'order_id': f"ORD-{random.randint(1000,9999)}",
        'station': station,
        'item': random.choice(MENU[station]),
        'prep_time_required': prep_time,
        'timestamp': time.time(),
    }

    producer.send("t1_kitchen.orders", order)
    logger.info(f"🔥 Produced {order['order_id']} for {station} (Prep: {prep_time}s)")
    time.sleep(random.uniform(0.5, 1.0))
