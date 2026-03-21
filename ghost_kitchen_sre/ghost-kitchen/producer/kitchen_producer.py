import json
import time
import random
import os
import logging
from kafka import KafkaProducer, KafkaConsumer
from threading import Thread

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("Traffic-Producer")

# --- SHARED STATE ---
class TrafficController:
    def __init__(self):
        self.mode = "STEADY" # Modes: STEADY, LUNCH_RUSH, BURST
        self.burst_end_time = 0

traffic = TrafficController()

def command_listener():
    """Listens for chaos commands from the dashboard."""
    consumer = KafkaConsumer(
        't1_kitchen.control',
        bootstrap_servers=os.getenv('BOOTSTRAP_SERVERS', 'redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092'),
        value_deserializer=lambda v: json.loads(v.decode('utf-8'))
    )
    for msg in consumer:
        new_mode = msg.value.get("mode")
        if new_mode in ["STEADY", "LUNCH_RUSH", "BURST"]:
            traffic.mode = new_mode
            if new_mode == "BURST":
                traffic.burst_end_time = time.time() + 10 # 10s burst
            logger.info(f"🚦 Traffic Mode switched to: {new_mode}")

# Start Listener Thread
Thread(target=command_listener, daemon=True).start()

producer = KafkaProducer(
    bootstrap_servers=os.getenv('BOOTSTRAP_SERVERS', 'redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092'),
    value_serializer=lambda v: json.dumps(v).encode('utf-8'),
)

STATIONS = ["pizza", "sushi", "grill", "fryer"]
MENU = {"pizza": ["Margherita"], "sushi": ["California Roll"], "grill": ["Burger"], "fryer": ["Fries"]}

logger.info("🚀 Starting Kitchen Producer (Scenario-Based Traffic Active)...")

while True:
    # 1. Determine Timing based on Mode
    if traffic.mode == "LUNCH_RUSH":
        sleep_interval = 0.2
        prep_time = random.randint(10, 25) # Guaranteed Breach
    elif traffic.mode == "BURST":
        if time.time() < traffic.burst_end_time:
            sleep_interval = 0.05
            prep_time = random.randint(5, 10)
        else:
            traffic.mode = "STEADY"
            sleep_interval = 1.0
            prep_time = random.randint(3, 7)
    else: # STEADY
        sleep_interval = 1.0
        prep_time = random.randint(3, 7)

    station = random.choice(STATIONS)
    order = {
        'tenant_id': "tenant1",
        'order_id': f"ORD-{random.randint(1000,9999)}",
        'station': station,
        'item': random.choice(MENU[station]),
        'prep_time_required': prep_time,
        'timestamp': time.time(),
    }

    producer.send("t1_kitchen.orders", order)
    logger.info(f"Produced order for {station} (Mode: {traffic.mode}, Prep: {prep_time}s)")
    time.sleep(sleep_interval)
