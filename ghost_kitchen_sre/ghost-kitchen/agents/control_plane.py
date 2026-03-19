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
    # FIX: Use the specific metric key that Flink provides and the Runbook expects
    # We default to 'p95_prep' as that is our primary Flink alert anchor
    metric = "p95_prep" 
    value = state["alert"].get("p95_prep", 0.0)
    
    logger.info(f"🔍 Consulting RAG for {metric} with value {value}")
    
    try:
        r = requests.get(RAG_ENDPOINT, params={"metric": metric, "value": value}, timeout=180)
        data = r.json()
        
        # FIX: Aligning keys with your FastAPI response structure
        return {
            "rag_insight": data.get("runbook_instruction", "No runbook instruction returned."),
            "rag_metrics": data.get("factory_metrics", {})
        }
    except Exception as e:
        logger.error(f"RAG Tool Failure: {e}")
        return {
            "rag_insight": "Critical: RAG Service Timeout. Defaulting to safe state.", 
            "rag_metrics": {"error": str(e)}
        }


def analyze_policy(state: ControlState):
    llm = OllamaLLM(model="llama3:latest", base_url=HOST, temperature=0)
    
    prompt = f"""
    Context: {state['rag_insight']}
    Alert: {state['alert']}
    Task: Decide if we should 'SCALE', 'RESTART', or 'IGNORE'.
    Response Format: JSON only: {{"decision": "...", "plan": "...", "replicas": 0}}
    """
    
    try:
        response = llm.invoke(prompt)
        # Robust JSON extraction: Find the first '{' and last '}'
        start = response.find('{')
        end = response.rfind('}') + 1
        if start == -1 or end == 0:
            raise ValueError("No JSON found in LLM response")
            
        json_str = response[start:end]
        parsed = json.loads(json_str)
        
        return {
            "policy_decision": parsed.get("decision", "IGNORE"),
            "action_plan": f"RAG Advised: {state['rag_insight']} | Agent Plan: {parsed.get('plan')}",
            "suggested_value": int(parsed.get("replicas", 2))
        }
    except Exception as e:
        logger.error(f"Policy Engine Parsing Error: {e} | Raw Response: {response}")
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
            auto_offset_reset='latest',
            group_id='sre-control-plane-v1',
            max_poll_interval_ms=300000, # Allow 5 mins of "thinking" time
            session_timeout_ms=30000,    # 30s heartbeat timeout
            heartbeat_interval_ms=10000  # Send heartbeat every 10s
        )
        producer = KafkaProducer(
            bootstrap_servers=BOOTSTRAP,
            value_serializer=lambda v: json.dumps(v).encode('utf-8')
        )
    except Exception as e:
        logger.error(f"Kafka Connection Error: {e}")
        return

    logger.info("🤖 RAG-Augmented Agent Online and Listening for SLO Breaches...")

    for msg in consumer:
        alert = msg.value
        logger.info(f"🚨 Alert Received for {alert.get('station', 'unknown')}")
        
        try:
            res = agent_app.invoke({"alert": alert})
            
            # Package proposal for the Dashboard
            proposal = {
                "id": f"rag-act-{int(time.time())}",
                "type": res["policy_decision"],
                "target": alert.get('station', 'unknown'),
                "value": res["suggested_value"],
                "reason": res["action_plan"],
                "rag_metrics": res.get("rag_metrics", {}),
                "status": "AWAITING_AUTH"
            }
            
            if proposal["type"] != "IGNORE":
                producer.send('t1_kitchen.actions', proposal)
                producer.flush()
                logger.info(f"📤 Action Proposal sent to Dashboard for {proposal['target']}")
            else:
                logger.info("ℹ️ Agent decided to IGNORE this alert based on policy.")
                
        except Exception as e:
            logger.error(f"Workflow Execution Error: {e}")

if __name__ == "__main__":
    run_agent()
