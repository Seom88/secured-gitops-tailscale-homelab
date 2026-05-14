#!/bin/bash
set -e

# Tailscale Auth Configuration (Required for seeding), 
# IMPORTANT: Do not commit with your credentials!
TS_CLIENT_ID="ChangeMeSecret"
TS_CLIENT_SECRET="ChangeMeSecret"

echo "Vault: Starting configuration..."

# 1. Wait for Vault pod
echo "Waiting for Vault pod to be created..."
until kubectl get pod -n vault -l app.kubernetes.io/name=vault,component=server -o name | grep "pod/"; do sleep 5; done
VAULT_POD=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault,component=server -o jsonpath="{.items[0].metadata.name}")
RELEASE_NAME=$(kubectl get pod $VAULT_POD -n vault -o jsonpath="{.metadata.labels['app\.kubernetes\.io/instance']}")
SECRET_NAME="$RELEASE_NAME-unseal-keys"
echo "Found Vault pod: $VAULT_POD (Release: $RELEASE_NAME)"
kubectl wait --for=condition=Ready pod/$VAULT_POD -n vault --timeout=300s

# Helpers for vault exec
VAULT_EXEC="kubectl exec -i -n vault $VAULT_POD -- env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault"

# 2. Initialization
STATUS=$($VAULT_EXEC status -format=json -tls-server-name=vault 2>/dev/null || echo "{\"initialized\":false}")
if echo "$STATUS" | jq -r '.initialized' | grep -q "false"; then
    echo "Initializing Vault..."
    INIT_OUT=$($VAULT_EXEC operator init -format=json -tls-server-name=vault)
    
    ROOT_TOKEN=$(echo "$INIT_OUT" | jq -r '.root_token')
    KEY1=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[0]')
    KEY2=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[1]')
    KEY3=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[2]')
    KEY4=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[3]')
    KEY5=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[4]')

    kubectl create secret generic "$SECRET_NAME" -n vault \
      --from-literal=root-token="$ROOT_TOKEN" \
      --from-literal=key1="$KEY1" \
      --from-literal=key2="$KEY2" \
      --from-literal=key3="$KEY3" \
      --from-literal=key4="$KEY4" \
      --from-literal=key5="$KEY5" \
      --dry-run=client -o yaml | kubectl apply -f -
    
    echo "Vault initialized and keys saved to secret/$SECRET_NAME"
fi

# 3. Unseal
if $VAULT_EXEC status -format=json -tls-server-name=vault | jq -r '.sealed' | grep -q "true"; then
    echo "Vault is sealed. Unsealing using $SECRET_NAME..."
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key1}' | base64 -d)
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key2}' | base64 -d)
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key3}' | base64 -d)
fi

# 4. Configure Vault
ROOT_TOKEN=$(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.root-token}' | base64 -d)
VAULT_EXEC_AUTH="kubectl exec -i -n vault $VAULT_POD -- env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault"

echo "Ensuring KV-v2 engine is enabled at secret/..."
$VAULT_EXEC_AUTH secrets list -tls-server-name=vault | grep -q "secret/" || \
  $VAULT_EXEC_AUTH secrets enable -path=secret -tls-server-name=vault kv-v2

echo "Ensuring Kubernetes auth is enabled..."
$VAULT_EXEC_AUTH auth list -tls-server-name=vault | grep -q "kubernetes/" || \
  $VAULT_EXEC_AUTH auth enable -tls-server-name=vault kubernetes

echo "Configuring Kubernetes auth..."
K8S_ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
K8S_CA=$(kubectl exec -n vault $VAULT_POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

$VAULT_EXEC_AUTH write -tls-server-name=vault auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert="$K8S_CA" \
    issuer="$K8S_ISSUER"

echo "Updating policies..."
$VAULT_EXEC_AUTH policy write -tls-server-name=vault tailscale-policy - <<EOF
path "secret/data/tailscale/*" {
  capabilities = ["read"]
}
EOF

echo "Updating ESO role..."
$VAULT_EXEC_AUTH write -tls-server-name=vault auth/kubernetes/role/eso-tailscale-role \
    bound_service_account_names=eso-app-external-secrets,eso-app-dev-external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=tailscale-policy \
    ttl=24h

# 5. Seed secrets for Tailscale auth

echo "Seeding Tailscale secrets into Vault..."
$VAULT_EXEC_AUTH kv put -tls-server-name=vault \
    secret/tailscale/auth \
    client_id="$TS_CLIENT_ID" \
    client_secret="$TS_CLIENT_SECRET"

echo "Vault: Configuration complete."
