# enhanced_producer.py
from kafka import KafkaProducer
import json, time, random

producer = KafkaProducer(
    bootstrap_servers="redpanda:9092",
    value_serializer=lambda v: json.dumps(v).encode()
)

topic = "construction.events"

worker_roles = ["operator", "engineer", "foreman", "laborer"]
zones = ["restricted", "general", "equipment", "material"]
risk_levels = {"restricted": "high", "equipment": "medium", "general": "low", "material": "medium"}

# Keep track of previous events for correlation
worker_last_zone = {}

while True:
    worker_id = "worker-" + str(random.randint(1, 5))
    zone = random.choice(zones)
    role = random.choice(worker_roles)
    risk = risk_levels[zone]

    previous_zone = worker_last_zone.get(worker_id, None)
    worker_last_zone[worker_id] = zone

    event = {
        "worker": worker_id,
        "role": role,
        "event": "entered_zone",
        "zone": zone,
        "risk_level": risk,
        "previous_zone": previous_zone,
        "timestamp": time.time()
    }

    producer.send(topic, event)
    print("event sent:", event)
    time.sleep(2)
