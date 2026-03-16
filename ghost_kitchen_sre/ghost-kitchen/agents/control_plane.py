import json
import os
import time
import logging
from typing import TypedDict, Dict, Any

from kafka import KafkaConsumer, KafkaProducer
from langgraph.graph import StateGraph, END
from langchain_ollama import OllamaLLM
from kubernetes import client, config
from kubernetes.client.rest import ApiException

# Logging Configuration
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SRE-Control-Plane")

class ControlState(TypedDict):
    alert: Dict[str, Any]
    slo_metrics: Dict[str, Any]
    policy_decision: str
    action_plan: str
    confidence: float
    execution_status: str

# Lazy singletons
_llm: OllamaLLM | None = None
_k8s_apps_v1: client.AppsV1Api | None = None

def get_k8s_client() -> client.AppsV1Api:
    """Initialize K8s client with in-cluster config."""
    global _k8s_apps_v1
    if _k8s_apps_v1 is None:
        try:
            config.load_incluster_config()
            _k8s_apps_v1 = client.AppsV1Api()
            logger.info("✅ Kubernetes In-Cluster client initialized")
        except config.ConfigException:
            logger.warning("Local Kubeconfig detected (not in-cluster)")
            config.load_kube_config()
            _k8s_apps_v1 = client.AppsV1Api()
    return _k8s_apps_v1

def get_llm() -> OllamaLLM:
    """Initializes connection to Ollama using the llama3.1:8b model."""
    global _llm
    if _llm is None:
        _llm = OllamaLLM(
            model="llama3.1:8b",
            base_url="http://ollama:11434",
            temperature=0.1,
            timeout=60
        )
        logger.info("✅ OllamaLLM initialized for llama3.1:8b")
    return _llm

# --- LANGGRAPH NODES ---

def policy_engine(state: ControlState) -> ControlState:
    """Node 1: Reasoning - Uses Llama 3 to decide policy based on SLO metrics."""
    alert = state.get("alert", {})
    metrics = state.get("slo_metrics", {})
    
    prompt = f"""[SRE ANALYSIS]
Station: {alert.get('station', 'unknown')}
Metrics: Avg={metrics.get('avg_prep_time')}s, P95={metrics.get('p95_prep_time')}s, Load={metrics.get('order_count')}
Current Alert: {alert.get('alert_type')}

Decide Policy: REBALANCE, THROTTLE, SCALE, or INVESTIGATE. 
Return only the word."""

    try:
        decision = get_llm().invoke(prompt).strip().upper()
        policy = next((p for p in ['REBALANCE', 'THROTTLE', 'SCALE', 'INVESTIGATE'] if p in decision), 'INVESTIGATE')
    except Exception as e:
        logger.error(f"LLM Error: {e}")
        policy = 'INVESTIGATE'

    state["policy_decision"] = policy
    state["confidence"] = 0.9 if policy != "INVESTIGATE" else 0.7
    return state

def action_generator(state: ControlState) -> ControlState:
    """Node 2: Planning - Maps policy to specific remediation intent."""
    policy = state["policy_decision"]
    station = state["alert"].get("station", "unknown")

    actions = {
        "REBALANCE": f"Shift load from {station} to underutilized stations",
        "THROTTLE": f"Limit incoming orders for {station}",
        "SCALE": f"Increase replica count for {station} processing workers",
        "INVESTIGATE": f"Check logs for {station} anomalous latency"
    }
    state["action_plan"] = actions.get(policy, "No action required")
    return state

def k8s_executor(state: ControlState) -> ControlState:
    """Node 3: Execution - Interacts with the K3s API to scale resources."""
    if state["policy_decision"] != "SCALE":
        state["execution_status"] = "SKIPPED (Non-scaling policy)"
        return state

    k8s = get_k8s_client()
    # Target deployment for the ghost kitchen processing logic
    target_deploy = "flink-taskmanager" 
    namespace = "kitchen-sre"

    try:
        # 1. Fetch current scale
        scale = k8s.read_namespaced_deployment_scale(name=target_deploy, namespace=namespace)
        current_replicas = scale.spec.replicas
        new_replicas = current_replicas + 1

        # 2. Safety Cap
        if new_replicas > 10:
            state["execution_status"] = "ABORTED (Max replicas reached)"
            return state

        # 3. Apply Scaling Patch
        scale.spec.replicas = new_replicas
        k8s.patch_namespaced_deployment_scale(name=target_deploy, namespace=namespace, body=scale)
        
        state["execution_status"] = f"SUCCESS (Scaled {current_replicas} -> {new_replicas})"
        logger.info(f"🚀 K8s Auto-Scale: {target_deploy} scaled to {new_replicas}")

    except ApiException as e:
        state["execution_status"] = f"FAILED (K8s API Error: {e.status})"
        logger.error(f"K8s Scaling Failed: {e}")
    
    return state

# --- GRAPH CONSTRUCTION ---
workflow = StateGraph(ControlState)
workflow.add_node("policy_engine", policy_engine)
workflow.add_node("action_generator", action_generator)
workflow.add_node("k8s_executor", k8s_executor)

workflow.add_edge("policy_engine", "action_generator")
workflow.add_edge("action_generator", "k8s_executor")
workflow.add_edge("k8s_executor", END)
workflow.set_entry_point("policy_engine")

agent_app = workflow.compile()

# --- RESILIENT KAFKA STARTUP ---

def get_kafka_clients():
    """Loops until Kafka/Redpanda is reachable to avoid CrashLoopBackOff."""
    bootstrap = os.getenv("BOOTSTRAP_SERVERS", "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092")
    while True:
        try:
            logger.info(f"📡 Connecting to Kafka at {bootstrap}...")
            consumer = KafkaConsumer(
                't1_kitchen.alerts',
                bootstrap_servers=bootstrap,
                value_deserializer=lambda x: json.loads(x.decode('utf-8')),
                group_id='sre-brain-group',
                session_timeout_ms=10000,
                request_timeout_ms=15000
            )
            producer = KafkaProducer(
                bootstrap_servers=bootstrap,
                value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                request_timeout_ms=15000
            )
            return consumer, producer
        except Exception as e:
            logger.error(f"❌ Connection failed: {e}. Retrying in 5s...")
            time.sleep(5)

# --- MAIN LOOP ---
def main():
    consumer, producer = get_kafka_clients()
    logger.info("🤖 Autonomous SRE Agent Online (K3s + LangGraph)")

    for msg in consumer:
        alert = msg.value
        logger.info(f"📩 Alert: {alert.get('station')} | Type: {alert.get('alert_type')}")
        
        try:
            # Execute the LangGraph State Machine
            final_state = agent_app.invoke({
                "alert": alert,
                "slo_metrics": {
                    "avg_prep_time": alert.get('avg_prep_time', 0),
                    "p95_prep_time": alert.get('p95_prep_time', 0),
                    "order_count": alert.get('order_count', 0)
                }
            })

            # Record result to Kafka for the Dashboard
            action_event = {
                **alert,
                "policy": final_state["policy_decision"],
                "action": final_state["action_plan"],
                "execution": final_state.get("execution_status", "N/A"),
                "confidence": final_state["confidence"],
                "agent_id": "Llama3-SRE-Brain",
                "timestamp": time.time()
            }
            producer.send('t1_kitchen.actions', action_event)
            logger.info(f"🏁 Final Policy: {action_event['policy']} | Status: {action_event['execution']}")

        except Exception as e:
            logger.error(f"Critical workflow failure: {e}")

if __name__ == "__main__":
    main()
