#!/bin/bash

# Define the root directory
PROJECT_ROOT="ghost-kitchen-sre"

echo "🚀 Initializing $PROJECT_ROOT structure..."

# Create core directory tree
mkdir -p $PROJECT_ROOT/{k8s,agents,producer,dashboard,flink_jobs,config,prometheus,scripts}

# Navigate into project root
cd $PROJECT_ROOT

# 1. Kubernetes Manifests (The Orchestration Layer)
touch k8s/kitchen-infra.yaml      # Namespace & PVCs
touch k8s/redpanda-ss.yaml        # StatefulSet for Redpanda
touch k8s/ollama-deploy.yaml      # Deployment + Init Container
touch k8s/agent-rbac.yaml         # RBAC for scaling logic
touch k8s/keda-scaling.yaml       # KEDA ScaledObject
touch k8s/app-deployments.yaml   # Producer, Dashboard, Agent pods

# 2. Application Logic (Python Components)
touch agents/control_plane.py     # The "Brain" (LangGraph + K8s Client)
touch producer/kitchen_producer.py # Event generator
touch dashboard/elite_dashboard.py # Streamlit UI
touch flink_jobs/slo_monitor.py   # PyFlink Streaming logic

# 3. Configuration & Monitoring
touch config/tenant1.yaml         # SRE Policy thresholds
touch prometheus/prometheus.yml    # Scrape configs

# 4. Dockerization
touch Dockerfile.agent
touch Dockerfile.producer
touch Dockerfile.dashboard
touch Dockerfile.flink

# Set permissions for the scripts folder
chmod +x scripts/

echo "✅ Structure created successfully!"
echo "Next step: Move your existing .py files into their respective folders."
