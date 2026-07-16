# DPN Certificate Manager Configuration

This section describes how to configure and deploy the **DPN Federator Certificate Manager (CLM)** in a single target environment. The Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for the Federator Gateway — it renews the DSM-signed certificate and builds the keystore/truststore P12 files used for mutual TLS (mTLS).

> **Depends on Vault.** The Certificate Manager **cannot run without the DPN HashiCorp Vault service**. Vault must already be deployed, initialised (KV v2 enabled at `pki-client`), and loaded with the certificate bundle before you deploy the Certificate Manager. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md).

> **Single environment:** These instructions target **one environment** (`<env>`). Substitute your own environment name wherever you see `<env>` (for `config/<env>.json` and `values-<env>.yaml`). You do not need to create multiple environment files.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Setup SMB File Share (Azure File Share)](#step2-setup-smb-file-share-azure-file-share)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Set Up Helm Values](#step3a-set-up-helm-values)
  - [Step3b: Configure Secrets](#step3b-configure-secrets)
- [Step4: Setup Deployment Configuration](#step4-setup-deployment-configuration)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager runs as a headless daemon (no HTTP endpoints) executing two scheduled jobs:

- **Renewal job** — obtains/renews the DSM-signed certificate via the Management Node PKI API and persists the material in Vault.
- **Sync job** — builds the keystore/truststore P12 files from the Vault material and writes them to the shared file share (default mount `/tls`). The P12 **passwords are managed in Vault** (see below) — they are **not** written to the file share.

The Federator Gateway Server and Client mount the same file share (read-only) and use these P12 files for mTLS with the DSI DSM and other DPNs.

**How it uses Vault:** the Certificate Manager reads and writes the following KV v2 paths under the `pki-client` mount. The first three are loaded during Vault setup; the last three are written by the Certificate Manager itself:

| Path (`pki-client/node-net/client/…`) | Content | Written by |
|---------------------------------------|---------|------------|
| `keypair`, `certificate`, `ca-chain` | Client key pair, DSM-signed certificate, CA chain | Vault bundle load (during [Vault setup](01-configure-dpn-vault-service.md#step-3-deployment-configuration)) |
| `intermediate-ca` | Intermediate CA certificate | Certificate Manager (renewal) |
| `keystore-password`, `truststore-password` | Passwords for the generated P12 files | Certificate Manager |

The service integrates with **HashiCorp Vault** (secret persistence), the **Management Node** API (PKI operations), and an **OAuth2 Identity Provider** (token auth). All external communication is over mTLS.

---

## Step1: Meet the Prerequisites

Ensure the following are in place **before** deploying the Certificate Manager:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Vault running over HTTPS, KV v2 enabled at `pki-client`, and the certificate bundle loaded into `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **`cert-manager-truststore` Kubernetes secret present** | Holds `truststore.jks` used to trust the Vault HTTPS endpoint. Created automatically by the Vault `vault-tls-bootstrap-cd` pipeline |
| 3 | **`VAULT-TOKEN` and `VAULT-TRUSTSTORE-PASSWORD` available** | The Vault root token (stored in Key Vault by the Vault init stage) and the Vault truststore password (from the Vault bootstrap). Both are consumed by the Certificate Manager |
| 4 | **Shared Azure File Share provisioned** + `azure-fileshare-secret` | Common storage for the P12 files. The `azure-fileshare-secret` should be in Azure Key Vault or Kubernetes secret must be **created manually before deploy** (the PV mounts using it) — see [Shared File Share](#step2-setup-smb-file-share-azure-file-share) below |
| 5 | **AKS cluster** + (if using Azure Key Vault for secrets) a **user-assigned managed identity** and the **Secrets Store CSI driver** | Required when `keyvault.enabled: true` |
| 6 | **OAuth2 client ID, client secret, and Management Node URL** | Received from DSM during onboarding to establish the DPN connection |
| 7 | **Certificate Manager container image available** | Built via the DSI-provided CI process or obtained prebuilt from the DSI GitHub Container Registry (GHCR). Its tag is supplied to the CD pipeline as `imageTag` (see the CI/CD overview in [Common Configuration](00-common-dpn-configuration.md#continuous-integration-ci)) |
| 8 | **`config/<env>.json` and `values-<env>.yaml` populated** | See [Pre-Deployment Configuration](#step3-environment-configuration) |

> **Azure DevOps pipeline setup (one-time):** Before running the CD pipeline, complete [Azure DevOps Configuration](00-common-dpn-configuration.md#step2-azure-devops-configuration) — the pipeline **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), set up the Azure **service connection**, and populate `config/<env>.json`.

## Step2: Setup SMB File Share (Azure File Share)

The Certificate Manager, Federator Gateway Server, and Federator Gateway Client all require the P12 files and their password files at a common mount point (default `/tls`). The Certificate Manager creates these dynamically when it renews/fetches certificates; the Federator mounts them read-only.

```text
/file-share-mount-path
└── tls
    ├── keystore.p12
    └── truststore.p12
```

> **Note:** Only the P12 files are written to the file share. The keystore and truststore **passwords are held in Vault** (`pki-client/node-net/client/keystore-password` and `truststore-password`) and managed by the Certificate Manager — they are not written as `.password` files on the share.

The SMB file share (Azure file share) is provisioned by the certificate-manager chart (`charts/certificate-manager`, PV/PVC in `templates/pv-pvc.yaml`) when `fileShare.create: true`. Set it to `false` if the PV/PVC already exist.

> **Manual Kubernetes secret — create this BEFORE deploying (required).** The file-share PersistentVolume authenticates to Azure Files with a storage-account key held in a **pre-existing** Kubernetes secret (`fileShare.secretName`, default `azure-fileshare-secret`), referenced by the PV's `nodeStageSecretRef`. It **must exist before the Certificate Manager is deployed** — it cannot be supplied by the Key Vault CSI driver, because the PV mounts before any CSI-synced secret is created. Create it once in the target namespace:
>
> ```bash
> kubectl create secret generic azure-fileshare-secret \
>   --namespace <namespace> \
>   --from-literal=azurestorageaccountname=<file-share-storage-account> \
>   --from-literal=azurestorageaccountkey=<file-share-storage-account-key>
> ```
>
> This same secret and PVC are reused by the Federator Gateway (which mounts `/tls` read-only), so it only needs to be created once.

**Note:** The upcoming release of the DPN package is planned to remove the SMB share.

---

## Step3: Environment Configuration

The following configurations are required in each environment: 

- `Helm values`
- `secrets` 

Organisations must change the default passwords during secret set up and follow periodic rotation of secrets.

### Step3a: Set Up Helm Values

Copy `values.yaml` (reference — do not edit directly) to `values-<env>.yaml` and set the parameters below. The CD pipeline resolves `values-<env>.yaml` from the environment you select at runtime.

```text
Root-Repository
  └── charts
        └── certificate-manager
              ├── values.yaml        <- Reference file; do not edit directly
              ├── values-<env>.yaml  <- Your environment overrides
```

DSI proposes only the selective changes below; other parameters may be customised if required. All of these map to container environment variables via the chart ConfigMap.

**Core deployment**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `managementNode.baseUrl` | DSI DSM Management Node URL for your environment | `https://management.dsm01.dsiXXX.neso.energy` |

**OAuth2 (Management Node authentication)**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `oauth2.clientId` | Client ID received from DSM | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `oauth2.tokenUri` | IDP token URL received from DSM | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |

**Certificate subject** (used by the Certificate Manager to generate its CSR)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cert.subject.country` | CSR subject Country (C) | `UK` |
| `cert.subject.org` | CSR subject Organisation (O) | `<organisation abbreviation>` |
| `cert.subject.cn` | CSR subject Common Name (CN) | `dpn-<env>-01` |
| `cert.subject.altNames` | Comma-separated SANs (producer/consumer endpoints) | `producer.dpn01.dsiXXX.neso.energy,consumer.dpn01.dsiXXX.neso.energy` |

**Generated keystore output (written to the shared file share)**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `certDest.path` | Directory on the file share for P12 artefacts | `/tls/` |
| `certDest.keystoreFile` / `certDest.truststoreFile` | P12 filenames written to the file share | `keystore.p12` / `truststore.p12` |
| `certDest.keystoreAlias` | Alias used for the keystore entry | `federator` |
| `mtls.keystorePath` / `mtls.truststorePath` | Absolute P12 paths on the file share | `/tls/keystore.p12` / `/tls/truststore.p12` |
| `mtls.keystoreType` | Keystore type | `PKCS12` |

**Azure File Share**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `fileShare.storageAccount` | Storage account backing the file share | `st<env>dpn01<region>01` |
| `fileShare.shareName` | SMB file share name | `fs<env>dpn01<region>01` |
| `fileShare.secretName` | Kubernetes secret with the file-share credentials | `azure-fileshare-secret` |

**Azure Key Vault**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | AKV name, managed-identity client ID, and tenant ID — update these in the values file | `kv-dpn-<env>-<region>-<seq>` / `<managed-identity-client-id>` / `<tenant-id>` |

### Step3b: Configure Secrets

#### Option A — Through Azure Key Vault (`keyvault.enabled: true`)

The `SecretProviderClass` pulls the following from `<keyvault.name>` into the `certificate-manager-secrets` Kubernetes secret:

| AKV Secret | Kubernetes secret / key | Purpose | Example (placeholder) |
|------------|-------------------------|---------|-----------------------|
| `VAULT-TOKEN` | `certificate-manager-secrets` / `VAULT_TOKEN` | Root token of the DPN HashiCorp Vault (from Vault init) | `hvs.xxxxxxxxxxx` |

> **Note:** `VAULT-TOKEN` is produced during Vault setup by the Vault init stage (`storeRootTokenInAkv: true`). Confirm it exists in Key Vault before deploying.

#### Option B - Through Vault truststore (Kubernetes secret)

The Vault HTTPS truststore (`truststore.jks`) is loaded into the Kubernetes secret named by `vaultTruststore.secretName` (default `cert-manager-truststore`) and mounted at `vaultTruststore.mountPath`. This secret is **created automatically by the Vault `vault-tls-bootstrap-cd` pipeline** — no manual `kubectl create secret` is required.

---

## Step4: Setup Deployment Configuration

The Certificate Manager is deployed with the CD pipeline `certificate-manager-cd.yaml` in the `dpn-federator-certificate-manager` repository:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── certificate-manager-cd.yaml
```

The pipeline runs three stages: **Validate** (`helm lint` + dry-run) → **Deploy** (`helm upgrade --install`, approval-gated, followed by a rolling restart) → **Verify** (rollout + PVC status).

Runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `serviceConnection` | Azure service connection for your environment |
| `environment` | Your target environment; resolves `config/<env>.json` and `values-<env>.yaml` |
| `imageTag` | Tag (Build ID) of the Certificate Manager image to deploy — from the CI build or the prebuilt DSI image |
| `vaultInitEnabled` | Run the one-time Vault init Job (`vaultInitJob.enabled`) that enables KV v2 + `pki-client`. Set `true` **only** on the first deploy if Vault was not already initialised during Vault setup; otherwise leave `false` |

> **Note (Vault dependency):** Deploy the Certificate Manager only after Vault is fully set up. If `vaultInitEnabled` is left `false` but Vault's KV v2 engine is not yet enabled, the renewal/sync jobs will fail until Vault is initialised.

---
## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 31-Jul-2026 | DSI Assurance    | Final  | V1.0.0 |
