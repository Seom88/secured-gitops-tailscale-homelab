#!/bin/bash
set -euo pipefail

: "${S3_ENDPOINT:?S3_ENDPOINT must be set (e.g. https://s3.<tailnet>.ts.net)}"
: "${SOPS_AGE_KEY_FILE:?SOPS_AGE_KEY_FILE must be set}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set (RustFS key)}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set (RustFS key)}"
for cmd in aws sops kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done

mkdir -p "$(dirname "$SOPS_AGE_KEY_FILE")"
aws s3 cp s3://secrets-homelab/sops/keys.txt "$SOPS_AGE_KEY_FILE" \
    --endpoint-url "$S3_ENDPOINT" --region us-east-1 --no-verify-ssl
chmod 600 "$SOPS_AGE_KEY_FILE"

if find platform apps -path '*/templates/*' -name '*.enc.yaml' | grep -q .; then
  echo "::error::there are *.enc.yaml in templates/ — move them to <chart>/sops/"
  find platform apps -path '*/templates/*' -name '*.enc.yaml'
  exit 1
fi

find platform apps -name '*.enc.yaml' -not -path '*/templates/*' | sort | while read -r f; do
  echo "→ applying $f"
  sops decrypt "$f" | kubectl apply -f -
done

shred -u "$SOPS_AGE_KEY_FILE" || rm -f "$SOPS_AGE_KEY_FILE"