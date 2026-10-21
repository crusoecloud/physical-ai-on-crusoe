#!/usr/bin/env bash
# Build the combined CA bundle and fan it out to the three namespaces (osmo-install.md Phase 7).
#
# Why this is a script: the bundle build + 3-namespace fan-out is the most
# delicate mechanical sequence in the install:
# the public CA must come from an in-cluster image — macOS has no
# /etc/ssl/certs bundle; REQUESTS_CA_BUNDLE/SSL_CERT_FILE REPLACE the
# trust store, so the bundle must be gateway-cert + FULL public set;
# workflow pods run in default and osmo-test, not osmo — a
# namespace-local ConfigMap is invisible to them).
# Single-homed here so a reissue refresh is one command, not a re-read.
#
# Usage:  scripts/build_ca_bundle.sh   (needs CLUSTER_NAME; kubectl on PATH)
# Writes: $WORKDIR/{public-ca-bundle,envoy-cert,combined-ca-bundle}.crt and
#         the envoy-ca-cert ConfigMap in osmo, default and osmo-test; then
#         restarts the two backend-operator deployments so they re-fetch.
# Exit 0 on success; exit 1 with a clear message on any gate failure.

set -euo pipefail

WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"

# 1. Public CA bundle from an in-cluster image (count-gated: >=100 certs).
kubectl delete pod ca-bundle-fetch -n osmo --ignore-not-found --wait=true
kubectl run ca-bundle-fetch --image=curlimages/curl:8.10.1 --restart=Never -n osmo \
  --command -- sh -c "cat /etc/ssl/certs/ca-certificates.crt; sleep 30"
kubectl wait pod/ca-bundle-fetch -n osmo --for=condition=Ready --timeout=120s
kubectl logs -n osmo ca-bundle-fetch > "$WORKDIR/public-ca-bundle.crt"
[ "$(grep -c 'BEGIN CERTIFICATE' "$WORKDIR/public-ca-bundle.crt")" -ge 100 ] || {
  echo "public CA bundle looks empty or truncated (<100 certs)"; exit 1; }
kubectl delete pod ca-bundle-fetch -n osmo --wait=false

# 2. Gateway cert + combined bundle.
kubectl get secret envoy-ssl-cert -n osmo -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORKDIR/envoy-cert.crt"
cat "$WORKDIR/public-ca-bundle.crt" "$WORKDIR/envoy-cert.crt" > "$WORKDIR/combined-ca-bundle.crt"

# 3. Three copies: workflow pods do NOT run in `osmo` (Unschedulable:
# Missing required configmaps otherwise) — default and osmo-test need it too.
for ns in osmo default osmo-test; do
  kubectl create configmap envoy-ca-cert -n "$ns" --from-file=ca.crt="$WORKDIR/combined-ca-bundle.crt" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# 4. Backend operator fetches its CA once at startup: restart both, gated.
[ "$(kubectl get deploy -n osmo -o name | grep -cE 'backend-(listener|worker)')" -eq 2 ] || {
  echo "expected 2 backend-operator deployments"; exit 1; }
for d in $(kubectl get deploy -n osmo -o name | grep -E 'backend-(listener|worker)'); do
  kubectl rollout restart -n osmo "$d"
done
for d in $(kubectl get deploy -n osmo -o name | grep -E 'backend-(listener|worker)'); do
  kubectl rollout status -n osmo "$d" --timeout=300s
done
echo "combined CA bundle built and fanned out; backend deployments restarted"
