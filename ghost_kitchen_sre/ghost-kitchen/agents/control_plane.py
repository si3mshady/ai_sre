import json
import os
import time
import logging
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
    execution_status: str

# Lazy Load K8s
def get_k8s():
    try: config.load_incluster_config()
    except: config.load_kube_config()
    return client.AppsV1Api(), client.CoreV1Api()

def get_llm():
    # UPDATE: Changed model to "llama3" to match your 'ollama list' output.
    # ADDED: timeout=300 because CPU inference is slower than GPU.
    return OllamaLLM(
        model="llama3", 
        base_url="http://ollama:11434", 
        temperature=0.1,
        timeout=300
    )

# --- NODES ---
def context_fetcher(state: ControlState) -> ControlState:
    _, core = get_k8s()
    try:
        # Fetching recent events to give the LLM context on why the SLO might be failing
        events = core.list_namespaced_event("kitchen-sre", limit=5)
        state["k8s_events"] = [f"{e.reason}: {e.message}" for e in events.items]
    except: 
        state["k8s_events"] = ["No K8s events found."]
    return state

def policy_engine(state: ControlState) -> ControlState:
    prompt = f"""[SRE] Analyze: {state['alert']['station']} is violating SLO. 
    Metrics: {state['slo_metrics']} | Cluster Context: {state['k8s_events']}
    Decide: SCALE, RESTART, or KILL_POD. Return ONLY the word."""
    try:
        logger.info(f"🧠 Agent is thinking about {state['alert']['station']}...")
        decision = get_llm().invoke(prompt).strip().upper()
        # Fallback logic to ensure we always get a valid enum
        state["policy_decision"] = next((p for p in ["SCALE", "RESTART", "KILL_POD"] if p in decision), "RESTART")
    except Exception as e:
        logger.error(f"LLM Error: {e}")
        state["policy_decision"] = "RESTART"
    return state

def executor(state: ControlState) -> ControlState:
    apps, core = get_k8s()
    ns, target = "kitchen-sre", "flink-taskmanager"
    policy = state["policy_decision"]
    try:
        if policy == "SCALE":
            s = apps.read_namespaced_deployment_scale(target, ns)
            s.spec.replicas += 1
            apps.patch_namespaced_deployment_scale(target, ns, s)
            state["execution_status"] = f"Scaled to {s.spec.replicas}"
        elif policy == "RESTART":
            body = {"spec": {"template": {"metadata": {"annotations": {"restartedAt": str(time.time())}}}}}
            apps.patch_namespaced_deployment(target, ns, body)
            state["execution_status"] = "Rolling Restart Triggered"
        elif policy == "KILL_POD":
            pods = core.list_namespaced_pod(ns, label_selector=f"app={target}")
            if pods.items:
                core.delete_namespaced_pod(pods.items[0].metadata.name, ns)
                state["execution_status"] = "Stuck pod killed"
    except Exception as e: 
        state["execution_status"] = f"Error: {str(e)}"
    
    logger.info(f"✅ Action Executed: {state['execution_status']}")
    return state

# --- GRAPH ---
workflow = StateGraph(ControlState)
workflow.add_node("context", context_fetcher)
workflow.add_node("policy", policy_engine)
workflow.add_node("exec", executor)

workflow.add_edge("context", "policy")
workflow.add_edge("policy", "exec")
workflow.add_edge("exec", END)
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

    logger.info("🤖 SRE Agent Online & Connected to Kafka")

    for msg in consumer:
        alert = msg.value
        logger.info(f"📩 Received Alert for {alert.get('station')}")
        
        # Invoke LangGraph
        res = agent_app.invoke({"alert": alert, "slo_metrics": alert})
        
        # Publish result to actions topic
        action_result = {
            **alert, 
            "policy": res["policy_decision"], 
            "status": res["execution_status"],
            "agent_id": "llama3-brain-v1"
        }
        producer.send('t1_kitchen.actions', action_result)

if __name__ == "__main__": 
    main()
