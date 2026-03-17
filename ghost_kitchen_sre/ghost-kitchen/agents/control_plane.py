import json, os, time, logging
from typing import TypedDict, Dict, Any, List
from kafka import KafkaConsumer, KafkaProducer
from langgraph.graph import StateGraph, END
from langchain_ollama import OllamaLLM
from kubernetes import client, config

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SRE-Control-Plane")

class ControlState(TypedDict):
    alert: Dict[str, Any]
    slo_metrics: Dict[str, Any]
    k8s_events: List[str]
    policy_decision: str
    action_plan: str
    suggested_value: int # Added to capture Flink's scaling suggestion

def get_k8s():
    try: config.load_incluster_config()
    except: config.load_kube_config()
    return client.CoreV1Api()

def get_llm():
    return OllamaLLM(
            model="llama3:latest", 
        base_url="http://ollama:11434", 
        temperature=0.1,
        timeout=300
    )

# --- NODES ---
def context_fetcher(state: ControlState) -> ControlState:
    core = get_k8s()
    try:
        # Pulling recent namespace events for LLM reasoning
        events = core.list_namespaced_event("kitchen-sre", limit=5)
        state["k8s_events"] = [f"{e.reason}: {e.message}" for e in events.items]
    except: 
        state["k8s_events"] = ["No K8s events found."]
    return state

def policy_engine(state: ControlState) -> ControlState:
    # We ask the LLM to validate if the scaling suggested by Flink makes sense
    prompt = f"""[SRE Agent] 
    Station: {state['alert']['station']}
    Metrics: {state['slo_metrics']} 
    Cluster Context: {state['k8s_events']}
    Flink Suggestion: Scale to {state['alert'].get('suggested_replicas', 'N/A')}
    
    Decide: SCALE or KILL_POD. 
    If metrics show high latency but events show no errors, choose SCALE.
    Return ONLY the word."""
    
    try:
        logger.info(f"🧠 Agent analyzing {state['alert']['station']}...")
        decision = get_llm().invoke(prompt).strip().upper()
        state["policy_decision"] = next((p for p in ["SCALE", "KILL_POD"] if p in decision), "SCALE")
    except Exception as e:
        logger.error(f"LLM Error: {e}")
        state["policy_decision"] = "SCALE"
    return state

def action_proposer(state: ControlState) -> ControlState:
    # Instead of executing, we build the proposal for the dashboard
    policy = state["policy_decision"]
    target = f"{state['alert']['station']}-station"
    
    if policy == "SCALE":
        state["action_plan"] = f"Proposing scale-out of {target} to {state['alert'].get('suggested_replicas', 2)} replicas."
    elif policy == "KILL_POD":
        state["action_plan"] = f"Proposing pod termination for {target} due to suspected process hang."
    
    logger.info(f"📝 Proposal Ready: {state['policy_decision']}")
    return state

# --- GRAPH ---
workflow = StateGraph(ControlState)
workflow.add_node("context", context_fetcher)
workflow.add_node("policy", policy_engine)
workflow.add_node("propose", action_proposer)

workflow.add_edge("context", "policy")
workflow.add_edge("policy", "propose")
workflow.add_edge("propose", END)
workflow.set_entry_point("context")
agent_app = workflow.compile()

def main():
    bootstrap = os.getenv("BOOTSTRAP_SERVERS", "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092")
    consumer = KafkaConsumer(
        't1_kitchen.alerts', 
        bootstrap_servers=bootstrap, 
        group_id="sre-agent-group",
        value_deserializer=lambda x: json.loads(x.decode('utf-8'))
    )
    producer = KafkaProducer(
        bootstrap_servers=bootstrap, 
        value_serializer=lambda v: json.dumps(v).encode('utf-8')
    )

    logger.info("🤖 SRE Agent (Llama3) Online - Proposer Mode Active")

    for msg in consumer:
        alert = msg.value
        # Invoke LangGraph to analyze the alert
        res = agent_app.invoke({"alert": alert, "slo_metrics": alert})
        
        # Publish the PENDING action to the dashboard via the actions topic
        proposal = {
            "id": f"agent-act-{int(time.time())}",
            "type": res["policy_decision"],
            "target": f"{alert['station']}-station",
            "value": alert.get('suggested_replicas', 2),
            "reason": res["action_plan"],
            "status": "AWAITING_AUTH", # This triggers the button on the dashboard
            "agent_id": "llama3-brain-v1"
        }
        producer.send('t1_kitchen.actions', proposal)
        logger.info(f"📤 Proposal sent to Dashboard for {alert.get('station')}")

if __name__ == "__main__": 
    main()
