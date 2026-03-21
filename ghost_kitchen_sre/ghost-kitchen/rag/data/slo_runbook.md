# GHOST KITCHEN OPERATIONAL RUNBOOK V2

---
METRIC_NAME: p95_prep
STATION: pizza
SLO_TARGET: 5s
BREACH_THRESHOLD: 8s
SEVERITY: CRITICAL
AUTOMATED_ACTION: SCALE_UP
KUBERNETES_COMMAND: kubectl scale deployment kitchen-station-pizza --replicas=5
NOTIFICATION: Notify Kitchen Ops Manager
---
METRIC_NAME: p95_prep
STATION: fryer
SLO_TARGET: 5s
BREACH_THRESHOLD: 8s
SEVERITY: CRITICAL
AUTOMATED_ACTION: SCALE_UP
KUBERNETES_COMMAND: kubectl scale deployment kitchen-station-fryer --replicas=5
NOTIFICATION: Notify Kitchen Ops Manager
---
METRIC_NAME: p90_prep
STATION: global
SLO_TARGET: 2s
BREACH_THRESHOLD: 2s
SEVERITY: LOW
AUTOMATED_ACTION: LITE_MODE
KUBERNETES_COMMAND: kubectl patch deployment frontend --patch '{"spec": {"template": {"metadata": {"labels": {"mode": "lite"}}}}}'
NOTIFICATION: Slack SRE Alerts
---
METRIC_NAME: p99_prep
STATION: global
SLO_TARGET: 10s
BREACH_THRESHOLD: 15s
SEVERITY: EMERGENCY
AUTOMATED_ACTION: STATUS_BUSY
KUBERNETES_COMMAND: curl -X POST https://api.delivery.com/status/busy
NOTIFICATION: SMS Executive On-Call
---
DIAGNOSTICS_PROTOCOL:
1. IF latency persists after scaling, CHECK Redpanda lag on orders topic.
2. IF Flink checkpoints fail, RESTART Flink job.
3. EMERGENCY RECOVERY: kubectl rollout restart deployment order-processor
