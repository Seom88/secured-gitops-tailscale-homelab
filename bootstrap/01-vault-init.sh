#!/bin/bash -ex

# values
SECRETS_DIR="$HOME/.k8s-secrets"
KEY_FILE="$SECRETS_DIR/tls.key"
CERT_FILE="$SECRETS_DIR/tls.crt"
VAULT_VERSION=0.32.0

# Check if the key and cert files exist, if not generate them
if [ ! -f "$KEY_FILE" ] && [ ! -f "$CERT_FILE" ]; then
  echo "Generate keys on $SECRETS_DIR"
  mkdir -p "$SECRETS_DIR"
  openssl genrsa -out "$KEY_FILE" 4096
  openssl req -x509 -new -nodes \
    -key "$KEY_FILE" \
    -sha256 -days 3650 \
    -out "$CERT_FILE" \
    -subj "/CN=vault.vault.svc"
fi

# Install vault certificates
echo "Generate vault tls key and cert"
kubectl create namespace vault
kubectl create secret generic vault-tls \
  --namespace vault \
  --from-file=tls.key="$KEY_FILE" \
  --from-file=ca.crt="$CERT_FILE" \
  --from-file=tls.crt="$CERT_FILE"

# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install vault
helm install vault hashicorp/vault \
  --namespace vault \
  --version $VAULT_VERSION \
  --set global.fullnameOverride=vault \
  -f platform/vault/values.yaml

# Wait Vault pod to be running (it won't be 'Ready' until unsealed)
echo "Waiting for vault-0 pod to be running..."
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 -n vault --timeout=120s

# Init Vault
INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init \
    -address=https://127.0.0.1:8200 \
    -tls-skip-verify \
    -format=json)

# Extract the unseal keys and root token from the output
KEY1=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[0]')
KEY2=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[1]')
KEY3=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[2]')
KEY4=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[3]')
KEY5=$(echo $INIT_OUTPUT | jq -r '.unseal_keys_b64[4]')
ROOT_TOKEN=$(echo $INIT_OUTPUT | jq -r '.root_token')

# Create a Kubernetes secret to store the unseal keys
kubectl create secret generic vault-unseal-keys \
  --namespace vault \
  --from-literal=root-token="$ROOT_TOKEN" \
  --from-literal=key1="$KEY1" \
  --from-literal=key2="$KEY2" \
  --from-literal=key3="$KEY3" \
  --from-literal=key4="$KEY4" \
  --from-literal=key5="$KEY5"

# Print the root token for you to save in your password manager
echo "⚠️  Save this in your password manager:"
echo "Root Token: $ROOT_TOKEN"
echo "Key 1: $KEY1"
echo "Key 2: $KEY2"
echo "Key 3: $KEY3"
echo "Key 4: $KEY4"
echo "Key 5: $KEY5"

# enter to UI
echo "You should now config secrets, before executing init argoCD"