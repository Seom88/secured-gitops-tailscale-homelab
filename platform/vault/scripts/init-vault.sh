#!/bin/bash
set -e

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Tailscale Auth Configuration
TS_CLIENT_ID="${TS_CLIENT_ID:-ChangeMeSecret}"
TS_CLIENT_SECRET="${TS_CLIENT_SECRET:-ChangeMeSecret}"

echo -e "${BLUE}  [Vault] Starting configuration...${NC}"

# 1. Wait for Vault pod
echo -ne "${YELLOW}  [Vault] Waiting for pod to be ready...${NC}"
until kubectl get pod -n vault -l app.kubernetes.io/name=vault,component=server -o name | grep "pod/" > /dev/null 2>&1; do echo -n "."; sleep 5; done
VAULT_POD=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault,component=server -o jsonpath="{.items[0].metadata.name}")
RELEASE_NAME=$(kubectl get pod $VAULT_POD -n vault -o jsonpath="{.metadata.labels['app\.kubernetes\.io/instance']}")
SECRET_NAME="$RELEASE_NAME-unseal-keys"

kubectl wait --for=condition=Ready pod/$VAULT_POD -n vault --timeout=300s > /dev/null 2>&1
echo -e " ${GREEN}Ready! ($VAULT_POD)${NC}"

# Helpers for vault exec
VAULT_EXEC="kubectl exec -i -n vault $VAULT_POD -- env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault"

# 2. Initialization
STATUS=$($VAULT_EXEC status -format=json -tls-server-name=vault 2>/dev/null || echo "{\"initialized\":false}")
if echo "$STATUS" | jq -r '.initialized' | grep -q "false"; then
    echo -e "${BLUE}  [Vault] Initializing...${NC}"
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
      --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
    
    echo -e "${GREEN}  [Vault] Initialized and keys saved to $SECRET_NAME${NC}"
fi

# 3. Unseal
SEALED=$( $VAULT_EXEC status -format=json -tls-server-name=vault 2>/dev/null | jq -r '.sealed' || echo "true" )
if [ "$SEALED" == "true" ]; then
    echo -e "${YELLOW}  [Vault] Unsealing using $SECRET_NAME...${NC}"
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key1}' | base64 -d) > /dev/null 2>&1
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key2}' | base64 -d) > /dev/null 2>&1
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key3}' | base64 -d) > /dev/null 2>&1
    echo -e "${GREEN}  [Vault] Unsealed!${NC}"
fi

# 4. Configure Vault
ROOT_TOKEN=$(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.root-token}' | base64 -d)
VAULT_EXEC_AUTH="kubectl exec -i -n vault $VAULT_POD -- env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault"

# Helper for idempotency
vault_auth_write() {
    local path=$1
    shift
    echo -e "${YELLOW}  [Vault] Configuring $path...${NC}"
    $VAULT_EXEC_AUTH write -tls-server-name=vault "$path" "$@" > /dev/null 2>&1
}

echo -e "${BLUE}  [Vault] Configuring engines and auth...${NC}"
$VAULT_EXEC_AUTH secrets list -tls-server-name=vault | grep -q "secret/" || \
  $VAULT_EXEC_AUTH secrets enable -path=secret -tls-server-name=vault kv-v2 > /dev/null 2>&1

$VAULT_EXEC_AUTH auth list -tls-server-name=vault | grep -q "kubernetes/" || \
  $VAULT_EXEC_AUTH auth enable -tls-server-name=vault kubernetes > /dev/null 2>&1

K8S_ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
K8S_CA=$(kubectl exec -n vault $VAULT_POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

vault_auth_write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert="$K8S_CA" \
    issuer="$K8S_ISSUER"

# Policies and Roles
echo -e "${YELLOW}  [Vault] Writing policies...${NC}"
$VAULT_EXEC_AUTH policy write -tls-server-name=vault tailscale-policy - > /dev/null 2>&1 <<EOF
path "secret/data/tailscale/*" {
  capabilities = ["read"]
}
EOF

$VAULT_EXEC_AUTH policy write -tls-server-name=vault monitoring-policy - > /dev/null 2>&1 <<EOF
path "secret/data/grafana/*" {
  capabilities = ["read"]
}
EOF

vault_auth_write auth/kubernetes/role/eso-tailscale-role \
    bound_service_account_names=eso-external-secrets,eso-dev-external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=tailscale-policy,monitoring-policy \
    ttl=24h

# 5. Seed secrets
echo -e "${BLUE}  [Vault] Seeding secrets...${NC}"

# Function to safely patch or create KV secrets
seed_kv_secret() {
    local path=$1
    shift
    # Check if secret exists
    if $VAULT_EXEC_AUTH kv get -tls-server-name=vault "$path" > /dev/null 2>&1; then
        echo -e "${GREEN}  [Vault] Secret already exists at $path, skipping generation.${NC}"
        # echo -e "${YELLOW}  [Vault] Patching existing secret: $path${NC}"
        # $VAULT_EXEC_AUTH kv patch -tls-server-name=vault "$path" "$@" > /dev/null 2>&1
    else
        echo -e "${YELLOW}  [Vault] Creating new secret: $path${NC}"
        $VAULT_EXEC_AUTH kv put -tls-server-name=vault "$path" "$@" > /dev/null 2>&1
    fi
}

generate_kv_secret_if_missing() {
    local path=$1
    local key=$2
    local bytes=${3:-24}
    shift 3
    
    if $VAULT_EXEC_AUTH kv get -tls-server-name=vault "$path" > /dev/null 2>&1; then
        echo -e "${GREEN}  [Vault] Secret already exists at $path, skipping generation.${NC}"
    else
        echo -e "${YELLOW}  [Vault] Generating random value for $path ($key)...${NC}"
        # Use Vault's random generator (write/POST is the correct method for this endpoint)
        local RANDOM_VAL
        RANDOM_VAL=$($VAULT_EXEC_AUTH write -tls-server-name=vault -format=json sys/tools/random bytes=$bytes | jq -r .data.random_bytes)
        $VAULT_EXEC_AUTH kv put -tls-server-name=vault "$path" "$key"="$RANDOM_VAL" "$@" > /dev/null 2>&1
    fi
}

seed_kv_secret secret/tailscale/auth \
    client_id="$TS_CLIENT_ID" \
    client_secret="$TS_CLIENT_SECRET"

# Generate random password for Grafana and include default user
generate_kv_secret_if_missing secret/grafana/admin password 32 "user=admin"

echo -e "${GREEN}  [Vault] Configuration complete!${NC}"
