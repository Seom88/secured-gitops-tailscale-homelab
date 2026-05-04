# Basics
this chart add esencial pod and operator that the entire homelab will use

## Generate secrets

Use .env.template as reference

```bash
kubectl create secret generic operator-oauth \
  --from-env-file=.env \
  --dry-run=client -o yaml | kubectl apply -f -
```