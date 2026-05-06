#!/bin/bash

ARGOCD_VERSION=9.5.0

# Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd
helm install argocd argo/argo-cd --namespace argocd --version $ARGOCD_VERSION --set global.fullnameOverride=argocd

# Deploy ArgoCD via its own Application manifest (GitOps style)
# ArgoCD will manage its own versioning via platform/argocd/ chart
echo "Initializing ArgoCD via GitOps..."
kubectl apply -f gitops/root-prod-app.yaml

# Wait for ArgoCD to be ready and show initial password
echo "Waiting for ArgoCD to be ready..."
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s 2>/dev/null || true

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "Not ready yet, check logs")
echo "ArgoCD initial admin password: $ARGOCD_PASSWORD"