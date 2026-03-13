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
