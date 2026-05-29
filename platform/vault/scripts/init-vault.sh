#!/bin/bash
set -ex

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Helper functions

# Helper for idempotency
vault_auth_write() {
    local path=$1
    shift
    echo -e "${YELLOW}  [Vault] Configuring $path...${NC}"
    retry $VAULT_EXEC_BASE "$VAULT_POD" -- env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt VAULT_TOKEN="$ROOT_TOKEN" vault write -tls-server-name=vault "$path" "$@" > /dev/null 2>&1
}

# Retry helper
retry() {
    local n=1
    local max=5
    local delay=2
    while true; do
        "$@" && break || {
            if [[ $n -lt $max ]]; then
                ((n++))
                sleep $delay
            else
                return 1
            fi
        }
    done
}

# Silent status check that handles exit code 2 (sealed) without kubectl noise
vault_status() {
    local pod=$1
    $VAULT_EXEC_BASE "$pod" -- /bin/sh -c "env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault status -format=json -tls-server-name=vault || true" 2>/dev/null
}

# General vault exec that silences kubectl "command terminated" noise on stderr
# Usage: vault_exec <pod> <full_command_string>
vault_exec() {
    local pod=$1
    local cmd=$2
    $VAULT_EXEC_BASE "$pod" -- /bin/sh -c "env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt $cmd" 2>/dev/null
}

# Function to safely patch or create KV secrets
seed_kv_secret() {
    local path=$1
    shift
    # Check if secret exists
    if vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault kv get -tls-server-name=vault $path" > /dev/null 2>&1; then
        echo -e "${GREEN}  [Vault] Secret already exists at $path, skipping generation.${NC}"
    else
        echo -e "${YELLOW}  [Vault] Creating new secret: $path${NC}"
        vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault kv put -tls-server-name=vault $path $*" > /dev/null 2>&1
    fi
}

generate_kv_secret_if_missing() {
    local path=$1
    local key=$2
    local bytes=${3:-24}
    shift 3
    
    if vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault kv get -tls-server-name=vault $path" > /dev/null 2>&1; then
        echo -e "${GREEN}  [Vault] Secret already exists at $path, skipping generation.${NC}"
    else
        echo -e "${YELLOW}  [Vault] Generating random value for $path ($key)...${NC}"
        # Use Vault's random generator
        local RANDOM_VAL
        RANDOM_VAL=$(vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault write -tls-server-name=vault -format=json sys/tools/random bytes=$bytes" | jq -r .data.random_bytes)
        vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault kv put -tls-server-name=vault $path $key=$RANDOM_VAL $*" > /dev/null 2>&1
    fi
}

# Tailscale Auth Configuration
TS_CLIENT_ID="${TS_CLIENT_ID:-ChangeMeSecret}"
TS_CLIENT_SECRET="${TS_CLIENT_SECRET:-ChangeMeSecret}"

echo -e "${BLUE}  [Vault] Starting configuration...${NC}"

# 1. Wait for Vault StatefulSet to exist
echo -ne "${YELLOW}  [Vault] Waiting for StatefulSet to be created...${NC}"
until kubectl get statefulset -n vault -l app.kubernetes.io/name=vault -o name | grep "statefulset" > /dev/null 2>&1; do
    echo -n "."
    sleep 2
done
echo -e " ${GREEN}Created!${NC}"

# Wait for all pods to be Running (not Ready — sealed pods won't pass readinessProbe)
echo -ne "${YELLOW}  [Vault] Waiting for all pods to be running...${NC}"
DESIRED_REPLICAS=$(kubectl get statefulset -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo "0")
RETRY_ERRORS=0
MAX_ERRORS=3
while true; do
    if ! RUNNING_OUTPUT=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault,component=server \
        --field-selector=status.phase=Running -o name 2>/dev/null); then
        RETRY_ERRORS=$((RETRY_ERRORS + 1))
        if [ "$RETRY_ERRORS" -ge "$MAX_ERRORS" ]; then
            echo -e "\n${RED}  [Vault] Failed to query pod status after $MAX_ERRORS retries${NC}"
            exit 1
        fi
        sleep 2
        continue
    fi
    RETRY_ERRORS=0
    RUNNING_COUNT=$(echo "$RUNNING_OUTPUT" | grep -c "pod/" || true)
    DESIRED_REPLICAS=$(kubectl get statefulset -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo "0")
    if [ "$RUNNING_COUNT" -eq "$DESIRED_REPLICAS" ] && [ "$DESIRED_REPLICAS" -gt 0 ]; then
        break
    fi
    echo -n "."
    sleep 5
done
echo -e " ${GREEN}All $DESIRED_REPLICAS pods running!${NC}"

VAULT_POD=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault,component=server -o jsonpath="{.items[0].metadata.name}")
RELEASE_NAME=$(kubectl get pod $VAULT_POD -n vault -o jsonpath="{.metadata.labels['app\.kubernetes\.io/instance']}")
SECRET_NAME="$RELEASE_NAME-unseal-keys"

# Helpers for vault exec
VAULT_EXEC_BASE="kubectl exec -i -n vault"

