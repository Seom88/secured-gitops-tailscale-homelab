#!/bin/bash

echo "Infra: Applying changes to the cluster..."

if kubectl get nodes -o jsonpath='{.items[0].metadata.labels.minikube\.k8s\.io/name}' | grep -q "minikube"; then
    echo "Environment detected: Minikube"
elif kubectl get nodes -o jsonpath='{.items[0].metadata.labels.k3s\.io/hostname}' &>/dev/null; then
    # Follow https://docs.k3s.io/upgrades/automated
    echo "Environment detected: K3s"
    echo "Applying system upgrade controller CRDs and controller..."
    kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/crd.yaml \
        -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
    echo "Applying update plan..."
    kubectl apply -f infra/update/plan-update-k3s.yaml
else
    echo "Unknown environment."
fi

echo "Infra: Cluster setup complete."
