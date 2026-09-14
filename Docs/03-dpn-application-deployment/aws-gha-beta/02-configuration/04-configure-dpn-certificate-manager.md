# DPN Certificate Manager Configuration

This section describes how to configure and deploy the **DPN Federator Certificate Manager (CLM)** in a single target environment. The Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for the Federator Gateway — it renews the DSM-signed certificate and builds the keystore/truststore P12 files used for mutual TLS (mTLS).

> **Depends on Vault.** The Certificate Manager **cannot run without the DPN HashiCorp Vault service**. Vault must already be deployed, initialised (KV v2 enabled at `pki-client`), and loaded with the certificate bundle before you deploy the Certificate Manager. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md).

> **Environment and cluster:** These instructions target one `<environment>`/`<cluster>` combination. Substitute your own values wherever you see `<environment>`/`<cluster>` (for `.github/config/aws/<environment>-<cluster>.json` and the chart's `values/aws/<environment>-<cluster>.yaml`).

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

> **No shared file share.** No PV/PVC is created by the `certificate-manager` chart on this path — the `mountCertFileShare`-style flags some values files retain are for backward compatibility only.

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
| 2 | **`cert-manager-truststore` Kubernetes secret present** | Holds `truststore.jks` used to trust the Vault HTTPS endpoint. Created automatically by the `dpn-vault-tls-bootstrap-cd.yml` workflow |
| 3 | **Vault credentials available** | `VAULT-TOKEN` (root token, stored in Azure Key Vault by the Vault init step) — see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication) for why AppRole isn't an option yet on this path. `VAULT-TRUSTSTORE-PASSWORD` (from the Vault bootstrap) is required either way |
| 4 | **EKS cluster** + a Key Vault-reachable identity | Required when `keyvault.enabled: true` — the org's central secrets store is Azure Key Vault regardless of target cloud |
| 5 | **OAuth2 client ID, client secret, and Management Node URL** | Received from DSM during onboarding to establish the DPN connection |
| 6 | **Certificate Manager container image available** | Built via the DSI-provided CI process or obtained prebuilt from the DSI GitHub Container Registry (GHCR). Its tag is supplied to the CD workflow as `imageTag` (see the CI/CD overview in [Common Configuration](00-common-dpn-configuration.md#continuous-integration-ci)) |
| 7 | **Config JSON and values file populated** | See [Pre-Deployment Configuration](#step3-environment-configuration) |

> **No shared file share required.** The Certificate Manager does not need a provisioned file share — it builds the mTLS keystore/truststore in memory directly from Vault. See [Step2](#step2-configure-vault-authentication) and the note in [Overview](#overview).

> **One-time setup:** Before running the CD workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) — the workflow **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), and populate `.github/config/aws/<environment>-<cluster>.json`.

## Step2: Configure Vault Authentication

The Certificate Manager reads and writes its certificate material directly in Vault — there is no file share to provision. What you do need to decide is **how the Certificate Manager authenticates to Vault**:

| Method | `vault.authentication` | Notes |
|--------|------------------------|-------|
| Root token | `TOKEN` | **Only supported method on this path today.** The token has full access to Vault; see [Configure DPN Vault Service, Step 3B](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml) |
| AppRole (chart supports it; not yet automated here) | `APPROLE` | The chart itself defaults to `APPROLE` and scoped, short-lived credentials are the recommended long-term design — but the GitHub Actions workflow that provisions the AppRole identity (`setup-approle.sh`) doesn't exist yet for this airgap path. See [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-planned-not-yet-available). **Set `vault.authentication: TOKEN` explicitly** until that workflow is available, or run `setup-approle.sh` by hand against the Vault pod if you want AppRole now |

Once the AppRole-provisioning workflow is available, switching over will look like this in the environment/cluster values file:

```yaml
vault:
  authentication: APPROLE
  appRole:
    roleId: <role_id from the AppRole setup output>
```

The generated `secret-id` would be delivered as the Key Vault secret `VAULT-APPROLE-SECRET-ID`, synced into the `certificate-manager-secrets` Kubernetes secret by the CSI driver — the same mechanism already used for `VAULT-TOKEN` (see [Step3b: Configure Secrets](#step3b-configure-secrets)). `VaultAuthStartupValidator` fails the deployment fast if `authentication: APPROLE` is set but the role-id/secret-id are missing — another reason to keep `authentication: TOKEN` until the AppRole identity actually exists.

---

## Step3: Environment Configuration

The following configurations are required in each environment: 

- `Helm values`
- `secrets` 

Organisations must change the default passwords during secret set up and follow periodic rotation of secrets.

### Step3a: Set Up Helm Values

Set the parameters below in your environment/cluster's values file. The CD workflow resolves `values/aws/<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
dpn-federator-cert-manager/
  └── charts/
        └── certificate-manager/
              ├── values.yaml                              <- Reference file; do not edit directly
              └── values/aws/<environment>-<cluster>.yaml <- Your environment overrides
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
| `vault.authentication` | `TOKEN` (only supported method on this path today; the chart itself defaults to `APPROLE` — see [Step2](#step2-configure-vault-authentication)) | `TOKEN` |
| `vault.pkiMount` / `vault.secretPath` | KV v2 mount and path holding the certificate material | `pki-client` / `pki-client/node-net/client` |
| `vault.appRole.roleId` | Non-sensitive role-id, from the AppRole setup output (once that workflow exists) | `<role_id>` |
| `certIdent.keystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

**Certificate subject** (used by the Certificate Manager to generate its CSR)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cert.subject.country` | CSR subject Country (C) | `UK` |
| `cert.subject.org` | CSR subject Organisation (O) | `<organisation abbreviation>` |
| `cert.subject.cn` | CSR subject Common Name (CN) | `dpn-<env>-01` |
| `cert.subject.altNames` | Comma-separated SANs — every producer/consumer endpoint this node exposes, across **both** the gRPC Federator and (if deployed) the REST Federator Gateway | `producer.dpn01.dsiXXX.neso.energy,consumer.dpn01.dsiXXX.neso.energy,producer-rest01.dpn01.dsiXXX.neso.energy` |
| `cert.renewalThresholdDays` | Renew automatically once the certificate's remaining validity drops below this many days | `100` |

> **In-memory keystore — no `certDest`/`mtls`/`fileShare` parameters.** The keystore/truststore are built in memory with an ephemeral password and handed directly to the application — there is nothing to point at a file path or a storage account.

**Azure Key Vault** (still the org's central secrets store, used cross-cloud)

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | AKV name, managed-identity/service-principal client ID, and tenant ID — update these in the values file | `kv-dpn-<env>-<region>-<seq>` / `<client-id>` / `<tenant-id>` |
| `vaultTruststore.secretName` | Pre-existing Kubernetes secret holding `truststore.jks` to trust Vault's HTTPS endpoint | `cert-manager-truststore` |
| `existingSecret.name` | Use a pre-created Kubernetes secret instead of the chart-managed one (required when `keyvault.enabled: true`) | `certificate-manager-secrets` |

### Step3b: Configure Secrets

#### Option A — Through Azure Key Vault (`keyvault.enabled: true`)

The `SecretProviderClass` pulls the following from `<keyvault.name>` into the `certificate-manager-secrets` Kubernetes secret. Populate the row matching the `vault.authentication` method you chose in [Step2](#step2-configure-vault-authentication) — the other is unused:

| AKV Secret | Kubernetes secret / key | Purpose | Example (placeholder) |
|------------|-------------------------|---------|-----------------------|
| `VAULT-APPROLE-SECRET-ID` *(not yet available)* | `certificate-manager-secrets` / `vaultAppRoleSecretId` | AppRole secret-id for the Certificate Manager — would come from the AppRole-setup workflow once it exists; see [Step2](#step2-configure-vault-authentication) | `<generated secret-id>` |
| `VAULT-TOKEN` *(use this today)* | `certificate-manager-secrets` / `vaultToken` | Root token of the DPN HashiCorp Vault (from Vault init) — required while `vault.authentication: TOKEN` | `hvs.xxxxxxxxxxx` |
| `OAUTH2-CLIENT-SECRET` | `certificate-manager-secrets` / `oauth2ClientSecret` | Client secret for the Management Node OAuth2 client (if `oauth2.authMode` requires one) | `<client-secret>` |

> **Note:** `VAULT-TOKEN` is produced during Vault setup by the `dpn-vault-https-cd.yml` workflow's Vault Init step (`storeRootTokenInAkv: true`) — confirm it exists in Key Vault before deploying. `VAULT-APPROLE-SECRET-ID` is not produced by anything yet on this path (see [Step2](#step2-configure-vault-authentication)).

#### Option B - Through Vault truststore (Kubernetes secret)

The Vault HTTPS truststore (`truststore.jks`) is loaded into the Kubernetes secret named by `vaultTruststore.secretName` (default `cert-manager-truststore`) and mounted at `vaultTruststore.mountPath`. This secret is **created automatically by the `dpn-vault-tls-bootstrap-cd.yml` workflow** — no manual `kubectl create secret` is required.

---

## Step4: Setup Deployment Configuration

The Certificate Manager is deployed with the `dpn-certificate-manager-cd.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`:

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        └── dpn-certificate-manager-cd.yml
```

Trigger it via **Actions → DPN CD - Certificate Manager → Run workflow**. The workflow runs `helm lint` + dry-run, then `helm upgrade --install`, followed by a rolling restart (`kubectl rollout restart deployment/dpn-certificate-manager`) and a rollout status check. There is no approval-gate concept built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test`; resolves `.github/config/aws/<environment>-<cluster>.json` and `values/aws/<environment>-<cluster>.yaml` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `imageTag` | Tag of the Certificate Manager image to deploy — from the CI build or the prebuilt DSI image |

> **Note (Vault dependency):** Deploy the Certificate Manager only after Vault is fully set up — this workflow does not initialise Vault itself; that happens in [Step 3B of the Vault workflow](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml). If Vault's KV v2 engine is not yet enabled, the renewal/sync jobs will fail until it is.

---
## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 31-Jul-2026 | DSI Assurance    | Final  | V1.0.0 |
