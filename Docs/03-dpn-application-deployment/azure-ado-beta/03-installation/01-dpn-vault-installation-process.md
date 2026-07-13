# DPN Vault Service Installation Process

This document covers the installation of the **DPN HashiCorp Vault service** into a single target environment on Azure Kubernetes Service (AKS).

> **Full instructions live in the configuration guide.** The end-to-end Vault flow — prerequisites, the values/config to populate, the deployment pipelines, post-deployment auto-unseal, and verification — is documented in one place:
>
> 👉 **[Configure DPN Vault Service](../02-configuration/01-configure-dpn-vault-service.md)**
>
> This installation page is a quick-reference summary that points to that guide.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Sequence](#installation-sequence)
- [Verification](#verification)
- [Manual Fallback](#manual-fallback)
- [Review Notes](#review-notes)

---

## Overview

Vault is deployed and configured using three Azure DevOps CD pipelines from the `dpn-federator-certificate-manager` repository. It serves over HTTPS internally and uses **Azure Key Vault auto-unseal**, so it unseals itself on start-up (no manual unseal step).

The pipelines are located under:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            ├── vault-tls-bootstrap-cd.yaml
            ├── vault-https-cd.yaml
            └── vault-load-bundle-cd.yaml
```

---

## Prerequisites

Confirm the prerequisites before starting — see [Configure DPN Vault Service → Step 1](../02-configuration/01-configure-dpn-vault-service.md#step-1-prerequisites-before-vault-can-be-deployed). In summary: an AKS cluster, an Azure Key Vault with the `vault-unseal-key` and a user-assigned managed identity, the Secrets Store CSI driver enabled, a populated `config/<env>.json` and `values-<env>.yaml`, and the DSM-signed client bundle.

---

## Installation Sequence

Run the three pipelines in order, each with your environment as the runtime parameter. Full parameter tables and details are in [Configure DPN Vault Service → Step 3](../02-configuration/01-configure-dpn-vault-service.md#step-3-deployment).

| Order | Pipeline | What it does |
|-------|----------|--------------|
| 1 | `vault-tls-bootstrap-cd` | Generates the Vault server TLS certificate/key + Certificate Manager truststore; publishes `VAULT-TLS-CERT`, `VAULT-TLS-KEY`, `VAULT-TRUSTSTORE-PASSWORD` to Key Vault and `truststore.jks` to the `cert-manager-truststore` Kubernetes secret |
| 2 | `vault-https-cd` | Deploys Vault (Validate → Deploy → Verify → **VaultInit**): initialises Vault, enables the KV v2 engine at `pki-client`, and (with `storeRootTokenInAkv: true`) stores the root token in Key Vault as `VAULT-TOKEN` |
| 3 | `vault-load-bundle-cd` | Loads the DSM-signed bundle (`vault.key`, `certificate.pem`, `ca-chain.pem` from ADO Secure Files) into `pki-client/node-net/client/{keypair,certificate,ca-chain}` |

---

## Verification

After the sequence completes, confirm Vault is up, unsealed, and populated using the checks in [Configure DPN Vault Service → Step 5](../02-configuration/01-configure-dpn-vault-service.md#step-5-manual-verification-optional). Quick check:

```bash
kubectl get pods -n <namespace> -l app=dpn-vault-https -o wide
kubectl -n <namespace> exec <vault-pod> -- \
  sh -c 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status'
```

`Initialized` should be `true` and `Sealed` should be `false`.

---

## Manual Fallback

If the automated pipelines cannot be used, follow [Configure DPN Vault Service → Manual Vault Configuration (Fallback)](../02-configuration/01-configure-dpn-vault-service.md#manual-vault-configuration-fallback), which performs the same steps with OpenSSL / `keytool` / `kubectl`.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 15-May-2026 | DSI Assurance    | Draft  | V0.1.0 |
