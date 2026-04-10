minikube delete --all --purge && sudo rm -f /usr/local/bin/minikube ~/.minikube ~/.kube/config && curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64 && minikube start --driver=docker

