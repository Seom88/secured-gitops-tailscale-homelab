#!/bin/bash
set -euo pipefail

USE_LONGHORN=${USE_LONGHORN:-false}

echo "Infra: Applying changes to the cluster..."

# --- Storage ---
if [ "$USE_LONGHORN" = "true" ]; then
    echo "Pre-creating longhorn-system namespace with PodSecurity labels..."
    kubectl apply -f infra/longhorn/longhorn-namespace.yaml

    echo "Installing Longhorn as default storage..."
    helm repo add longhorn https://charts.longhorn.io --force-update > /dev/null 2>&1
    helm repo update > /dev/null 2>&1
    helm upgrade --install longhorn longhorn/longhorn \
      --version 1.12.0 \
      --namespace longhorn-system \
      --values infra/longhorn/longhorn-values.yaml \
      --timeout 30m

    echo "Waiting for Longhorn to be ready..."

    # 1. Longhorn Manager DaemonSet (created by the chart)
    kubectl rollout status -n longhorn-system daemonset/longhorn-manager --timeout=10m

    # 2. Driver deployer — creates the CSI plugin DaemonSet dynamically
    kubectl rollout status -n longhorn-system deployment/longhorn-driver-deployer --timeout=5m

    # 3. CSI plugin — not in chart, created by driver-deployer after it starts
    echo "Waiting for longhorn-csi-plugin DaemonSet..."
    for i in $(seq 1 30); do
      if kubectl get daemonset longhorn-csi-plugin -n longhorn-system &>/dev/null; then
        kubectl rollout status -n longhorn-system daemonset/longhorn-csi-plugin --timeout=3m
        break
      fi
      sleep 10
    done

    echo "Applying additional Longhorn storage classes..."
    kubectl apply -f infra/longhorn/longhorn-storageclass.yaml
else
    echo "Installing Local Path Provisioner as default storage..."
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
    kubectl label --overwrite ns local-path-storage pod-security.kubernetes.io/enforce=privileged
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

if kubectl get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.io/hostname}' | grep -q "talos"; then
    echo "Environment detected: Talos"
elif kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' | grep -q "+k3s"; then
    # Follow https://docs.k3s.io/upgrades/automated
    echo "Environment detected: K3s"
    echo "Applying system upgrade controller CRDs and controller..."
    kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/crd.yaml \
        -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
    echo "Applying update plan..."
    kubectl apply -f infra/k3s/update/plan-update-k3s.yaml
elif kubectl get nodes -o jsonpath='{.items[0].metadata.labels.minikube\.k8s\.io/name}' | grep -q "minikube"; then
    echo "Environment detected: Minikube"
else
    echo "Unknown environment."
fi

echo "Infra: Cluster setup complete."
