#!/bin/bash

# Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd
helm upgrade --install argocd platform/argocd/ \
  --namespace argocd \
  -f platform/argocd/values.yaml 

# Wait for ArgoCD deployment to be created
echo "Waiting for ArgoCD deployment to be created..."
for i in $(seq 1 150); do
  if kubectl get deployment/argocd-server -n argocd &>/dev/null; then
    echo "Deployment argocd-server created"
    break
  fi
  sleep 2
done

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD to be ready..."
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s

# Wait for ArgoCD initial admin secret to be created
echo "Waiting for ArgoCD initial admin secret..."
for i in $(seq 1 150); do
  if kubectl -n argocd get secret argocd-initial-admin-secret &>/dev/null; then
    echo "Secret argocd-initial-admin-secret created"
    break
  fi
  sleep 2
done

# Deploy ArgoCD via its own Application manifest (GitOps style)
# ArgoCD will manage its own versioning via platform/argocd/ chart
echo "Initializing ArgoCD via GitOps..."
kubectl apply -f gitops/root-prod-app.yaml

# Extract the initial admin password for ArgoCD
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD initial admin password: $ARGOCD_PASSWORD"