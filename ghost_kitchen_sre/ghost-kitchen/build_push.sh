#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Docker Hub Configuration
# ============================================================
DOCKER_USER="si3mshady"
DOCKER_REPO="aiops"
VERSION="v5"

echo "🏗️  Starting Build & Push Phase for $DOCKER_USER/$DOCKER_REPO:$VERSION"

# Ensure we are in the project root
if [[ ! -d "agents" || ! -d "producer" ]]; then
    echo "❌ Error: Script must be run from the ghost-kitchen root directory."
    exit 1
fi

# ============================================================
# 1. Build Phase
# ============================================================

echo "📦 Building Python-based images..."

# Build Agent (The Control Plane)
echo "--- Building Agent ---"
docker build -t "$DOCKER_USER/$DOCKER_REPO:agent-$VERSION" -f Dockerfile.agent .

# Build Dashboard (The Streamlit UI)
echo "--- Building Dashboard ---"
docker build -t "$DOCKER_USER/$DOCKER_REPO:dashboard-$VERSION" -f Dockerfile.dashboard .

# Build Producer (The Traffic Generator)
echo "--- Building Producer ---"
docker build -t "$DOCKER_USER/$DOCKER_REPO:producer-$VERSION" -f Dockerfile.producer .

# Build Flink (The SLO Monitor - contains custom jars/pip pkgs)
echo "--- Building Flink Custom ---"
docker build -t "$DOCKER_USER/$DOCKER_REPO:flink-$VERSION" -f Dockerfile.flink .

# ============================================================
# 2. Push Phase
# ============================================================

echo "🚀 Pushing to Docker Hub: $DOCKER_USER/$DOCKER_REPO..."

services=("agent" "dashboard" "producer" "flink")

for service in "${services[@]}"; do
    IMAGE_TAG="$DOCKER_USER/$DOCKER_REPO:$service-$VERSION"
    echo "Pushing $IMAGE_TAG..."
    docker push "$IMAGE_TAG"
done

echo "✅ All images successfully pushed to Docker Hub!"
echo "🎯 Repository: https://hub.docker.com/r/$DOCKER_USER/$DOCKER_REPO"
