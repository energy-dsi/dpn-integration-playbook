#!/bin/sh
# Creates the dpn-nginx-basic-auth Secret that manifests/09-nginx-proxy.yaml
# mounts. Run BEFORE applying manifests/09-nginx-proxy.yaml — its Deployment
# has a readOnly volume mount on this Secret and won't roll out cleanly
# without it.
#
# Deliberately not checked in as a manifest: the credential is generated
# fresh, per-cluster, right here — this mirrors the source chart's own
# convention (see charts/nginx-observability/values.yaml comment on
# basicAuth.createSecret).
set -eu

: "${NAMESPACE:=ns-dpn-health-01}"
: "${USERNAME:=dpn-observability}"

PASSWORD=$(openssl rand -base64 18 | tr -d '=+/')
HASH=$(openssl passwd -apr1 "$PASSWORD")
echo "${USERNAME}:${HASH}" > /tmp/.htpasswd

kubectl create secret generic dpn-nginx-basic-auth -n "$NAMESPACE" \
  --from-file=.htpasswd=/tmp/.htpasswd \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f /tmp/.htpasswd

echo ""
echo "=== Save this now — it is not retrievable from the cluster afterward ==="
echo "Username: ${USERNAME}"
echo "Password: ${PASSWORD}"
echo ""
echo "To rotate later, just re-run this script — kubectl apply overwrites"
echo "the existing Secret in place, no pod restart required (nginx reads"
echo ".htpasswd per-request)."
