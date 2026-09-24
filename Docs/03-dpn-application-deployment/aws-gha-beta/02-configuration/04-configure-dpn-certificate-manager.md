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
    - [Option A - Through AWS Secrets Manager](#option-a---through-aws-secrets-manager)
    - [Option B - Through Vault truststore (Kubernetes secret)](#option-b---through-vault-truststore-kubernetes-secret)
- [Step4: Setup Deployment Configuration](#step4-setup-deployment-configuration)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager runs as a headless daemon (no HTTP endpoints) executing two scheduled jobs:

- **Renewal job** — obtains/renews the DSM-signed certificate via the Management Node PKI API and persists the material in Vault.
- **Sync job** — refreshes the mTLS keystore/truststore from the Vault material. By default both are built **in memory** directly from certificate material read from Vault at start-up/refresh — no shared file share is used, and no P12 files are ever written to disk.

The Federator Gateway Server and Client read the same certificate material directly from Vault and build their own in-memory keystore/truststore the same way — they no longer mount a shared volume to pick up P12 files from the Certificate Manager

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
| 3 | **Vault credentials available** | `VAULT-TOKEN`/`VAULT_TOKEN` (root token) and the truststore password required either way — see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication) and [Step3b](#step3b-configure-secrets) for where each lives per secrets backend |
| 4 | **EKS cluster** + either a AWS Secrets Manager-reachable identity or an IRSA-annotated ServiceAccount | Required `secretsManager.enabled: true` |
| 5 | **OAuth2 client ID, client secret, and Management Node URL** | Received from DSM during onboarding to establish the DPN connection |
| 6 | **Certificate Manager container image available** | Prebuilt from the DSI GitHub Container Registry (GHCR). Its tag is supplied to the CD workflow as `imageTag` (see the CI/CD overview in [Common Configuration](00-common-dpn-configuration.md#continuous-integration-ci)) |
| 7 | **Config JSON and values file populated, with `cloudProvider: aws` set** | See [Pre-Deployment Configuration](#step3-environment-configuration) — the chart's own `cloudProvider` default is `azure` |

> **No shared file share required by default.** The Certificate Manager does not need a provisioned file share — it builds the mTLS keystore/truststore in memory directly from Vault. An opt-in AWS EFS-backed shared file share exists (`fileShare.create: true`) for environments that need one; see [Step2](#step2-configure-vault-authentication) and the note in [Overview](#overview).

> **One-time setup:** Before running the CD workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) — the workflow **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), and populate `.pipelines/github-actions-pipelines/config/aws/<environment>-<cluster>.json`.

## Step2: Configure Vault Authentication

The Certificate Manager reads and writes its certificate material directly in Vault. What you do need to decide is **how the Certificate Manager authenticates to Vault**:

| Method | `vault.authentication` | Notes |
|--------|------------------------|-------|
| Root token | `TOKEN` | The token has full access to Vault; see [Configure DPN Vault Service, Step 3B](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml) |
| AppRole | `APPROLE` | The chart itself defaults to `APPROLE`, and scoped, short-lived credentials are the recommended design. The provisioning workflow, `dpn-certificate-manager-role-id-creation.yml`, is available for this path and now also takes `cloud: aws` (alongside `azure`) and a `component` input (`certificate-manager` or `rest-federator`) — see below |

`dpn-certificate-manager-role-id-creation.yml` runs `scripts/vault/setup-approle.sh` inside the Vault pod (using the admin `VAULT-TOKEN`/`VAULT_TOKEN`) to write a least-privilege policy scoped to the selected component's own paths, create/update its AppRole role, and publish the generated **secret-id**. On AWS it stores both values in Secrets Manager rather than Key Vault:

| Value | AWS Secrets Manager location | Azure Key Vault location |
|---|---|---|
| `secret-id` (sensitive) | `dpn/<environment>-<cluster>/certificate-manager/VAULT_APPROLE_SECRET_ID` | `VAULT-APPROLE-SECRET-ID` (355-day expiry, to satisfy Key Vault's maximum-validity policy) |
| `role-id` (not sensitive) | `dpn/<environment>-<cluster>/certificate-manager/VAULT_APPROLE_ROLE_ID` — stored for reference/other tooling (e.g. [Step 3C of the Vault workflow](01-configure-dpn-vault-service.md#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml) fetches it programmatically) | Printed in the workflow summary for you to copy into `vault.appRole.roleId` |

**On AWS you must still copy the role-id into the values file yourself.** `dpn-certificate-manager-cd.yml` does not read `VAULT_APPROLE_ROLE_ID` from Secrets Manager and inject it — it deploys the Helm chart exactly as the values file specifies. Copy the `role_id` from the setup workflow's run summary into `vault.appRole.roleId`, the same as on Azure. To switch over, set in the environment/cluster values file:

```yaml
vault:
  authentication: APPROLE
  appRole:
    roleId: <role_id from the AppRole setup workflow's output>   # required on AWS too — the CD workflow does not resolve this for you
```

The `secret-id` itself is delivered into the `certificate-manager-secrets` Kubernetes secret by the CSI driver — the same mechanism already used for `VAULT-TOKEN`/`VAULT_TOKEN` (see [Step3b: Configure Secrets](#step3b-configure-secrets)). `VaultAuthStartupValidator` fails the deployment fast if `authentication: APPROLE` is set but the role-id/secret-id are missing. **The AppRole secret-id does not expire** (`secret_id_ttl=0`) — re-run the setup workflow periodically to rotate it, then redeploy the Certificate Manager to pick up the refreshed value.

---

## Step3: Environment Configuration

The following configurations are required in each environment: 

- `Helm values`
- `secrets` 

Organisations must change the default passwords during secret set up and follow periodic rotation of secrets.

### Step3a: Set Up Helm Values

Set the parameters below in your environment/cluster's values file. The CD workflow resolves `values-<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
dpn-federator-cert-manager/
  └── charts/
        └── certificate-manager/
              ├── values.yaml   <- Reference file; do not edit directly
              └── values-<environment>-<cluster>.yaml <- Your environment overrides
```

DSI proposes only the selective changes below; other parameters may be customised if required. All of these map to container environment variables via the chart ConfigMap.

**Core deployment**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cloudProvider` | **Set to `aws`.** Selects the AWS Secrets Manager/IRSA/EFS-fileShare path below; the chart's own default is `azure` | `aws` |
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
| `vault.authentication` | `TOKEN` or `APPROLE` — the chart itself defaults to `APPROLE`; see [Step2](#step2-configure-vault-authentication) | `TOKEN` |
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

> **In-memory keystore by default — `certDest`/`mtls` parameters don't exist.** The keystore/truststore are built in memory with an ephemeral password and handed directly to the application — there is nothing to point at a file path or a storage account, **unless** you opt into the AWS file share below.

**AWS EFS file share** (Recommended — see the [Overview](#overview) note; leave `fileShare.create: false` to use in memory certificate storage only)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `fileShare.create` | Provision the shared PVC | `false` |
| `fileShare.storageClassName` | EFS-backed StorageClass (dynamic access-point provisioning — no PV or `nodeStageSecretRef` needed, unlike the Azure File path) | `efs-sc` |
| `fileShare.size` | Requested capacity (EFS is elastic; this is nominal) | `1Gi` |
| `fileShare.pvcName` | PVC name — mounted by this chart, the Federator Server, and the Federator Client | `pvc-dpn-certs-fileshare` |

**AWS ServiceAccount / IRSA** (required when `secretsManager.enabled: true`)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `serviceAccount.create` | Create the IRSA-annotated ServiceAccount | `true` |
| `serviceAccount.name` | ServiceAccount name (default `dpn-certificate-manager`) | `dpn-certificate-manager` |
| `serviceAccount.irsaRoleArn` | IAM role ARN whose trust policy scopes `sts:AssumeRoleWithWebIdentity` to `system:serviceaccount:<namespace>:<serviceAccount.name>`, granting Secrets Manager `GetSecretValue` | `arn:aws:iam::<account-id>:role/<role-name>` |

**AWS Secrets Manager** (native AWS backend — only used when `secretsManager.enabled: true`)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `secretsManager.enabled` | Use AWS Secrets Manager instead of AKV | `true` |
| `secretsManager.secretPrefix` | Prefix under which each secret is created in Secrets Manager | `dpn/<env>-<cluster>/certificate-manager` |

### Step3b: Configure Secrets

#### Option A - Through AWS Secrets Manager

The `SecretProviderClass` pulls the following from `<secretsManager.secretPrefix>/<KEY_NAME>` into the `certificate-manager-secrets` Kubernetes secret, using the pod's IRSA identity (no dedicated role beyond `serviceAccount.irsaRoleArn` for this POC):

| Secrets Manager entry (under `secretPrefix/`) | Kubernetes secret / key | Purpose |
|---|---|---|
| `MTLS_KEYSTORE_PASSWORD` | `MTLS_KEYSTORE_PASSWORD` | Reserved for a future/manual keystore path — unused while the in-memory keystore is ephemeral |
| `MTLS_TRUSTSTORE_PASSWORD` | `MTLS_TRUSTSTORE_PASSWORD` | Same, for the truststore |
| `VAULT_TOKEN` | `VAULT_TOKEN` | Root token of the DPN HashiCorp Vault — required while `vault.authentication: TOKEN` |
| `OAUTH2_CLIENT_SECRET` | `OAUTH2_CLIENT_SECRET` | Client secret for the Management Node OAuth2 client |
| `VAULT_TRUSTSTORE_PASSWORD` | `VAULT_SSL_TRUST_STORE_PASSWORD` | Password for `truststore.jks` — same app-side env var as the Azure path above |
| `VAULT_APPROLE_SECRET_ID` *(only when `vault.authentication: APPROLE`)* | `VAULT_APPROLE_SECRET_ID` | AppRole secret-id, from `dpn-certificate-manager-role-id-creation.yml` (see [Step2](#step2-configure-vault-authentication)) |

#### Option B - Through Vault truststore (Kubernetes secret)

The Vault HTTPS truststore (`truststore.jks`) is loaded into the Kubernetes secret named by `vaultTruststore.secretName` (default `cert-manager-truststore`) and mounted at `vaultTruststore.mountPath`. This secret is **created automatically by the `dpn-gha-vault-tls-bootstrap-cd.yml` workflow** — no manual `kubectl create secret` is required. This is independent of which secrets backend (Option A or B) supplies the rest of the application secrets.

---

## Step4: Setup Deployment Configuration

The Certificate Manager is deployed with the `dpn-certificate-manager-cd.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`:

```text
root/
└── .pipelines/
    └── github-actions-pipelines/
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
| `imageRepository` | Optional — overrides `image.repository` for this run only (path after `ghcr.io/energy-dsi/`) |

> **Note (Vault dependency):** Deploy the Certificate Manager only after Vault is fully set up — this workflow does not initialise Vault itself; that happens in [Step 3B of the Vault workflow](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml). If Vault's KV v2 engine is not yet enabled, the renewal/sync jobs will fail until it is.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 | 
