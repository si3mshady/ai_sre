#!/usr/bin/env bash

PROFILE="gvisor-cluster"
minikube delete --all
minikube start --profile="$PROFILE" --driver=docker --container-runtime=containerd --cpus=4 --memory=8192
minikube ssh --profile="$PROFILE" "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

sleep 30

minikube addons enable gvisor --profile="$PROFILE"

helm install traefik traefik/traefik   --namespace traefik   --create-namespace   --version 37.3.0   -f ./traefik.yaml --skip-crds


kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml

kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml


helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
