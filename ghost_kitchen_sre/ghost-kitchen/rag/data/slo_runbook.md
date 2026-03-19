# Ghost Kitchen Service Level Objectives (SLO) & Runbook

## Core Latency Metrics & Thresholds
This section defines the technical keys used by Apache Flink and the corresponding SLO targets.

### METRIC: p90_prep (Order Creation)
- **Target**: < 2 seconds
- **Breach Threshold**: > 2 seconds
- **Automated Action**: Enable "Lite Mode" on the frontend to remove high-resolution images and reduce payload size.
- **Notification**: Alert the On-call Engineer via Slack.

### METRIC: p95_prep (Kitchen Ticket Generation)
- **Target**: < 5 seconds
- **Breach Threshold**: > 8 seconds
- **Critical Action**: Temporarily pause "Instant Checkout" and force a 5-second queue for all new incoming orders.
- **Escalation**: Notify the Kitchen Operations Manager.

### METRIC: p99_prep (Delivery Dispatch)
- **Target**: < 10 seconds
- **Breach Threshold**: > 15 seconds
- **Emergency Action**: Set Ghost Kitchen status to "Busy" on external delivery apps to throttle incoming traffic.

## Diagnostic Procedures
If the RAG service detects persistent latencies across any of the metrics above, verify the following:
1. Check for "Chaos Mode" spikes in the `kitchen-producer`.
2. Ensure `redpanda` brokers are not experiencing disk pressure.

## Manual Mitigation
If automated actions fail to stabilize latency within 3 minutes:
- **Restart Command**: `kubectl rollout restart deployment order-processor -n kitchen-sre`
- **Scale Command**: Increase replicas for the impacted station (fryer, sushi, grill).
