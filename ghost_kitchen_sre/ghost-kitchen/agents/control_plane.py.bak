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
