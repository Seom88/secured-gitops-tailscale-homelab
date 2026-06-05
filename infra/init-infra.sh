#!/bin/bash

echo "Infra: Applying changes to the cluster..."

if kubectl get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.io/hostname}' | grep -q "talos"; then
    echo "Environment detected: Talos"
    echo "Installing Local Path Provisioner..."
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
    echo "Setting privileged security for Local Path Provisioner..."
    kubectl label --overwrite ns local-path-storage pod-security.kubernetes.io/enforce=privileged
    echo "Patching Local Path Provisioner to be default..."
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
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
