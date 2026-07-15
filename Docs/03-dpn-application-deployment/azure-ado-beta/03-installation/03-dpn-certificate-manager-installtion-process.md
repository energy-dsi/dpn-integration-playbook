# DPN Certificate Manager Installation Process

This document covers the installation of the **DPN Federator Certificate Manager (CLM)** into a single target environment on Azure Kubernetes Service (AKS).

> **Full instructions live in the configuration guide.** The end-to-end Certificate Manager flow — overview, prerequisites, the values/secrets to populate, deployment, and post-deployment verification — is documented in one place:
>
> 👉 **[Configure DPN Certificate Manager](../02-configuration/02-configure-dpn-certificate-manager.md)**
>
> This installation page is a quick-reference summary that points to that guide.

> **Depends on Vault.** The Certificate Manager cannot run until the DPN HashiCorp Vault service is deployed, initialised, and loaded with the certificate bundle. Complete [Vault installation](01-dpn-vault-installation-process.md) first.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Sequence](#installation-sequence)
- [Verification](#verification)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager is deployed with a single Azure DevOps CD pipeline from the `dpn-federator-certificate-manager` repository. It is a headless Spring Boot service that renews the DSM-signed certificate and writes the keystore/truststore P12 files (and their passwords) to the shared file share for the Federator Gateway to consume.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── certificate-manager-cd.yaml
```

> **Note:** On Azure ADO there is no separate Certificate Manager CI pipeline — the container image is built by the DSI CI process or obtained prebuilt from the DSI GitHub Container Registry (GHCR), and its tag is supplied to the CD pipeline as `imageTag`.

---

## Prerequisites

Confirm the prerequisites before starting — see [Configure DPN Certificate Manager → Prerequisites](../02-configuration/02-configure-dpn-certificate-manager.md#prerequisites). In summary: Vault deployed/initialised/loaded, the `cert-manager-truststore` secret present, `VAULT-TOKEN`/`VAULT-TRUSTSTORE-PASSWORD` available, a provisioned Azure File Share + `azure-fileshare-secret`, the OAuth2 client credentials and Management Node URL from DSM, a Certificate Manager image tag, and a populated `config/<env>.json` and `values-<env>.yaml`.

---

## Installation Sequence

Run the CD pipeline with your environment as the runtime parameter. Full parameter details are in [Configure DPN Certificate Manager → Deployment](../02-configuration/02-configure-dpn-certificate-manager.md#deployment).

| Pipeline | What it does |
|----------|--------------|
| `certificate-manager-cd` | Validate (`helm lint` + dry-run) → Deploy (`helm upgrade --install`, approval-gated, rolling restart) → Verify (rollout + PVC). Parameters: `serviceConnection`, `environment`, `imageTag`, `vaultInitEnabled` |

> **`vaultInitEnabled`:** set `true` only on the first deploy if Vault's KV v2 engine was not already enabled during Vault setup; otherwise leave `false`.

---

## Verification

After the pipeline completes, confirm the deployment and the generated P12 files using the checks in [Configure DPN Certificate Manager → Post-Deployment Configuration and Verification](../02-configuration/02-configure-dpn-certificate-manager.md#post-deployment-configuration-and-verification). Quick check:

```bash
kubectl rollout status deployment/dpn-certificate-manager -n <namespace> --timeout=300s
kubectl -n <namespace> exec <pod-name> -- ls -l /tls
# expect: keystore.p12  truststore.p12
```

> **Post-configuration:** the keystore/truststore P12 passwords are managed in Vault by the Certificate Manager (not written to the file share). The Federator Gateway must be configured with the matching P12 passwords in its secret configuration — see [Configure DPN Federator Gateway](../02-configuration/03-configure-dpn-federator-gateway.md).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 15-May-2026 | DSI Assurance    | Draft  | V0.1.0 |
