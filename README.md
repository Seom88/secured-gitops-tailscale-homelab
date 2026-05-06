# Argocd Kubernetes Gitops Homelab

## Prerequisites
This homelab is build using k3s (since I only have one node)

- k3s
- kubectl
- helm
- argocd

### k3s install (optional)
    Follow install guide [fedora](https://oneuptime.com/blog/post/2026-03-20-k3s-fedora/view) or official [doc](https://docs.k3s.io/installation/requirements)

## Init Cluster

```bash
./bootstrap/01-vault-init.sh
```

### Access Vault UI

Change credentials to yours

```bash
# Port forward
kubectl port-forward svc/vault -n vault 8200:8200

# Get secret token
kubectl -n vault get secret vault-unseal-keys -o jsonpath="{.data.root-token}" | base64 -d
```

## Install services on k8s

```bash
./bootstrap/02-k8s-init.sh
```

### Access ArgoCD UI

```bash
# Get credential
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

You should have your services exposed on Tailscale
