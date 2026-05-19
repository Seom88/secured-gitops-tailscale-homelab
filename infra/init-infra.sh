#!/bin/bash

echo "Infra: Applying changes to the cluster..."

# Apply the appropriate storage class based on the detected environment
echo "Installing storageClass..."
if kubectl get nodes -o jsonpath='{.items[0].metadata.labels.minikube\.k8s\.io/name}' | grep -q "minikube"; then
    echo "Environment detected: Minikube"
    # kubectl apply -f infra/storage/storage-minikube.yaml
elif kubectl get nodes -o jsonpath='{.items[0].metadata.labels.k3s\.io/hostname}' &>/dev/null; then
    echo "Environment detected: K3s"
    # kubectl apply -f infra/storage/storage-k3s.yaml
else
    echo "Unknown environment. No StorageClass applied."
    exit 1
fi

echo "Infra: Cluster setup complete."
