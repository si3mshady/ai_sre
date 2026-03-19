import json, os, time, logging, requests
from typing import TypedDict, Dict, Any, List
from kafka import KafkaConsumer, KafkaProducer
from langgraph.graph import StateGraph, END
from langchain_ollama import OllamaLLM
from kubernetes import client, config

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SRE-Control-Plane")

# --- ENVIRONMENT ---
HOST = os.getenv("OLLAMA_HOST", "http://ollama.kitchen-sre.svc.cluster.local:11434")
BOOTSTRAP = os.getenv("BOOTSTRAP_SERVERS", "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092")
RAG_ENDPOINT = os.getenv("RAG_SERVICE_URL", "http://rag-service.kitchen-sre.svc.cluster.local:8080/diagnose")
ALLOWED_TARGETS = ["kitchen-agent", "kitchen-producer", "kitchen-dashboard"]

class ControlState(TypedDict):
    alert: Dict[str, Any]
    rag_insight: str
    rag_metrics: Dict[str, Any]
    policy_decision: str
    action_plan: str
    suggested_value: int

def call_rag_tool(state: ControlState):
    """Consults the RAG Token Factory for runbook interpretation."""
    metric = state["alert"].get("metric_name", "prep_time")
    value = state["alert"].get("p95_prep", 0.0)
    
    try:
        r = requests.get(RAG_ENDPOINT, params={"metric": metric, "value": value}, timeout=10)
        data = r.json()
        return {
            "rag_insight": data["reasoning"],
            "rag_metrics": data["metrics"]
        }
    except Exception as e:
        logger.error(f"RAG Tool Failure: {e}")
        return {"rag_insight": "Manual override: RAG unavailable.", "rag_metrics": {}}

def analyze_policy(state: ControlState):
    """LangGraph node to decide K8s action based on RAG context."""
    llm = OllamaLLM(model="llama3:latest", base_url=HOST, temperature=0)
    
    prompt = f"""
    Context: {state['rag_insight']}
    Alert: {state['alert']}
    Task: Decide if we should 'SCALE', 'RESTART', or 'IGNORE'.
    Response Format: JSON only: {{"decision": "...", "plan": "...", "replicas": 0}}
    """
    
    try:
        response = llm.invoke(prompt)
        parsed = json.loads(response)
        return {
            "policy_decision": parsed.get("decision", "IGNORE"),
            "action_plan": f"RAG Advised: {state['rag_insight']} | Agent Plan: {parsed.get('plan')}",
            "suggested_value": parsed.get("replicas", 2)
        }
    except:
        return {"policy_decision": "IGNORE", "action_plan": "Fallback: Parse Error", "suggested_value": 1}

# --- GRAPH CONSTRUCTION ---
workflow = StateGraph(ControlState)
workflow.add_node("consult_rag", call_rag_tool)
workflow.add_node("decide_policy", analyze_policy)

workflow.set_entry_point("consult_rag")
workflow.add_edge("consult_rag", "decide_policy")
workflow.add_edge("decide_policy", END)

agent_app = workflow.compile()

def run_agent():
    try:
        consumer = KafkaConsumer(
            't1_kitchen.alerts',
            bootstrap_servers=BOOTSTRAP,
            value_deserializer=lambda x: json.loads(x.decode('utf-8')),
            auto_offset_reset='latest'
        )
        producer = KafkaProducer(
            bootstrap_servers=BOOTSTRAP,
            value_serializer=lambda v: json.dumps(v).encode('utf-8')
        )
    except Exception as e:
        logger.error(f"Connection Error: {e}")
        return

    logger.info("🤖 RAG-Augmented Agent Online")

    for msg in consumer:
        alert = msg.value
        res = agent_app.invoke({"alert": alert})
        
        # Package proposal with RAG reasoning for the Dashboard
        proposal = {
            "id": f"rag-act-{int(time.time())}",
            "type": res["policy_decision"],
            "target": alert.get('station', 'unknown'),
            "value": res["suggested_value"],
            "reason": res["action_plan"], # This now contains the RAG chain
            "rag_metrics": res.get("rag_metrics", {}),
            "status": "AWAITING_AUTH"
        }
        
        if proposal["type"] != "IGNORE":
            producer.send('t1_kitchen.actions', proposal)
            producer.flush()
            logger.info(f"📤 RAG-Backed Proposal sent for {proposal['target']}")

if __name__ == "__main__":
    run_agent()
