## Install istio add-ons for version 1.29

mkdir -p istio-addons
curl -L https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/prometheus.yaml -o istio-addons/prometheus.yaml
curl -L https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/grafana.yaml -o istio-addons/grafana.yaml
curl -L https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/kiali.yaml -o istio-addons/kiali.yaml
curl -L https://raw.githubusercontent.com/istio/istio/release-1.29/samples/addons/jaeger.yaml -o istio-addons/jaeger.yaml

kubectl apply -f istio-addons/prometheus.yaml
kubectl apply -f istio-addons/grafana.yaml
kubectl apply -f istio-addons/kiali.yaml
kubectl apply -f istio-addons/jaeger.yaml
