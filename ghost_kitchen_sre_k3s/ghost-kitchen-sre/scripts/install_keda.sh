#!/usr/bin/env bash
set -euo pipefail

KEDA_VERSION="2.13.0" # Stable version for 2026

echo "🔍 Checking for Helm..."

if ! command -v helm &> /dev/null; then
    echo "⚠️  Helm not found. Installing Helm via official script..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chod  645 get_helm.sh
    ./get_helm.sh
    rm get_helm.sh
    echo "✅ Helm installed successfully."
else
    echo "✅ Helm is already installed. Proceeding..."
fi

echo "🚀 Installing KEDA..."

# Adding KEDA Helm repo and updating
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# Installing KEDA into the keda namespace
helm install keda kedacore/keda \
    --namespace keda \
    --create-namespace \
    --set watchNamespace=kitchen-sre

echo "⏳ Waiting for KEDA to be ready..."
kubectl wait --for=condition=available --timeout=60s deployment/keda-operator -n keda

echo "✅ KEDA is online and watching the 'kitchen-sre' namespace."
