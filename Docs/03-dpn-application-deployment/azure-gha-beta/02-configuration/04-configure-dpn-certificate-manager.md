Release : 2.1.0 - Oct 2026

# DPN Certificate Manager Configuration

This section describes how to configure and deploy the **DPN Federator Certificate Manager (CLM)** in a single target environment. The Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for the Federator Gateway — it renews the DSM-signed certificate and builds the keystore/truststore P12 files used for mutual TLS (mTLS).

> **Depends on Vault.** The Certificate Manager **cannot run without the DPN HashiCorp Vault service**. Vault must already be deployed, initialised (KV v2 enabled at `pki-client`), and loaded with the certificate bundle before you deploy the Certificate Manager. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md).

> **Environment and cluster:** These instructions target one `<environment>`/`<cluster>` combination.
---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Vault Authentication](#step2-configure-vault-authentication)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Set Up Helm Values](#step3a-set-up-helm-values)
  - [Step3b: Configure Secrets](#step3b-configure-secrets)
    - [Option A - Through Azure Key Vault](#option-a---through-azure-key-vault)
    - [Option B - Through Vault truststore (Kubernetes secret)](#option-b---through-vault-truststore-kubernetes-secret)
- [Step4: Setup Deployment Configuration](#step4-setup-deployment-configuration)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager runs as a headless daemon (no HTTP endpoints) executing two scheduled jobs:

- **Renewal job** — obtains/renews the DSM-signed certificate via the Management Node PKI API and persists the material in Vault.
- **Sync job** — refreshes the mTLS keystore/truststore from the Vault material. By default both are built **in memory** directly from certificate material read from Vault at start-up/refresh — no shared file share is used, and no P12 files are ever written to disk.

The Federator Gateway Server and Client read the same certificate material directly from Vault and build their own in-memory keystore/truststore the same way — they no longer mount a shared volume to pick up P12 files from the Certificate Manager.

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
| 2 | **`cert-manager-truststore` and `tls-auth-secret` Kubernetes secrets present** | `cert-manager-truststore` holds `truststore.jks` used to trust the Vault HTTPS endpoint; `tls-auth-secret` holds its password (`TRUSTSTORE_PASSWORD`), which the Deployment reads directly. Both are created by `dpn-gha-tls-cd.yml`; `dpn-gha-vault-tls-bootstrap-cd.yaml` creates `cert-manager-truststore` only — see [Configure DPN Vault Service, Step 3A](01-configure-dpn-vault-service.md#step-3a-configure-bootstrap-vault-tls-dpn-gha-vault-tls-bootstrap-cdyml) |
| 3 | **Vault credentials available** | The Vault auth credential in Key Vault — `VAULT-APPROLE-SECRET-ID` (when `vault.authentication: APPROLE`) or `VAULT-TOKEN` (root token, when `TOKEN`) — see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication) and [Step3b](#step3b-configure-secrets) |
| 4 | **AKS cluster** + a user-assigned managed identity that can read those Key Vault secrets | Used by the chart's Azure Key Vault `SecretProviderClass` (`useVMManagedIdentity`, `keyvault.clientID`) when `keyvault.enabled: true` |
| 5 | **OAuth2 client ID and Management Node URL** | Received from DSM during onboarding to establish the DPN connection — authentication is JWT-based, no client secret is issued |
| 6 | **Certificate Manager container image available** | Prebuilt from the DSI GitHub Container Registry (GHCR). Its tag is supplied to the CD workflow as `imageTag` (see the CI/CD overview in [Common Configuration](00-common-dpn-configuration.md#continuous-integration-ci)) |
| 7 | **Config JSON and values file populated** | See [Pre-Deployment Configuration](#step3-environment-configuration) — the Azure values files enable the Key Vault path with `keyvault.enabled: true` |

> **No shared file share required.** The Certificate Manager does not need a provisioned file share — it builds the mTLS keystore/truststore in memory directly from Vault, and the chart creates no PV/PVC.

> **One-time setup:** Before running the CD workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) — the workflow **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), and populate `.github/config/azure/<environment>-<cluster>.json` in the `dpn-federator-certificate-manager` repository.

## Step2: Configure Vault Authentication

The Certificate Manager reads and writes its certificate material directly in Vault. What you do need to decide is **how the Certificate Manager authenticates to Vault**:

| Method | `vault.authentication` | Notes |
|--------|------------------------|-------|
| Root token | `TOKEN` | The token has full access to Vault; see [Configure DPN Vault Service, Step 3B](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml) |
| AppRole | `APPROLE` | The chart itself defaults to `APPROLE`, and scoped, short-lived credentials are the recommended design (the shipped Azure values files use `APPROLE`). The provisioning workflow, `dpn-gha-certificate-manager-role-id-creation.yaml` (**DPN CD - Certificate Manager Role ID Creation (Vault AppRole Setup)**) in the `dpn-federator-certificate-manager` repository, takes `component` (`certificate-manager` — the only option in this repository's copy), `environment`, `cluster` and `cloud: azure` — see below |

`dpn-gha-certificate-manager-role-id-creation.yaml` resolves the Vault pod (`app=dpn-vault-https`), reads the admin token from Key Vault (`VAULT-TOKEN` in `KEY_VAULT_NAME`), and runs `vault/setup-approle.sh` with `vault/certificate-manager-policy.hcl` inside the Vault pod to enable the `approle` auth method, write a least-privilege policy scoped to the Certificate Manager's own paths, create/update its AppRole role, and publish the generated **secret-id**. On Azure:

| Value | Azure Key Vault location | Consumed by |
|---|---|---|
| `secret-id` (sensitive) | `VAULT-APPROLE-SECRET-ID` (355-day expiry, to satisfy Key Vault's maximum-validity policy) | The chart's Azure Key Vault `SecretProviderClass`, synced into the `certificate-manager-secrets` Kubernetes secret |
| `role-id` (not sensitive) | Not stored in Key Vault — printed in the workflow run summary | You copy it into `vault.appRole.roleId` in `charts/certificate-manager/values/azure/<environment>-<cluster>.yaml` |

**On Azure you must copy the role-id into the values file yourself.** `dpn-gha-certificate-manager-cd.yaml` does not read `vault.appRole.roleId` from Key Vault and inject it — it deploys the Helm chart exactly as the values file specifies. Copy the `role_id` printed in the setup workflow's run summary into `vault.appRole.roleId`. To switch over, set in the environment/cluster values file:

```yaml
vault:
  authentication: APPROLE
  appRole:
    roleId: <role_id from the AppRole setup workflow's output>   # required on Azure — the CD workflow does not resolve this for you
```

The `secret-id` itself is delivered into the `certificate-manager-secrets` Kubernetes secret by the CSI driver — the same mechanism already used for `VAULT-TOKEN`/`VAULT_TOKEN` (see [Step3b: Configure Secrets](#step3b-configure-secrets)). `VaultAuthStartupValidator` fails the deployment fast if `authentication: APPROLE` is set but the role-id/secret-id are missing. **The AppRole secret-id does not expire** (`secret_id_ttl=0`), but the Key Vault copy is stamped with a 355-day expiry to satisfy governance policy — re-run the setup workflow before that expiry to rotate it, then redeploy the Certificate Manager to pick up the refreshed value.

---

## Step3: Environment Configuration

The following configurations are required in each environment:

- `Helm values`
- `secrets`

Organisations must change the default passwords during secret set up and follow periodic rotation of secrets.

### Step3a: Set Up Helm Values

Set the parameters below in your environment/cluster's values file (the workflow's `CHART_DIR` is `charts/certificate-manager`, release `dpn-certificate-manager`). The CD workflow resolves `charts/certificate-manager/values/azure/<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
dpn-federator-certificate-manager/
  └── charts/
        └── certificate-manager/
          └── values/
              └── azure/
                └── <environment>-<cluster>.yaml <- Your environment overrides
```

DSI proposes only the selective changes below; other parameters may be customised if required. All of these map to container environment variables via the chart ConfigMap.

**Core deployment**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `namespace` | Kubernetes namespace | `ns-dpn-01` |
| `image.repository` | Complete URL of the Certificate Manager image | `ghcr.io/energy-dsi/dpn-federator-certificate-manager` |
| `managementNode.baseUrl` | DSI DSM Management Node URL for your environment | `https://management.dsm01.dsiXXX.neso.energy` |

**OAuth2 (Management Node authentication)**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `oauth2.clientId` | Client ID received from DSM | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `oauth2.tokenUri` | IDP token URL received from DSM | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| `oauth2.authMode` | Client authentication mode — the chart default is `client_credentials`; the shipped Azure values files use `private_key_jwt` (no client secret needed) | `private_key_jwt` |

**Vault connectivity** (see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication))

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `vault.uri` | HTTPS address of the DPN Vault service | `https://vault-https.<namespace>.svc.cluster.local:8200` |
| `vault.authentication` | `TOKEN` or `APPROLE` — the chart itself defaults to `APPROLE`; see [Step2](#step2-configure-vault-authentication) | `APPROLE` |
| `vault.pkiMount` / `vault.secretPath` | KV v2 mount and path holding the certificate material | `pki-client` / `pki-client/node-net/client` |
| `vault.appRole.roleId` | Non-sensitive role-id, from the AppRole setup workflow's output | `<role_id>` |
| `certIdent.keystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

**Certificate subject** (used by the Certificate Manager to generate its CSR)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cert.subject.country` | CSR subject Country (C) | `UK` |
| `cert.subject.org` | CSR subject Organisation (O) | `<organisation abbreviation>` |
| `cert.subject.cn` | CSR subject Common Name (CN) | `dpn-<env>-01` |
| `cert.subject.altNames` | Comma-separated SANs — every producer/consumer endpoint this node exposes, across **both** the gRPC Federator and (if deployed) the REST Federator Gateway | `producer.dpn01.dsiXXX.neso.energy,consumer.dpn01.dsiXXX.neso.energy,producer-rest01.dpn01.dsiXXX.neso.energy` |
| `cert.renewalThresholdDays` | Renew automatically once the certificate's remaining validity drops below this many days | `60` |

> **In-memory keystore — `certDest`/`mtls`/`fileShare` parameters don't exist.** The keystore/truststore are built in memory with an ephemeral password and handed directly to the application — there is nothing to point at a file path or a storage account. The chart creates no PV/PVC and runs without a dedicated ServiceAccount (no workload identity is required); Key Vault access goes through the user-assigned managed identity configured under `keyvault.*` below.

**OTel Collector authentication**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `otel.oauth2.enabled` | Attach an `Authorization: Bearer` token to OTLP export, authenticated via the `dpn-service-client` Keycloak client — **on by default**, since that client is already registered in Keycloak for every environment | `true` |
| `otel.oauth2.tokenUri` | Keycloak token endpoint — set per `values/azure/<environment>-<cluster>.yaml`, same host/realm as the Federator Gateway's own `kafka.oauth.tokenEndpointUrl` for that environment | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| `otel.oauth2.clientId` | Keycloak client ID — same value in every environment | `dpn-service-client` |

No new secret is provisioned for this — the client secret is read from the pre-existing `dpn-keycloak-secrets` Kubernetes secret (key `KC_SERVICE_CLIENT_SECRET`), the same one the Federator Gateway already uses for its own Kafka OAuth (see the [Overview](#overview) note in [Configure DPN Federator Gateway](05-configure-dpn-federator-gateway.md)). That secret is **not created by this chart** — it's produced by the DPN Authentication Service's own deployment and must already exist in this component's namespace.

**Azure Key Vault** (native Azure backend — used when `keyvault.enabled: true`)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `keyvault.enabled` | Render the Azure Key Vault `SecretProviderClass` `dpn-certificate-manager-kv-secrets` (chart default `false`; the shipped Azure values files set `true`) | `true` |
| `keyvault.clientID` | Client ID of the user-assigned managed identity the CSI driver uses (`useVMManagedIdentity`) | `<azure-client-id>` |
| `keyvault.name` | Azure Key Vault holding the Certificate Manager's Vault auth credential — Key Vault objects are flat names (see [Step3b](#step3b-configure-secrets)) | `<KEY_VAULT_NAME>` |
| `keyvault.tenantId` | Azure AD tenant ID | `<tenant-id>` |
| `existingSecret.name` | Use the CSI-synced secret instead of a chart-created one — set to the name the `SecretProviderClass` syncs to | `certificate-manager-secrets` |
| `vaultTruststore.secretName` | Kubernetes secret holding the Vault HTTPS truststore (see [Option B](#option-b---through-vault-truststore-kubernetes-secret)) | `cert-manager-truststore` |

### Step3b: Configure Secrets

#### Option A - Through Azure Key Vault

When `keyvault.enabled: true`, the chart renders the `SecretProviderClass` `dpn-certificate-manager-kv-secrets` (`provider: azure`, using the user-assigned managed identity in `keyvault.clientID`). It pulls exactly one Key Vault object — the Vault auth credential matching `vault.authentication` — and syncs it into the `certificate-manager-secrets` Kubernetes secret. Set `existingSecret.name: certificate-manager-secrets` so the Deployment reads that secret, as the shipped Azure values files do:

| Key Vault object | Kubernetes secret / key | Purpose |
|---|---|---|
| `VAULT-APPROLE-SECRET-ID` *(when `vault.authentication: APPROLE`)* | `VAULT_APPROLE_SECRET_ID` | AppRole secret-id, from `dpn-gha-certificate-manager-role-id-creation.yaml` (see [Step2](#step2-configure-vault-authentication)) |
| `VAULT-TOKEN` *(when `vault.authentication: TOKEN`)* | `VAULT_TOKEN` | Root token of the DPN HashiCorp Vault, stored by `dpn-gha-vault-https-cd.yaml` with `storeRootTokenInSecretsBackend: true` |

> **Not pulled from Key Vault.** The Vault truststore password is read directly from the `tls-auth-secret` Kubernetes secret (key `TRUSTSTORE_PASSWORD`, created by `dpn-gha-tls-cd.yml`) into `VAULT_SSL_TRUST_STORE_PASSWORD` and `OTEL_TRUSTSTORE_PASSWORD`. When `otel.oauth2.enabled` is `true`, `OTEL_OAUTH2_CLIENT_SECRET` comes from `dpn-keycloak-secrets` (key `KC_SERVICE_CLIENT_SECRET`). `MTLS-KEYSTORE-PASSWORD` / `MTLS-TRUSTSTORE-PASSWORD` are no longer read (the mTLS keystore/truststore use an ephemeral in-memory password), and `OAUTH2-CLIENT-SECRET` is not read because the shipped values use `oauth2.authMode: private_key_jwt`.

#### Option B - Through Vault truststore (Kubernetes secret)

The Vault HTTPS truststore (`truststore.jks`) is loaded into the Kubernetes secret named by `vaultTruststore.secretName` (set to `cert-manager-truststore` in the shipped Azure values files; the chart default is empty) and mounted at `vaultTruststore.mountPath` (default `/app/truststore`). This secret is **created automatically by the `dpn-gha-tls-cd.yml` workflow** (or by `dpn-gha-vault-tls-bootstrap-cd.yaml`) — no manual `kubectl create secret` is required. This is independent of which secrets backend (Option A or B) supplies the rest of the application secrets.

---

## Step4: Setup Deployment Configuration

The Certificate Manager is deployed with the `dpn-gha-certificate-manager-cd.yaml` GitHub Actions workflow in `dpn-federator-certificate-manager`:

```text
dpn-federator-certificate-manager/
└── .github/
    └── workflows/
        ├── dpn-gha-certificate-manager-cd.yaml
        ├── dpn-gha-certificate-manager-rollback.yaml    <- DPN Rollback - Certificate Manager
        └── dpn-gha-certificate-manager-uninstall.yaml   <- DPN Uninstall - Certificate Manager
```

Trigger it via **Actions → DPN CD - Certificate Manager → Run workflow**. The workflow runs **Applied Parameters** (rejects `imageTag`/`imageRepository` values with leading/trailing whitespace) → **Read Deployment Config** → **Cloud Login** (Azure OIDC login and AKS context via `.github/actions/cloud-login`) → **Verify Cluster Access** → `helm lint` + dry-run → `helm upgrade --install dpn-certificate-manager charts/certificate-manager`, followed by a rolling restart (`kubectl rollout restart deployment/dpn-certificate-manager`) and a rollout status check. There is no approval-gate concept built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.


`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test`; resolves `.github/config/azure/<environment>-<cluster>.json` and `charts/certificate-manager/values/azure/<environment>-<cluster>.yaml` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `imageTag` | Tag of the Certificate Manager image to deploy — from the CI build or the prebuilt DSI image (required, no default) |
| `imageRepository` | Optional — overrides `image.repository` for this run only (path after `ghcr.io/energy-dsi/`) |

> **Note (Vault dependency):** Deploy the Certificate Manager only after Vault is fully set up — this workflow does not initialise Vault itself; that happens in [Step 3B of the Vault workflow](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml). If Vault's KV v2 engine is not yet enabled, the renewal/sync jobs will fail until it is.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
