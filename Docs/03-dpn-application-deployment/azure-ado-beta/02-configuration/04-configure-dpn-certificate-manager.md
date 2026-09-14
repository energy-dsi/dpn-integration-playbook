# DPN Certificate Manager Configuration

This section describes how to configure and deploy the **DPN Federator Certificate Manager (CLM)** in a single target environment. The Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for the Federator Gateway — it renews the DSM-signed certificate and builds the keystore/truststore P12 files used for mutual TLS (mTLS).

> **Depends on Vault.** The Certificate Manager **cannot run without the DPN HashiCorp Vault service**. Vault must already be deployed, initialised (KV v2 enabled at `pki-client`), and loaded with the certificate bundle before you deploy the Certificate Manager. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md).

> **Single environment:** These instructions target **one environment** (`<env>`). Substitute your own environment name wherever you see `<env>` (for `config/<env>.json` and `values-<env>.yaml`). You do not need to create multiple environment files.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Vault Authentication](#step2-configure-vault-authentication)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Set Up Helm Values](#step3a-set-up-helm-values)
  - [Step3b: Configure Secrets](#step3b-configure-secrets)
    - [Option A — Through Azure Key Vault (`keyvault.enabled: true`)](#option-a--through-azure-key-vault-keyvaultenabled-true)
    - [Option B - Through Vault truststore (Kubernetes secret)](#option-b---through-vault-truststore-kubernetes-secret)
- [Step4: Setup Deployment Configuration](#step4-setup-deployment-configuration)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager runs as a headless daemon (no HTTP endpoints) executing two scheduled jobs:

- **Renewal job** — obtains/renews the DSM-signed certificate via the Management Node PKI API and persists the material in Vault.
- **Sync job** — refreshes the mTLS keystore/truststore from the Vault material. Both are built **in memory** directly from certificate material read from Vault at start-up/refresh — no shared file share is used, and no P12 files are ever written to disk.

The Federator Gateway Server and Client read the same certificate material directly from Vault and build their own in-memory keystore/truststore the same way — they no longer mount a shared volume to pick up P12 files from the Certificate Manager.

> **No more SMB file share.** Earlier releases distributed `keystore.p12`/`truststore.p12` between the Certificate Manager and the Federator Gateway via a shared Azure SMB file share. That file share has been fully removed from this chart: there is no `fileShare.*` values block, no PV/PVC template, and no toggle to re-enable it — the keystore/truststore are built in memory from Vault material instead.

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
| 3 | **Vault credentials available** | Either `VAULT-TOKEN` (root token, stored in Key Vault by the Vault init stage) or, if using the recommended AppRole method, `VAULT-APPROLE-SECRET-ID` plus a `role_id` — see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication). `VAULT-TRUSTSTORE-PASSWORD` (from the Vault bootstrap) is required either way |
| 4 | **AKS cluster** + (if using Azure Key Vault for secrets) a **user-assigned managed identity** and the **Secrets Store CSI driver** | Required when `keyvault.enabled: true` |
| 5 | **OAuth2 client ID, client secret, and Management Node URL** | Received from DSM during onboarding to establish the DPN connection |
| 6 | **Certificate Manager container image available** | Built via the DSI-provided CI process or obtained prebuilt from the DSI GitHub Container Registry (GHCR). Its tag is supplied to the CD pipeline as `imageTag` (see the CI/CD overview in [Common Configuration](00-common-dpn-configuration.md#continuous-integration-ci)) |
| 7 | **`config/<env>.json` and `values-<env>.yaml` populated** | See [Pre-Deployment Configuration](#step3-environment-configuration) |

> **No shared file share required.** Unlike earlier releases, the Certificate Manager does not need a provisioned Azure File Share or `azure-fileshare-secret` — it builds the mTLS keystore/truststore in memory directly from Vault. See [Step2](#step2-configure-vault-authentication) and the note in [Overview](#overview).

> **Azure DevOps pipeline setup (one-time):** Before running the CD pipeline, complete [Azure DevOps Configuration](00-common-dpn-configuration.md#step2-azure-devops-configuration) — the pipeline **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), set up the Azure **service connection**, and populate `config/<env>.json`.

## Step2: Configure Vault Authentication

The Certificate Manager reads and writes its certificate material directly in Vault — there is no file share to provision. What you do need to decide is **how the Certificate Manager authenticates to Vault**:

| Method | `vault.authentication` | Notes |
|--------|------------------------|-------|
| Root token | `TOKEN` | Simplest to bootstrap with, but the token has full access to Vault. Kept for backward compatibility; see [Configure DPN Vault Service](01-configure-dpn-vault-service.md#step-3b-configuration-to-initialise-vault-vault-https-cd) |
| **AppRole** (recommended, chart default) | `APPROLE` | Scoped, short-lived credentials specific to the Certificate Manager. Provisioned by the `vault-approle-setup-cd` pipeline — see [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-vault-approle-setup-cd-recommended) |

To switch to AppRole once the identity has been provisioned, set in `values-<env>.yaml`:

```yaml
vault:
  authentication: APPROLE
  appRole:
    roleId: <role_id from vault-approle-setup-cd>
```

The generated `secret-id` is delivered as the Key Vault secret `VAULT-APPROLE-SECRET-ID`, synced into the `certificate-manager-secrets` Kubernetes secret by the CSI driver — the same mechanism already used for `VAULT-TOKEN` (see [Step3b: Configure Secrets](#step3b-configure-secrets)). `VaultAuthStartupValidator` fails the deployment fast if `authentication: APPROLE` is set but the role-id/secret-id are missing.

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

**Vault connectivity** (see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication))

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `vault.uri` | HTTPS address of the DPN Vault service | `https://vault-https.<namespace>.svc.cluster.local:8200` |
| `vault.authentication` | `APPROLE` (recommended, and the chart's own default) or `TOKEN` | `APPROLE` |
| `vault.authRole` | Vault role name used for the `TOKEN`/`KUBERNETES` login paths | `certificate-manager` |
| `vault.pkiMount` / `vault.secretPath` | KV v2 mount and path holding the certificate material | `pki-client` / `pki-client/node-net/client` |
| `vault.appRole.role` | AppRole role name (must match the role created by `vault-approle-setup-cd`) | `certificate-manager` |
| `vault.appRole.roleId` | Non-sensitive role-id printed by `vault-approle-setup-cd` | `<role_id>` |
| `vault.appRole.mountPath` | Mount path of Vault's AppRole auth method | `approle` |
| `certIdent.keystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

**Certificate subject** (used by the Certificate Manager to generate its CSR)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cert.subject.country` | CSR subject Country (C) | `UK` |
| `cert.subject.org` | CSR subject Organisation (O) | `<organisation abbreviation>` |
| `cert.subject.cn` | CSR subject Common Name (CN) | `dpn-<env>-01` |
| `cert.subject.altNames` | Comma-separated SANs — every producer/consumer endpoint this node exposes, across **both** the gRPC Federator and (if deployed) the REST Federator Gateway | `producer.dpn01.dsiXXX.neso.energy,consumer.dpn01.dsiXXX.neso.energy,producer-rest01.dpn01.dsiXXX.neso.energy` |
| `cert.renewalThresholdDays` | Renew automatically once the certificate's remaining validity drops below this many days | `100` |

> **In-memory keystore — no `certDest`/`mtls`/`fileShare` parameters.** Earlier chart versions wrote P12 files to a shared file share and exposed `certDest.*`/`mtls.*`/`fileShare.*` values to configure that path. These no longer exist: the keystore/truststore are built in memory with an ephemeral password and handed directly to the application — there is nothing to point at a file path or a storage account.

**Azure Key Vault**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | AKV name, managed-identity client ID, and tenant ID — update these in the values file | `kv-dpn-<env>-<region>-<seq>` / `<managed-identity-client-id>` / `<tenant-id>` |
| `vaultTruststore.secretName` | Pre-existing Kubernetes secret holding `truststore.jks` to trust Vault's HTTPS endpoint | `cert-manager-truststore` |
| `existingSecret.name` | Use a pre-created Kubernetes secret instead of the chart-managed one (required when `keyvault.enabled: true`) | `certificate-manager-secrets` |

### Step3b: Configure Secrets

#### Option A — Through Azure Key Vault (`keyvault.enabled: true`)

The `SecretProviderClass` pulls the following from `<keyvault.name>` into the `certificate-manager-secrets` Kubernetes secret. Populate the row matching the `vault.authentication` method you chose in [Step2](#step2-configure-vault-authentication) — the other is unused:

| AKV Secret | Kubernetes secret / key | Purpose | Example (placeholder) |
|------------|-------------------------|---------|-----------------------|
| `VAULT-APPROLE-SECRET-ID` *(recommended)* | `certificate-manager-secrets` / `VAULT_APPROLE_SECRET_ID` | AppRole secret-id for the Certificate Manager, from `vault-approle-setup-cd` | `<generated secret-id>` |
| `VAULT-TOKEN` | `certificate-manager-secrets` / `VAULT_TOKEN` | Root token of the DPN HashiCorp Vault (from Vault init) — only used when `vault.authentication: TOKEN` | `hvs.xxxxxxxxxxx` |
| `OAUTH2-CLIENT-SECRET` | `certificate-manager-secrets` / `OAUTH2_CLIENT_SECRET` | Client secret for the Management Node OAuth2 client (if `oauth2.authMode` requires one) | `<client-secret>` |

> **Note:** `VAULT-APPROLE-SECRET-ID` is produced by the `vault-approle-setup-cd` pipeline (see [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-vault-approle-setup-cd-recommended)). `VAULT-TOKEN` is produced during Vault setup by the Vault init stage (`storeRootTokenInAkv: true`) and is only needed if you have not migrated to AppRole. Confirm whichever you use exists in Key Vault before deploying.

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
