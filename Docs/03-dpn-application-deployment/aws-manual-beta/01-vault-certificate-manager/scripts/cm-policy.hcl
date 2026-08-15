# =============================================================================
# Vault policy for certificate-manager
# Applied in RUNBOOK.md step 5:
#   vault policy write certificate-manager /tmp/cm-policy.hcl
#
# Grants only what VaultSecretProviderImpl needs:
#   - sys/mounts                        : KV mount verification on startup
#   - pki-client/data/node-net/client/* : read+write the keypair, certificate,
#                                         ca-chain, intermediate-ca and the
#                                         keystore/truststore passwords
#   - pki-client/metadata/...           : list/read for diagnostics
# =============================================================================

path "sys/mounts" {
  capabilities = ["read", "list"]
}

path "pki-client/data/node-net/client/*" {
  capabilities = ["read", "create", "update", "list"]
}

path "pki-client/metadata/node-net/client/*" {
  capabilities = ["read", "list"]
}

path "pki-client/metadata/node-net/client" {
  capabilities = ["read", "list"]
}
