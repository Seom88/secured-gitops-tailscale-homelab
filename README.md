# Secured GitOps Homelab

[![Kubernetes](https://img.shields.io/badge/Kubernetes-Talos%20%2F%20K3s-blue?style=for-the-badge&logo=kubernetes)](https://www.talos.dev/)
[![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-orange?style=for-the-badge&logo=argo)](https://argoproj.github.io/cd/)
[![Security](https://img.shields.io/badge/Security-HashiCorp_Vault-blue?style=for-the-badge&logo=vault)](https://www.vaultproject.io/)
[![Network](https://img.shields.io/badge/Network-Tailscale-234E5C?style=for-the-badge&logo=tailscale)](https://tailscale.com/)

Enterprise-grade DevSecOps homelab with GitOps, zero-trust networking, and secrets management — running on Talos (production) and k3d (development).

## 🚀 Overview

Fully automated Kubernetes environment focused on **GitOps principles**, **Zero-Trust networking** via Tailscale, and **Advanced Secret Management** with Vault + External Secrets Operator.

Dual-environment architecture: **Talos** for production, **k3d** for local development — both consuming the same GitOps repo.

## 🏗 Architecture

```mermaid
graph TD
    subgraph "Tailscale Mesh VPN"
        TS[Tailscale Operator]
    end

    subgraph "Talos / K3s Cluster"
        direction TB
        Argo[ArgoCD<br/>App-of-Apps]
        Vault[HashiCorp Vault<br/>3-node Raft]
        ESO[External Secrets<br/>Operator]
        Cert[Cert-Manager]
        Apps[Platform & User Apps]

        Argo -->|sync waves| Cert
        Argo -->|wave 0| ESO
        Argo -->|wave 1| Vault
        Argo -->|wave 2-3| Apps
    end

    User((Admin)) -->|tailscale| TS
    TS -->|secure ingress| Argo
    TS -->|secure ingress| Vault
    TS -->|secure ingress| Apps

    ESO -->|ClusterSecretStore| Vault
    Vault -.->|auto-unseal CronJob| Vault
    Cert -.->|TLS certificates| Vault
```

## 🛡 Key DevSecOps Features

- **GitOps Flow**: ArgoCD manages everything declaratively via App-of-Apps pattern. Bootstrap script goes from bare cluster → fully operational in one shot.
- **Immutable Infrastructure**: Talos Linux for production — no SSH, no package manager, API-only management. k3d for rapid local development with the same GitOps repo.
- **Zero-Trust Networking**: Tailscale operator provides secure ingress without exposing ports — every service gets a `.tailnet` domain.
- **Secrets Management**:
  - HashiCorp Vault (HA, 3-node Raft) with auto-unseal via CronJob
  - External Secrets Operator syncs Vault → native Kubernetes Secrets
  - Per-service ClusterSecretStores for least-privilege access
  - Secrets encryption at rest via KMS
- **Certificate Automation**: cert-manager issues and renews TLS certificates for Vault and cluster services.
- **Observability**: Prometheus + Grafana + Loki stack with Vault-injected credentials.
- **Architecture Decision Records**: ADRs document key decisions and their tradeoffs.

## 🛠 Tech Stack

| Category | Tool | Status |
|----------|------|--------|
| **Orchestration** | Talos (prod) / k3d (dev) | ✅ Dual-env |
| **GitOps** | ArgoCD | ✅ App-of-Apps |
| **Secrets** | Vault (HA Raft) + ESO | ✅ Per-service stores |
| **Networking** | Tailscale Operator | ✅ Ingress templates |
| **Certificates** | cert-manager | ✅ Vault TLS |
| **Monitoring** | Prometheus + Grafana + Loki | 🚧 Ingreses disabled |
| **Storage** | local-path provisioner | ✅ Default |

## 🏁 Getting Started

If you want to replicate or fork this lab:

1. **Fork the Repo** — Follow the [Customization Guide](docs/customization-guide.md) to update repository references.
2. **Choose your infra**:
   - **Production**: Provision Talos nodes ([Talos Guide](https://www.talos.dev/))
   - **Development**: Use `k3d` with `infra/k3d/k3d-config.yaml`
3. **Bootstrap**: Run `bootstrap/01-init-gitops.sh` to deploy ArgoCD → App-of-Apps → Vault → everything.

Bootstrap auto-detects the environment (Talos / K3s / Minikube) and adapts accordingly.

## 📂 Project Structure

```
secured-gitops-tailscale-homelab/
├── bootstrap/                   # One-shot init scripts
│   └── 01-init-gitops.sh        # Bootstraps ArgoCD & points it to this repo
│
├── platform/                    # Platform-level Helm charts
│   ├── argocd/                  # ArgoCD Helm values (HA config, health checks)
│   ├── vault/                   # Vault HA chart + auto-unseal + ESO configs
│   ├── monitoring/              # Prometheus / Grafana / Loki stack
│   ├── tailscale/               # Tailscale operator + ingress templates
│   ├── longhorn/                # (planned) Distributed block storage
│   └── seaweedfs/               # (planned) S3-compatible object storage
│
├── apps/                        # User-facing applications
│   └── template-pod-tailscale/  # Reusable template: deploy + service + ingress
│
├── gitops/                      # Root "App of Apps" Helm chart
│   ├── Chart.yaml               # Meta-chart orchestrating everything
│   ├── values.yaml              # Production values
│   ├── values-dev.yaml          # Dev overrides (branch: dev)
│   └── templates/               # ApplicationSets & root app
│
├── infra/                       # Infrastructure provisioning & configs
│   ├── init-infra.sh            # Node-level setup (auto-detects Talos/K3s)
│   ├── talos/                   # Talos schematic + patches
│   │   ├── schematic.yaml       # System extensions (iscsi, qemu, tailscale)
│   │   └── patches/             # Node role patches (controlplane / worker)
│   ├── k3d/                     # Local dev cluster configs
│   │   ├── k3d-config.yaml      # Base config
│   │   └── k3d-config-longhorn.yaml  # With Longhorn prerequisites
│   ├── update/                  # K3s update automation (System Upgrade Controller)
│
├── docs/                        # Documentation & ADRs
│   ├── getting-started.md       # Full walkthrough
│   ├── k3s-install.md           # Fedora + Tailscale + K3s setup
│   ├── customization-guide.md   # Fork adaptation guide
│   ├── secrets-structure.md     # Vault secret organization
│   └── adrs/                    # Architecture Decision Records
│
└── justfile                     # 20+ dev recipes for cluster management
```

## 📈 Roadmap

### Phase 1 — Foundation ✅
- [X] Bootstrap script: bare cluster → ArgoCD → Vault → apps
- [X] ArgoCD with HA config and custom health probes
- [X] Vault HA (3-node Raft) with TLS + auto-unseal + ESO integration
- [X] Cert-Manager for automated TLS
- [X] External Secrets Operator with per-service ClusterSecretStores
- [X] Tailscale operator with platform ingress templates
- [X] K3s update automation (System Upgrade Controller)
- [X] k3d dev environment with config flavors
- [X] Dual-environment support (Talos + K3s auto-detection)
- [X] Architecture Decision Records

### Phase 2 — Automation & Observability 🚧
- [X] Monitoring stack — Prometheus + Grafana + Loki deployed
- [X] Prometheus / Grafana ingresses enabled via Tailscale
- [ ] Renovate bot

### Phase 3 — Storage & Scale 📋
- [ ] Longhorn — distributed block storage
- [ ] SeaweedFS — S3-compatible object storage
- [ ] Velero — cluster backups to SeaweedFS

### Phase 4 — Hardening & Developer Experience 💡
- [ ] CI/CD Pipeline — GitHub Actions for lint, test, preview
- [ ] Real application deployment (Immich or similar)

---

*Built for learning, security, and automation.*