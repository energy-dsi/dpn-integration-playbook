#!/bin/sh
# Generates a NON-PRODUCTION client identity bundle (private key + self-signed
# certificate + CA chain) to load into Vault at pki-client/node-net/client/*
# (see RUNBOOK.md Installation, "Load the bootstrap identity bundle").
#
# In a real deployment this bundle is normally issued by your PKI/DSM
# (Device/Secrets Management) system, not generated locally. Use this script
# only for demos, dev environments, or when you don't yet have a real DSM
# integration and just want the stack to come up end-to-end.
#
# Usage:
#   COUNTRY=GB ORG="Example Corp" CN=dpn-client-01 OUT_DIR=./bootstrap-cert \
#     sh generate-bootstrap-cert.sh
#
# Produces:
#   $OUT_DIR/vault.key         — private key
#   $OUT_DIR/certificate.pem   — self-signed certificate
#   $OUT_DIR/ca-chain.pem      — CA chain (== certificate.pem for a self-signed cert)
set -eu

COUNTRY="${COUNTRY:-GB}"
ORG="${ORG:-Example Corp}"
CN="${CN:-dpn-client-01}"
OUT_DIR="${OUT_DIR:-./bootstrap-cert}"

mkdir -p "$OUT_DIR"

echo "=== Generating self-signed bootstrap identity (CN=${CN}) ==="
openssl genrsa -out "$OUT_DIR/vault.key" 2048
openssl req -x509 -new -nodes -key "$OUT_DIR/vault.key" -sha256 -days 825 \
  -subj "/C=${COUNTRY}/O=${ORG}/CN=${CN}" \
  -out "$OUT_DIR/certificate.pem"
cp "$OUT_DIR/certificate.pem" "$OUT_DIR/ca-chain.pem"

echo ""
echo "Done. Files written under $OUT_DIR/:"
find "$OUT_DIR" -type f
echo ""
echo "NOT FOR PRODUCTION USE — replace with a DSM-issued bundle before go-live."
