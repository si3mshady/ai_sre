#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Starting Elite Ghost Kitchen Stack..."

# Start core infra
docker compose up -d redpanda redpanda-console prometheus grafana

echo "⏳ Waiting for Redpanda..."
sleep 20

# Start Ollama & application services
docker compose up -d ollama
echo "⏳ Waiting for Ollama..."
sleep 15

# Pull model inside running Ollama container (no race)
OLLAMA_CONTAINER=$(docker ps --filter "name=ollama" --format "{{.ID}}")
if [[ -n "${OLLAMA_CONTAINER}" ]]; then
  echo "📥 Pulling llama3.1:8b model inside Ollama..."
  docker exec "${OLLAMA_CONTAINER}" ollama pull llama3.1:8b
fi

docker compose up -d kitchen-producer flink-jobmanager flink-taskmanager kitchen-agent dashboard

# Submit Flink job (from /opt/flink, use bin/flink)
echo "🚀 Submitting Flink SLO Monitor job..."
docker exec flink-jobmanager bin/flink run -py /opt/flink/jobs/slo_monitor.py

echo "✅ Elite Stack Ready!"
echo ""
echo "📊 Access Points:"
echo "   Streamlit Dashboard: http://localhost:8501"
echo "   Redpanda Console:    http://localhost:8080" 
echo "   Flink UI:            http://localhost:8081"
echo "   Prometheus:          http://localhost:9090"
echo "   Grafana:             http://localhost:3000 (admin / \$GF_ADMIN_PASSWORD)"
echo ""
echo "📝 Flink job submitted. Check Flink UI for status."
