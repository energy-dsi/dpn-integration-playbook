#!/bin/sh
# Generates the Vault server TLS certificate (server cert + key) and a Java
# truststore (JKS) that trusts it, so certificate-manager can talk to Vault
# over HTTPS.
#
# Usage:
#   COUNTRY=GB ORG="Example Corp" TRUSTSTORE_PASS=<your-password> OUT_DIR=./vault-bundle \
#     sh create-vault-tls-bootstrap.sh
#
# Produces:
#   $OUT_DIR/ca/rootCA.crt              — self-signed root CA (keep offline/secure)
#   $OUT_DIR/certs/vault.crt            — Vault server certificate
#   $OUT_DIR/certs/vault.key            — Vault server private key
#   $OUT_DIR/truststore.jks             — truststore containing rootCA.crt
#
# Requires: openssl, keytool (part of any JDK).
#
# The SAN below MUST match the Kubernetes Service name Vault is reachable at
# (vault-https.<namespace>.svc.cluster.local). If you rename the Service in
# manifests/01-vault-https.yaml, update SAN here and re-run.
set -eu

COUNTRY="${COUNTRY:-GB}"
ORG="${ORG:-Example Corp}"
NAMESPACE="${NAMESPACE:-ns-dpn-01}"
TRUSTSTORE_PASS="${TRUSTSTORE_PASS:?set TRUSTSTORE_PASS to a password of your choosing}"
OUT_DIR="${OUT_DIR:-./vault-bundle}"
SAN="vault-https.${NAMESPACE}.svc.cluster.local"

mkdir -p "$OUT_DIR/ca" "$OUT_DIR/certs"

echo "=== Generating root CA ==="
openssl genrsa -out "$OUT_DIR/ca/rootCA.key" 4096
openssl req -x509 -new -nodes -key "$OUT_DIR/ca/rootCA.key" -sha256 -days 3650 \
  -subj "/C=${COUNTRY}/O=${ORG}/CN=vault-bootstrap-root-ca" \
  -out "$OUT_DIR/ca/rootCA.crt"

echo "=== Generating Vault server key + CSR ==="
openssl genrsa -out "$OUT_DIR/certs/vault.key" 2048
openssl req -new -key "$OUT_DIR/certs/vault.key" \
  -subj "/C=${COUNTRY}/O=${ORG}/CN=vault" \
  -out "$OUT_DIR/certs/vault.csr"

cat > "$OUT_DIR/certs/vault.ext" <<EOF
subjectAltName = DNS:${SAN}, DNS:vault-https, DNS:localhost, IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF

echo "=== Signing Vault server certificate (SAN=${SAN}) ==="
openssl x509 -req -in "$OUT_DIR/certs/vault.csr" \
  -CA "$OUT_DIR/ca/rootCA.crt" -CAkey "$OUT_DIR/ca/rootCA.key" -CAcreateserial \
  -out "$OUT_DIR/certs/vault.crt" -days 825 -sha256 \
  -extfile "$OUT_DIR/certs/vault.ext"

rm -f "$OUT_DIR/certs/vault.csr" "$OUT_DIR/certs/vault.ext"

echo "=== Building truststore.jks (trusts rootCA.crt) ==="
rm -f "$OUT_DIR/truststore.jks"
keytool -importcert -noprompt \
  -alias vault-root-ca \
  -file "$OUT_DIR/ca/rootCA.crt" \
  -keystore "$OUT_DIR/truststore.jks" \
  -storepass "$TRUSTSTORE_PASS"

echo ""
echo "Done. Files written under $OUT_DIR/:"
find "$OUT_DIR" -type f
echo ""
echo "Next: kubectl create secret generic vault-tls \\"
echo "  --from-file=vault.crt=$OUT_DIR/certs/vault.crt \\"
echo "  --from-file=vault.key=$OUT_DIR/certs/vault.key \\"
echo "  -n ${NAMESPACE}"
