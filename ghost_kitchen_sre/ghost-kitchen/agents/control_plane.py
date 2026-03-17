import json, os, time, logging
from typing import TypedDict, Dict, Any, List
from kafka import KafkaConsumer, KafkaProducer
from langgraph.graph import StateGraph, END
from langchain_ollama import OllamaLLM
from kubernetes import client, config

# Logging Configuration
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SRE-Control-Plane")

# Environment Variables
HOST = os.getenv("OLLAMA_HOST", "http://ollama.kitchen-sre.svc.cluster.local:11434")
BOOTSTRAP = os.getenv("BOOTSTRAP_SERVERS", "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092")

# Whitelist of deployments the agent is authorized to manage
ALLOWED_TARGETS = ["kitchen-agent", "kitchen-producer", "kitchen-dashboard"]

class ControlState(TypedDict):
    alert: Dict[str, Any]
    slo_metrics: Dict[str, Any]
    k8s_events: List[str]
    policy_decision: str
    action_plan: str
    suggested_value: int

def get_k8s():
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()
    return client.CoreV1Api()

def get_llm():
    return OllamaLLM(
        model="llama3:latest", 
        base_url=HOST, 
        temperature=0.1,
        timeout=300
    )

# --- NODES ---

def context_fetcher(state: ControlState) -> ControlState:
    """Gathers cluster events to give Llama3 context on potential underlying issues."""
    core = get_k8s()
    try:
        events = core.list_namespaced_event("kitchen-sre", limit=5)
        state["k8s_events"] = [f"{e.reason}: {e.message}" for e in events.items]
    except Exception as e:
        logger.warning(f"Could not fetch K8s events: {e}")
        state["k8s_events"] = ["No K8s events found."]
    return state

def policy_engine(state: ControlState) -> ControlState:
    """Consults Llama3 to validate if the Flink-suggested scaling is appropriate."""
    target = state['alert'].get('station', 'unknown')
    
    # Pre-check: If not in whitelist, skip LLM call to save resources
    if target not in ALLOWED_TARGETS:
        state["policy_decision"] = "IGNORE"
        return state

    prompt = f"""[SRE Agent] 
    Station: {target}
    Metrics: {state['slo_metrics']} 
    Cluster Context: {state['k8s_events']}
    Flink Suggestion: Scale to {state['alert'].get('suggested_replicas', 'N/A')}
    
    Decide: SCALE or KILL_POD. 
    If metrics show high latency but events show no errors, choose SCALE.
    Return ONLY the word."""
    
    try:
        logger.info(f"🧠 Agent analyzing target: {target}...")
        decision = get_llm().invoke(prompt).strip().upper()
        # Fallback logic to ensure we get a valid keyword
        state["policy_decision"] = next((p for p in ["SCALE", "KILL_POD"] if p in decision), "SCALE")
    except Exception as e:
        logger.error(f"LLM Error: {e}")
        state["policy_decision"] = "SCALE" # Fail-safe to Scaling
    return state

def action_proposer(state: ControlState) -> ControlState:
    """Formats the final proposal for the Dashboard actions topic."""
    policy = state["policy_decision"]
    target = state['alert'].get('station', 'unknown')
    
    if policy == "IGNORE":
        state["action_plan"] = f"Skipping: {target} is not in the managed scaling whitelist."
    elif policy == "SCALE":
        state["action_plan"] = f"Proposing scale-out of {target} to {state['alert'].get('suggested_replicas', 2)} replicas."
    elif policy == "KILL_POD":
        state["action_plan"] = f"Proposing pod termination for {target} due to suspected process hang."
    
    logger.info(f"📝 Decision for {target}: {policy}")
    return state

# --- GRAPH CONSTRUCTION ---

workflow = StateGraph(ControlState)
workflow.add_node("context", context_fetcher)
workflow.add_node("policy", policy_engine)
workflow.add_node("propose", action_proposer)

workflow.add_edge("context", "policy")
workflow.add_edge("policy", "propose")
workflow.add_edge("propose", END)
workflow.set_entry_point("context")
agent_app = workflow.compile()

# --- MAIN EXECUTION ---

def main():
    try:
        consumer = KafkaConsumer(
            't1_kitchen.alerts', 
            bootstrap_servers=BOOTSTRAP, 
            group_id="sre-agent-group",
            value_deserializer=lambda x: json.loads(x.decode('utf-8')),
            auto_offset_reset='latest'
        )
        producer = KafkaProducer(
            bootstrap_servers=BOOTSTRAP, 
            value_serializer=lambda v: json.dumps(v).encode('utf-8')
        )
    except Exception as e:
        logger.error(f"Kafka Connection Error: {e}")
        return

    logger.info("🤖 SRE Agent (Llama3) Online - Proposer Mode Active")
    logger.info(f"Targeting Deployments: {ALLOWED_TARGETS}")

    for msg in consumer:
        alert = msg.value
        station = alert.get('station', 'unknown')
        
        # Invoke LangGraph workflow
        res = agent_app.invoke({"alert": alert, "slo_metrics": alert})
        
        # Only publish to the dashboard if the target is managed
        if res["policy_decision"] != "IGNORE":
            proposal = {
                "id": f"agent-act-{int(time.time())}",
                "type": res["policy_decision"],
                "target": station, # EXACT deployment name for K8s API
                "value": alert.get('suggested_replicas', 2),
                "reason": res["action_plan"],
                "status": "AWAITING_AUTH",
                "agent_id": "llama3-brain-v1"
            }
            producer.send('t1_kitchen.actions', proposal)
            producer.flush()
            logger.info(f"📤 Proposal sent to Dashboard for {station}")
        else:
            logger.info(f"⏭️  Ignoring alert for unmanaged station: {station}")

if __name__ == "__main__": 
    main()
