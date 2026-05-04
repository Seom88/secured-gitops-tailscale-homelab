# Argocd Kubernetes Gitops Homelab

## Prerequisites
This homelab is build using k3s (since I only have one node)

### k3s install
    Follow install guide [fedora](https://oneuptime.com/blog/post/2026-03-20-k3s-fedora/view) or official [doc](https://docs.k3s.io/installation/requirements)

## Install ArgoCD on your Cluster

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd
helm install argocd argo/argo-cd --namespace argocd --version 9.5.0 --set global.fullnameOverride=argocd
```

## Access ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## Retrieve Credentials

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```