Release : 2.1.0 - Oct 2026

# DPN Certificate Manager Configuration

This section describes how to configure and deploy the **DPN Federator Certificate Manager (CLM)** in a single target environment. The Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for the Federator Gateway — it renews the DSM-signed certificate and builds the keystore/truststore P12 files used for mutual TLS (mTLS).

> **Depends on Vault.** The Certificate Manager **cannot run without the DPN HashiCorp Vault service**. Vault must already be deployed, initialised (KV v2 enabled at `pki-client`), and loaded with the certificate bundle before you deploy the Certificate Manager. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md).

> **Single environment:** These instructions target **one environment/cluster combination** (`<env>`/`<cluster>`). Substitute your own values wherever you see `<env>`/`<cluster>` (for `config/<env>-<cluster>.json` and `values-<env>-<cluster>.yaml`). You do not need to create multiple environment files.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Vault Authentication](#step2-configure-vault-authentication)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Set Up Helm Values](#step3a-set-up-helm-values)
  - [Step3b: Configure Secrets](#step3b-configure-secrets)
    - [Vault authentication credential (`certificate-manager-secrets`)](#vault-authentication-credential-certificate-manager-secrets)
    - [Vault HTTPS truststore (`cert-manager-truststore`)](#vault-https-truststore-cert-manager-truststore)
- [Step4: Setup Deployment Configuration](#step4-setup-deployment-configuration)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager runs as a headless daemon (no HTTP endpoints) executing two scheduled jobs:

- **Renewal job** — obtains/renews the DSM-signed certificate via the Management Node PKI API and persists the material in Vault.
- **Sync job** — refreshes the mTLS keystore/truststore from the Vault material. Both are built **in memory** directly from certificate material read from Vault at start-up/refresh — no shared file share is used, and no P12 files are ever written to disk.

> **This is a different certificate from a "server certificate."** The Renewal job above is fully automatic and produces the Federator Gateway's own mTLS certificate. A participant's own edge/server infrastructure (e.g. a Cloudflare-fronted server) needs a separate, manually-requested, long-TTL certificate from the same Management Node — see [Requesting a DPN Server Certificate](01-configure-dpn-vault-service.md#requesting-a-dpn-server-certificate), or request it through the DSI portal instead (labelled **"Edge component certificate"** there) via the [DSI Certificate Management UI Guide](../../../05-dpn-user-interfaces/10-dsi-certificate-management-ui-operations.md). The two certificate types are not interchangeable.

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
| 2 | **`cert-manager-truststore` Kubernetes secret present** | Holds `truststore.jks` used to trust the Vault HTTPS endpoint. Created automatically by the `dpn-tls-cd` pipeline — see [Configure DPN Vault Service, Step 3A](01-configure-dpn-vault-service.md#step-3a-configure-dpn-universal-tls-dpn-tls-cd) |
| 3 | **Vault credentials available** | Either `VAULT-TOKEN` (root token, stored in Key Vault by the Vault init stage) or, if using the recommended AppRole method, `VAULT-APPROLE-SECRET-ID` plus a `role_id` — see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication). `tls-auth-secret` (from `dpn-tls-cd`) supplies the truststore password either way |
| 4 | **AKS cluster** + (if using Azure Key Vault for secrets) a **user-assigned managed identity** and the **Secrets Store CSI driver** | Required when `keyvault.enabled: true` |
| 5 | **OAuth2 client ID and Management Node URL** | Received from DSM during onboarding to establish the DPN connection — authentication is JWT-based, no client secret is issued |
| 6 | **Certificate Manager container image available** | Built via the DSI-provided CI process or obtained prebuilt from the DSI GitHub Container Registry (GHCR). Its tag is supplied to the CD pipeline as `imageTag` (see the CI/CD overview in [Common Configuration](00-common-dpn-configuration.md#continuous-integration-ci)) |
| 7 | **`config/<env>-<cluster>.json` and `values-<env>-<cluster>.yaml` populated** | See [Pre-Deployment Configuration](#step3-environment-configuration) |

> **No shared file share required.** Unlike earlier releases, the Certificate Manager does not need a provisioned Azure File Share or `azure-fileshare-secret` — it builds the mTLS keystore/truststore in memory directly from Vault. See [Step2](#step2-configure-vault-authentication) and the note in [Overview](#overview).

> **Azure DevOps pipeline setup (one-time):** Before running the CD pipeline, complete [Azure DevOps Configuration](00-common-dpn-configuration.md#step2-azure-devops-configuration) — the pipeline **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), set up the Azure **service connection**, and populate `config/<env>-<cluster>.json`.

## Step2: Configure Vault Authentication

The Certificate Manager reads and writes its certificate material directly in Vault — there is no file share to provision. What you do need to decide is **how the Certificate Manager authenticates to Vault**:

| Method | `vault.authentication` | Notes |
|--------|------------------------|-------|
| Root token | `TOKEN` | Simplest to bootstrap with, but the token has full access to Vault. Kept for backward compatibility; see [Configure DPN Vault Service](01-configure-dpn-vault-service.md#step-3b-configuration-to-initialise-vault-vault-https-cd) |
| **AppRole** (recommended, chart default) | `APPROLE` | Scoped, short-lived credentials specific to the Certificate Manager. Provisioned by the `vault-approle-setup-cd` pipeline — see [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended) |

To switch to AppRole once the identity has been provisioned, set in `values-<env>-<cluster>.yaml`:

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

Copy `values.yaml` (reference — do not edit directly) to `values-<env>-<cluster>.yaml` and set the parameters below. The CD pipeline resolves `values-<env>-<cluster>.yaml` from the environment and cluster you select at runtime.

```text
Root-Repository
  └── charts
        └── certificate-manager
              ├── values.yaml                 <- Reference file; do not edit directly
              ├── values-<env>-<cluster>.yaml <- Your environment overrides
```

DSI proposes only the selective changes below; other parameters may be customised if required. All of these map to container environment variables via the chart ConfigMap.

**Core deployment**

| Parameter | Put here | Example |
|-----------|----------|---------|
| `managementNode.baseUrl` | The DSM Management Node URL DSI gave you during onboarding — see [Common Configuration, Step1](00-common-dpn-configuration.md#step1-dsi-dsm-endpoint-configuration) for your environment's endpoint | `https://management.dsm01.dsipreprod1.neso.energy` |

**OAuth2 (Management Node authentication)**

| Parameter | Put here | Example |
|-----------|----------|---------|
| `oauth2.clientId` | The Client ID DSM issued you during onboarding | `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee` |
| `oauth2.tokenUri` | The Authentication endpoint DSI gave you — same table as `managementNode.baseUrl` above, path `/realms/management-node/protocol/openid-connect/token` | `https://auth-mtls.dsm01.dsipreprod1.neso.energy/realms/management-node/protocol/openid-connect/token` |

**Vault connectivity** (see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication))

| Parameter | Put here | Example |
|-----------|----------|---------|
| `vault.uri` | Fixed — your Vault service's in-cluster HTTPS address, substituting your `NAMESPACE` | `https://vault-https.ns-dpn-01.svc.cluster.local:8200` |
| `vault.authentication` | `APPROLE` (recommended, and the chart's own default) or `TOKEN` | `APPROLE` |
| `vault.authRole` | Fixed — leave as the chart default | `certificate-manager` |
| `vault.pkiMount` / `vault.secretPath` | Fixed — leave as the chart default | `pki-client` / `pki-client/node-net/client` |
| `vault.appRole.role` | Fixed — leave as the chart default | `certificate-manager` |
| `vault.appRole.roleId` | The `role_id` printed when you ran `vault-approle-setup-cd` ([Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended)) — not sensitive, safe to commit | `27df8420-2cd2-5086-672e-04b28cecd81c` |
| `vault.appRole.mountPath` | Fixed — leave as the chart default | `approle` |
| `certIdent.keystoreAlias` | Fixed — leave as the chart default | `federator` |

**Certificate subject** (used by the Certificate Manager to generate its CSR)

| Parameter | Put here | Example |
|-----------|----------|---------|
| `cert.subject.country` | Your organisation's country code | `UK` |
| `cert.subject.org` | Your organisation's name or abbreviation — display only, not validated by DSM | `NESO` |
| `cert.subject.cn` | A label identifying this DPN node — your choice | `dpn01.myorg.example.com` |
| `cert.subject.altNames` | Comma-separated, **no spaces**: every producer/consumer hostname your organisation exposes — your own externally-resolvable DNS names other DPNs will connect to, across **both** the gRPC Federator and (if deployed) the REST Federator Gateway | `producer.dpn01.myorg.example.com,consumer.dpn01.myorg.example.com,producer-rest01.dpn01.myorg.example.com` |
| `cert.renewalThresholdDays` | Renew automatically once the certificate's remaining validity drops below this many days — leave at the default unless advised otherwise | `60` |

> **In-memory keystore — no `certDest`/`mtls`/`fileShare` parameters.** Earlier chart versions wrote P12 files to a shared file share and exposed `certDest.*`/`mtls.*`/`fileShare.*` values to configure that path. These no longer exist: the keystore/truststore are built in memory with an ephemeral password and handed directly to the application — there is nothing to point at a file path or a storage account.

**OTel Collector authentication**

| Parameter | Put here | Example |
|-----------|----------|---------|
| `otel.oauth2.enabled` | Leave `true` — already on by default | `true` |
| `otel.oauth2.tokenUri` | Fixed — your Keycloak's in-cluster token endpoint, substituting your `NAMESPACE` | `https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| `otel.oauth2.clientId` | Fixed — leave as the chart default | `dpn-service-client` |

No new secret is provisioned for this — the client secret is read from the pre-existing `dpn-keycloak-secrets` Kubernetes secret (key `KC_SERVICE_CLIENT_SECRET`), the same one the gRPC Federator Gateway already uses for its own Redis/Kafka OAuth. That secret is **not created by this chart** — it's produced by the DPN Authentication Service's own `SecretProviderClass` and must already exist in this component's namespace.

**Azure Key Vault**

| Parameter | Put here | Example |
|-----------|----------|---------|
| `keyvault.name` | Your Azure Key Vault's name — same as `KEY_VAULT_NAME` in the config JSON | `kv-my-dpn` |
| `keyvault.clientID` | Client ID of the managed identity from [Configure DPN Vault Service, Step 1, Prerequisite 4](01-configure-dpn-vault-service.md#step-1-prerequisites-before-vault-can-be-deployed) | `ffffffff-1111-2222-3333-444444444444` |
| `keyvault.tenantId` | Your Azure AD tenant ID | `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee` |
| `vaultTruststore.secretName` | Fixed — leave as the chart default; this secret is created automatically by `dpn-tls-cd` | `cert-manager-truststore` |
| `existingSecret.name` | Fixed — leave as the chart default when `keyvault.enabled: true` | `certificate-manager-secrets` |

### Step3b: Configure Secrets

Two independent secrets are involved — the chart needs both, but they're populated differently and are not alternatives to each other.

#### Vault authentication credential (`certificate-manager-secrets`)

Holds whichever of `VAULT_TOKEN` / `VAULT_APPROLE_SECRET_ID` matches the `vault.authentication` method you chose in [Step2](#step2-configure-vault-authentication). Choose **one** of the following two ways to populate it:

**Option A — Through Azure Key Vault (`keyvault.enabled: true`)**

The `SecretProviderClass` pulls the matching row below from `<keyvault.name>` into the `certificate-manager-secrets` Kubernetes secret. Also set `existingSecret.name: certificate-manager-secrets` so the chart uses this CSI-managed secret instead of creating its own:

| AKV Secret | Kubernetes secret / key | Purpose | Example (placeholder) |
|------------|-------------------------|---------|-----------------------|
| `VAULT-APPROLE-SECRET-ID` *(recommended)* | `certificate-manager-secrets` / `VAULT_APPROLE_SECRET_ID` | AppRole secret-id for the Certificate Manager, from `vault-approle-setup-cd` | `<generated secret-id>` |
| `VAULT-TOKEN` | `certificate-manager-secrets` / `VAULT_TOKEN` | Root token of the DPN HashiCorp Vault (from Vault init) — only used when `vault.authentication: TOKEN` | `hvs.xxxxxxxxxxx` |

> **Note:** `VAULT-APPROLE-SECRET-ID` is produced by the `vault-approle-setup-cd` pipeline (see [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended)). `VAULT-TOKEN` is produced during Vault setup by the Vault init stage (`storeRootTokenInAkv: true`) and is only needed if you have not migrated to AppRole. Confirm whichever you use exists in Key Vault before deploying.

**Option B — Directly in the values file (no Azure Key Vault / CSI driver needed)**

Leave `keyvault.enabled: false` and `existingSecret.name` empty, and instead set the value directly in `values-<env>-<cluster>.yaml`:

```yaml
secrets:
  vaultAppRoleSecretId: "<generated secret-id>"   # when vault.authentication: APPROLE
  vaultToken: ""                                  # when vault.authentication: TOKEN
```

The chart then creates its **own** Kubernetes secret, named `<fullnameOverride>-secrets` (`dpn-certificate-manager-secrets` with the default `fullnameOverride`) — simplest to bootstrap with, but the plaintext secret then lives in the values file, so treat that file as sensitive and prefer Option A once Key Vault is available.

#### Vault HTTPS truststore (`cert-manager-truststore`)

The Vault HTTPS truststore (`truststore.jks`) is loaded into the Kubernetes secret named by `vaultTruststore.secretName` (default `cert-manager-truststore`) and mounted at `vaultTruststore.mountPath`. This secret is **created automatically by the `dpn-tls-cd` pipeline** regardless of which option above you chose — no manual `kubectl create secret` is required.

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

The pipeline runs three stages: **Validate** (`helm lint` + dry-run) → **Approval** → **Deploy** (`helm upgrade --install`) → **Verify** (rollout status + keystore health check).

Runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `ServiceConnection` | Azure service connection for your environment |
| `environment` | Your target environment; resolves `config/<env>-<cluster>.json` and `values-<env>-<cluster>.yaml` |
| `dpnCluster` | Target DPN cluster — `dpn01` or `dpn02` (pdev/ptest/puat only ever use `dpn01`) |
| `imageTag` | Tag (Build ID) of the Certificate Manager image to deploy — from the CI build or the prebuilt DSI image |

> **Note (Vault dependency):** Deploy the Certificate Manager only after Vault is fully set up — this pipeline has **no Vault-init toggle of its own**; KV v2 at `pki-client` is enabled entirely by `vault-https-cd`'s own VaultInit stage (see [Configure DPN Vault Service, Step 3B](01-configure-dpn-vault-service.md#step-3b-configuration-to-initialise-vault-vault-https-cd)). If that hasn't run yet, the renewal/sync jobs will fail until it has.

---
## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 | 
