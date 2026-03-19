# Ghost Kitchen Service Level Objectives (SLO) & Runbook

## Latency Targets
* **Order Creation (p90):** Must be < 2 seconds.
* **Kitchen Ticket Generation (p95):** Must be < 5 seconds.
* **Delivery Dispatch (p99):** Must be < 10 seconds.

## SLO Breach Protocols
1. **P90 Latency Breach (> 2s):** - Automated Action: Enable "Lite Mode" on the frontend (removes high-res images).
   - Notification: Alert the On-call Engineer via Slack.
2. **P95 Latency Breach (> 8s):**
   - Critical Action: Temporarily pause "Instant Checkout" and force a 5-second queue.
   - Escalation: Notify the Kitchen Operations Manager.
3. **P99 Latency Breach (> 15s):**
   - Emergency Action: Set Ghost Kitchen status to "Busy" on delivery apps to slow incoming traffic.

## Manual Mitigation
If the RAG service detects persistent latencies, the operator should restart the 'order-processor' pod in the upcoming K8s cluster.
