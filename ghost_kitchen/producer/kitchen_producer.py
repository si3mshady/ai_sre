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
