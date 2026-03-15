import json
import os
import time
from typing import TypedDict, Dict, Any

import logging
import yaml
from kafka import KafkaConsumer, KafkaProducer
from langgraph.graph import StateGraph, END
from langchain_ollama import OllamaLLM

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Simple TypedDict - works on Python 3.10+3.11 (no NotRequired needed)
class ControlState(TypedDict):
    alert: Dict[str, Any]
    slo_metrics: Dict[str, Any]
    policy_decision: str
    action_plan: str
    confidence: float

# Lazy singletons - prevent startup crashes
_config: Dict[str, Any] | None = None
_llm: OllamaLLM | None = None

def get_config() -> Dict[str, Any]:
    global _config
    if _config is None:
        max_retries = 5
        for attempt in range(max_retries):
            try:
                cfg_path = os.getenv("KITCHEN_CONFIG_PATH", "/app/config/tenant1.yaml")
                with open(cfg_path, 'r') as f:
                    _config = yaml.safe_load(f)
                logger.info(f"✅ Config loaded from {cfg_path}")
                return _config
            except FileNotFoundError:
                logger.warning(f"Config not found at {cfg_path}, retry {attempt+1}/{max_retries}")
            except PermissionError:
                logger.error(f"Permission denied on {cfg_path}. Fix: chmod 644 config/*.yaml")
                raise
            except Exception as e:
                logger.error(f"Config load error: {e}, retry {attempt+1}/{max_retries}")
            time.sleep(2 ** attempt)
        raise RuntimeError("Failed to load config after retries")
    return _config

def get_llm() -> OllamaLLM:
    global _llm
    if _llm is None:
        max_retries = 10
        for attempt in range(max_retries):
            try:
                # Test Ollama connectivity first
                import requests
                resp = requests.get("http://ollama:11434/api/tags", timeout=10)
                if resp.status_code != 200:
                    raise RuntimeError(f"Ollama API error: {resp.status_code}")
                
                _llm = OllamaLLM(
                    model="llama3.1:8b",
                    base_url="http://ollama:11434",
                    temperature=0.1,
                    timeout=60
                )
                # Quick healthcheck
                _llm.invoke("OK")
                logger.info("✅ OllamaLLM ready")
                return _llm
            except Exception as e:
                logger.warning(f"Ollama init failed (attempt {attempt+1}/{max_retries}): {e}")
                time.sleep(5)
        raise RuntimeError("OllamaLLM initialization failed after retries")
    return _llm

def policy_engine(state: ControlState) -> ControlState:
    """SRE Policy Engine - maps SLO violations to actions"""
    alert = state.get("alert", {})
    metrics = state.get("slo_metrics", {}) or {
        "avg_prep_time": alert.get("avg_prep_time", 0),
        "p95_prep_time": alert.get("p95_prep_time", 0),
        "order_count": alert.get("order_count", 0),
    }

    prompt = f"""SRE Policy Engine Analysis:
Tenant: {alert.get('tenant_id', 'unknown')}
Station: {alert.get('station', 'unknown')}
Alert: {alert.get('alert_type', 'UNKNOWN')} ({alert.get('severity', 'INFO')})
Metrics: avg_prep={metrics.get('avg_prep_time', 0):.1f}, p95={metrics.get('p95_prep_time', 0):.1f}, orders/min={metrics.get('order_count', 0)}

Choose ONE policy action ONLY (exactly one word): REBALANCE|THROTTLE|SCALE|INVESTIGATE"""

    try:
        llm = get_llm()
        decision = llm.invoke(prompt).strip().upper()
        valid_policies = ['REBALANCE', 'THROTTLE', 'SCALE', 'INVESTIGATE']
        policy = next((p for p in valid_policies if p in decision), 'INVESTIGATE')
        confidence = 0.9 if policy != 'INVESTIGATE' else 0.7
    except Exception as e:
        logger.error(f"LLM policy error: {e}. Defaulting to INVESTIGATE.")
        policy, confidence = 'INVESTIGATE', 0.5

    return {
        "alert": alert,
        "slo_metrics": metrics,
        "policy_decision": policy,
        "confidence": confidence,
    }

def action_generator(state: ControlState) -> ControlState:
    """Generate concrete remediation actions"""
    policy = state["policy_decision"]
    alert = state["alert"]
    station = alert.get("station", "unknown")

    actions = {
        "REBALANCE": f"Redirect 30% {station} orders to grill station",
        "THROTTLE": f"Pause {station} high-prep items (>12m)",
        "SCALE": f"Request 2x capacity for {station}",
        "INVESTIGATE": f"Escalate {station} SLO violation to SRE oncall"
    }

    return {
        "alert": alert,
        "slo_metrics": state["slo_metrics"],
        "policy_decision": policy,
        "action_plan": actions.get(policy, "MONITOR"),
        "confidence": state["confidence"],
    }

# Build graph once at module load
workflow = StateGraph(ControlState)
workflow.add_node("policy_engine", policy_engine)
workflow.add_node("action_generator", action_generator)
workflow.add_edge("policy_engine", "action_generator")
workflow.set_entry_point("policy_engine")
workflow.add_edge("action_generator", END)

app = workflow.compile()

def main():
    """Production main loop with retries"""
    get_config()  # Warm up config
    
    bootstrap_servers = os.getenv("BOOTSTRAP_SERVERS", "redpanda:9092")
    
    consumer = KafkaConsumer(
        't1_kitchen.alerts',
        bootstrap_servers=bootstrap_servers,
        value_deserializer=lambda x: json.loads(x.decode('utf-8')),
        consumer_timeout_ms=5000,
        group_id='control-plane',
        enable_auto_commit=True,
        auto_offset_reset='latest'
    )

    producer = KafkaProducer(
        bootstrap_servers=bootstrap_servers,
        value_serializer=lambda v: json.dumps(v).encode('utf-8'),
        retries=3
    )

    logger.info("🤖 Elite SRE Control Plane Online - waiting for alerts...")
    
    while True:
        try:
            msg_batch = consumer.poll(timeout_ms=10000, max_records=10)
            if not msg_batch:
                logger.debug("No alerts available")
                continue
                
            for topic_partition, messages in msg_batch.items():
                for msg in messages:
                    alert = msg.value
                    logger.debug(f"Processing alert: {alert.get('station', 'unknown')}")
                    
                    try:
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
                            "policy": result["policy_decision"],
                            "action": result["action_plan"],
                            "confidence": result["confidence"],
                            "timestamp": time.time()
                        }

                        producer.send('t1_kitchen.actions', action)
                        logger.info(f"✅ [{action['station']}] {action['policy']} -> {action['action'][:50]}...")
                        
                    except Exception as e:
                        logger.error(f"Alert processing failed: {e}")
            
            consumer.commit()
        except KeyboardInterrupt:
            logger.info("🛑 Shutting down gracefully...")
            break
        except Exception as e:
            logger.error(f"Main loop error: {e}")
            time.sleep(5)

if __name__ == "__main__":
    main()

