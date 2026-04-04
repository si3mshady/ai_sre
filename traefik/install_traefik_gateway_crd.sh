helm install traefik traefik/traefik   --namespace traefik   --create-namespace   --version 37.3.0   -f traefik.yaml --skip-crds


kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml

~                                              
