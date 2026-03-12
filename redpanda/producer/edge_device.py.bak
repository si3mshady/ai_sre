from kafka import KafkaProducer
import json,time,random

producer=KafkaProducer(
 bootstrap_servers="redpanda:9092",
 value_serializer=lambda v: json.dumps(v).encode()
)

topic="construction.events"

while True:

 event={
  "worker":"worker-"+str(random.randint(1,5)),
  "event":"entered_zone",
  "zone":"restricted",
  "timestamp":time.time()
 }

 producer.send(topic,event)

 print("event sent",event)

 time.sleep(3)