# 2. Initialization
STATUS=$(vault_status "$VAULT_POD")
if echo "$STATUS" | jq -e '.initialized == false' >/dev/null 2>&1; then
    echo -e "${BLUE}  [Vault] Initializing...${NC}"
    # For init we don't silence stderr to see real errors if they happen
    INIT_OUT=$($VAULT_EXEC_BASE "$VAULT_POD" -- /bin/sh -c "env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault operator init -format=json -tls-server-name=vault")
    
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

# 3. Unseal all pods
echo -e "${YELLOW}  [Vault] Checking seal status for all pods...${NC}"
for POD in $(kubectl get pods -n vault -l app.kubernetes.io/name=vault,component=server -o jsonpath='{.items[*].metadata.name}'); do
    echo -ne "${YELLOW}  [Vault] Waiting for pod $POD to be responsive...${NC}"
    until vault_status "$POD" | jq -e '.version' >/dev/null 2>&1; do
        echo -n "."
        sleep 2
    done
    echo -e " ${GREEN}Responsive!${NC}"

    STATUS=$(vault_status "$POD")
    SEALED=$(echo "$STATUS" | jq -r '.sealed')

    if [ "$SEALED" == "true" ]; then
        echo -e "${YELLOW}  [Vault] Unsealing pod $POD...${NC}"
        KEY1=$(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key1}' | base64 -d)
        KEY2=$(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key2}' | base64 -d)
        KEY3=$(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.key3}' | base64 -d)
        
        retry vault_exec "$POD" "vault operator unseal -tls-server-name=vault $KEY1" > /dev/null 2>&1
        retry vault_exec "$POD" "vault operator unseal -tls-server-name=vault $KEY2" > /dev/null 2>&1
        retry vault_exec "$POD" "vault operator unseal -tls-server-name=vault $KEY3" > /dev/null 2>&1
        echo -e "${GREEN}  [Vault] Pod $POD unsealed!${NC}"
    else
        echo -e "${GREEN}  [Vault] Pod $POD is already unsealed.${NC}"
    fi
done

# 4. Configure Vault
ROOT_TOKEN=$(kubectl get secret "$SECRET_NAME" -n vault -o jsonpath='{.data.root-token}' | base64 -d)

echo -e "${BLUE}  [Vault] Configuring engines and auth...${NC}"
vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault secrets list -tls-server-name=vault" | grep -q "secret/" || \
  vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault secrets enable -path=secret -tls-server-name=vault kv-v2" > /dev/null 2>&1

vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault auth list -tls-server-name=vault" | grep -q "kubernetes/" || \
  vault_exec "$VAULT_POD" "VAULT_TOKEN=$ROOT_TOKEN vault auth enable -tls-server-name=vault kubernetes" > /dev/null 2>&1

K8S_ISSUER=$(retry kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
K8S_CA=$(retry kubectl exec -n vault "$VAULT_POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

vault_auth_write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert="$K8S_CA" \
    issuer="$K8S_ISSUER"

# Policies and Roles
echo -e "${YELLOW}  [Vault] Writing policies...${NC}"
$VAULT_EXEC_BASE "$VAULT_POD" -- /bin/sh -c "env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault policy write -tls-server-name=vault tailscale-policy -" > /dev/null 2>&1 <<EOF
path "secret/data/tailscale/*" {
  capabilities = ["read"]
}
EOF

$VAULT_EXEC_BASE "$VAULT_POD" -- /bin/sh -c "env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault policy write -tls-server-name=vault monitoring-policy -" > /dev/null 2>&1 <<EOF
path "secret/data/grafana/*" {
  capabilities = ["read"]
}
EOF

vault_auth_write auth/kubernetes/role/eso-role \
    bound_service_account_names=eso-external-secrets,eso-dev-external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=tailscale-policy,monitoring-policy \
    ttl=24h

# 5. Seed secrets
echo -e "${BLUE}  [Vault] Seeding secrets...${NC}"

seed_kv_secret secret/tailscale/auth \
    client_id="$TS_CLIENT_ID" \
    client_secret="$TS_CLIENT_SECRET"

# Generate random password for Grafana and include default user
generate_kv_secret_if_missing secret/grafana/admin password 32 "user=admin"

# 6. Reconcile dependent ArgoCD applications (force sync, too lazy to simplify)
echo -e "\n${BLUE}🔄 Syncing and refreshing dependent ArgoCD applications...${NC}"
if [ "$ENV" == "dev" ]; then
  for APP in eso-dev monitoring-dev tailscale-dev; do
    if kubectl get app "$APP" -n argocd >/dev/null 2>&1; then
        echo -e "${YELLOW}  [ArgoCD] Refreshing and syncing $APP...${NC}"
        kubectl annotate app "$APP" -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
        kubectl patch app "$APP" -n argocd --type merge -p '{"operation":{"sync":{"resources":[]}}}' >/dev/null 2>&1 || true
    fi
  done
else
  for APP in eso monitoring tailscale; do
    if kubectl get app "$APP" -n argocd >/dev/null 2>&1; then
        echo -e "${YELLOW}  [ArgoCD] Refreshing and syncing $APP...${NC}"
        kubectl annotate app "$APP" -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
        kubectl patch app "$APP" -n argocd --type merge -p '{"operation":{"sync":{"resources":[]}}}' >/dev/null 2>&1 || true
    fi
  done
fi

echo -e "${GREEN}  [Vault] Configuration complete!${NC}"
