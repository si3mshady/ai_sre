from kafka import KafkaConsumer,KafkaProducer
import json,requests

consumer=KafkaConsumer(
 "construction.events",
 bootstrap_servers="redpanda:9092",
 value_deserializer=lambda x: json.loads(x.decode())
)

producer=KafkaProducer(
 bootstrap_servers="redpanda:9092",
 value_serializer=lambda v: json.dumps(v).encode()
)

for msg in consumer:

 event=msg.value

 prompt=f"""
Analyze this construction site event
{event}

Is this a safety issue?
"""

 r=requests.post(
    "http://host.docker.internal:11434/api/generate",
  json={
   "model":"llama3.2:3b",
   "prompt":prompt,
   "stream":False
  }
 )


 data = r.json()
 print("OLLAMA RESPONSE:", data)

 analysis = data.get("response", "No response from model")

 result={
  "event":event,
  "analysis":analysis
 }

 producer.send("construction.analysis",result)

 print("analysis sent")
