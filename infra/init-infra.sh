#!/bin/bash

CERT_MANAGER_VERSION=v1.17.2

echo "Infra: Applying changes to the cluster..."

# Apply cert-manager Issuer and Certificate
# Install cert-manager
echo "Installing cert-manager..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version $CERT_MANAGER_VERSION \
  --set crds.enabled=true \
  --set global.leaderElection.namespace=cert-manager

# Apply the appropriate storage class based on the detected environment
echo "Installing storageClass..."
if kubectl get nodes -o jsonpath='{.items[0].metadata.labels.minikube\.k8s\.io/name}' | grep -q "minikube"; then
    echo "Environment detected: Minikube"
    kubectl apply -f infra/storage/storage-minikube.yaml
elif kubectl get nodes -o jsonpath='{.items[0].metadata.labels.k3s\.io/hostname}' &>/dev/null; then
    echo "Environment detected: K3s"
    kubectl apply -f infra/storage/storage-k3s.yaml
else
    echo "Unknown environment. No StorageClass applied."
    exit 1
fi

echo "Infra: Cluster setup complete."
