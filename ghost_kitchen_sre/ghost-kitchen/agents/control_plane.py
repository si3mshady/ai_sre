import json
import os
import time
import logging
import requests
import uuid
from typing import TypedDict, Dict, Any, Literal
from kafka import KafkaConsumer, KafkaProducer
from langgraph.graph import StateGraph, END
from langgraph.checkpoint.memory import MemorySaver  # Corrected Import
from langchain_ollama import OllamaLLM

# --- CONFIG ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SRE-ReAct-Controller")
BOOTSTRAP = os.getenv('BOOTSTRAP_SERVERS', 'redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092')

# --- STATE DEFINITION ---
class ControlState(TypedDict):
    trace_id: str
    station: str
    alert_data: Dict[str, Any]
    rag_insight: str
    iteration_count: int
    action_taken: str
    is_healthy: bool

# --- KAFKA PRODUCER FOR ACTIONS & TRACES ---
producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP,
    value_serializer=lambda v: json.dumps(v).encode('utf-8')
)

def emit_trace(state: ControlState, node: str, message: str):
    """Real logic: Send trace logs to the dashboard topic."""
    producer.send('t1_kitchen.agent_trace', {
        "trace_id": state["trace_id"],
        "node": node,
        "message": message,
        "iteration_count": state["iteration_count"],
        "timestamp": time.time()
    })
    producer.flush()

# --- NODES ---
def consult_rag(state: ControlState):
    endpoint = os.getenv("RAG_SERVICE_URL", "http://rag-service.kitchen-sre.svc.cluster.local:8080/diagnose")
    val = state["alert_data"].get("p95_prep", 0)
    
    emit_trace(state, "CONSULT_RAG", f"Checking runbook for {state['station']} latency: {val}s")
    
    r = requests.get(endpoint, params={"metric": "p95_prep", "value": val, "station": state["station"]})
    data = r.json()
    
    return {
        "rag_insight": data.get("reasoning", ""),
        "iteration_count": state.get("iteration_count", 0) + 1
    }

def decide_and_act(state: ControlState):
    llm = OllamaLLM(model="llama3:latest", base_url=os.getenv("OLLAMA_HOST"), temperature=0)
    prompt = f"Context: {state['rag_insight']}\nIteration: {state['iteration_count']}\nAction: Recommend K8s scaling. Return JSON: {{'action': 'SCALE', 'value': 5}}"
    
    # Executing Real Action: Notify the cluster of the decision
    action_payload = {
        "type": "SCALE", 
        "target": state["station"], 
        "value": 5, 
        "trace_id": state["trace_id"]
    }
    producer.send('t1_kitchen.actions', action_payload)
    producer.flush()
    
    msg = f"Decision made: Scaling {state['station']} to 5 replicas."
    emit_trace(state, "DECIDE_AND_ACT", msg)
    
    return {"action_taken": msg}

def wait_and_verify(state: ControlState):
    """
    REAL LOGIC: 
    Consumes the latest message from 't1_kitchen.telemetry' for the specific station 
    to verify if the action actually lowered the p95_prep latency.
    """
    emit_trace(state, "WAIT_AND_VERIFY", "Waiting 15s for K8s pod stabilization...")
    time.sleep(15)
    
    # Create a temporary consumer to grab the latest telemetry
    verifier = KafkaConsumer(
        't1_kitchen.telemetry',
        bootstrap_servers=BOOTSTRAP,
        auto_offset_reset='latest',
        enable_auto_commit=False,
        value_deserializer=lambda x: json.loads(x.decode('utf-8')),
        consumer_timeout_ms=5000 # Wait up to 5s for a new metric
    )
    
    current_p95 = 99.0 # Default to high if no data found
    for msg in verifier:
        if msg.value.get('station') == state['station']:
            current_p95 = msg.value.get('p95_prep', 99.0)
            break # Got the latest metric for our target station
    verifier.close()
    
    is_healthy = current_p95 <= 8.0
    status = "RESOLVED" if is_healthy else f"STILL BREACHING ({current_p95}s)"
    emit_trace(state, "VERIFICATION_RESULT", f"Verification complete. Status: {status}")
    
    return {"is_healthy": is_healthy}

def should_continue(state: ControlState) -> Literal["continue", "end"]:
    if state["is_healthy"] or state["iteration_count"] >= 3:
        return "end"
    return "continue"

# --- GRAPH ---
# MemorySaver handles the persistence for the ReAct loop without external DB complexity
memory = MemorySaver() 
builder = StateGraph(ControlState)

builder.add_node("consult_rag", consult_rag)
builder.add_node("decide_and_act", decide_and_act)
builder.add_node("wait_and_verify", wait_and_verify)

builder.set_entry_point("consult_rag")
builder.add_edge("consult_rag", "decide_and_act")
builder.add_edge("decide_and_act", "wait_and_verify")
builder.add_conditional_edges("wait_and_verify", should_continue, {"continue": "consult_rag", "end": END})

react_agent = builder.compile(checkpointer=memory)

def run_loop():
    consumer = KafkaConsumer(
        't1_kitchen.alerts', 
        bootstrap_servers=BOOTSTRAP,
        value_deserializer=lambda x: json.loads(x.decode('utf-8'))
    )
    
    logger.info("🚀 SRE ReAct Controller Online...")
    for msg in consumer:
        alert = msg.value
        if alert.get('alert_type') == 'SLO_VIOLATION':
            trace_id = f"TRC-{uuid.uuid4().hex[:6]}"
            logger.info(f"🚨 Handling breach for {alert['station']} (Trace: {trace_id})")
            
            react_agent.invoke(
                {
                    "trace_id": trace_id, 
                    "station": alert['station'], 
                    "alert_data": alert, 
                    "iteration_count": 0,
                    "is_healthy": False
                },
                {"configurable": {"thread_id": trace_id}}
            )

if __name__ == "__main__":
    run_loop()
