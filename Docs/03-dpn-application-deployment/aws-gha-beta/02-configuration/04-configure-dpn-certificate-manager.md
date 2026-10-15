Release : 2.1.0 - Oct 2026

# DPN Certificate Manager Configuration

This section describes how to configure and deploy the **DPN Federator Certificate Manager (CLM)** in a single target environment. The Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for the Federator Gateway — it renews the DSM-signed certificate and builds the keystore/truststore P12 files used for mutual TLS (mTLS).

> **Depends on Vault.** The Certificate Manager **cannot run without the DPN HashiCorp Vault service**. Vault must already be deployed, initialised (KV v2 enabled at `pki-client`), and loaded with the certificate bundle before you deploy the Certificate Manager. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md).

> **Environment and cluster:** These instructions target one `<environment>`/`<cluster>` combination. Substitute your own values wherever you see `<environment>`/`<cluster>`.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Vault Authentication](#step2-configure-vault-authentication)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Set Up Helm Values](#step3a-set-up-helm-values)
  - [Step3b: Configure Secrets](#step3b-configure-secrets)
    - [Option A — Through AWS Secrets Manager (`secretsManager.enabled: true`)](#option-a--through-aws-secrets-manager-secretsmanagerenabled-true)
    - [Option B - Through Vault truststore (Kubernetes secret)](#option-b---through-vault-truststore-kubernetes-secret)
- [Step4: Setup Deployment Configuration](#step4-setup-deployment-configuration)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager runs as a headless daemon (no HTTP endpoints) executing two scheduled jobs:

- **Renewal job** — obtains/renews the DSM-signed certificate via the Management Node PKI API and persists the material in Vault.
- **Sync job** — refreshes the mTLS keystore/truststore from the Vault material. By default both are built **in memory** directly from certificate material read from Vault at start-up/refresh — no shared file share is used, and no P12 files are ever written to disk.

The Federator Gateway Server and Client read the same certificate material directly from Vault and build their own in-memory keystore/truststore the same way — they no longer mount a shared volume to pick up P12 files from the Certificate Manager, **unless** the optional AWS EFS file share below is enabled.

> **In-memory by default; an opt-in shared EFS file share exists for AWS.** No PV/PVC is created by the `certificate-manager` chart by default — the `mountCertFileShare`-style flags some values files retain are for backward compatibility only. On AWS, setting `fileShare.create: true` provisions a `ReadWriteMany` PVC dynamically from an EFS-backed StorageClass (`efs-sc`, via the EFS CSI driver's access-point provisioning — see [Step2.3: EKS Namespace Configuration](00-common-dpn-configuration.md#step23-eks-namespace-configuration)), shared by the Certificate Manager, Federator Server, and Federator Client. Leave `fileShare.create: false` (the default) unless your environment specifically needs a shared file rather than each pod's own in-memory keystore.

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
| 2 | **`cert-manager-truststore` and `tls-auth-secret` Kubernetes secrets present** | `cert-manager-truststore` holds `truststore.jks` used to trust the Vault HTTPS endpoint; `tls-auth-secret` holds its password (`TRUSTSTORE_PASSWORD`). Both are created automatically by the `dpn-gha-tls-cd.yml` workflow — see [Configure DPN Vault Service, Step 3A](01-configure-dpn-vault-service.md#step-3a-configure-vault-tls-dpn-tls-cdyaml) |
| 3 | **Vault credentials available** | The AppRole `role_id`/`secret_id` from `dpn-gha-certificate-manager-role-id-creation.yaml` (when `vault.authentication: APPROLE`) and `VAULT_TOKEN` (root token) in Secrets Manager — see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication) and [Step3b](#step3b-configure-secrets) |
| 4 | **EKS cluster** + an IRSA-annotated ServiceAccount | Required when `secretsManager.enabled: true` (native AWS Secrets Manager) |
| 5 | **OAuth2 client ID and Management Node URL** | Received from DSM during onboarding to establish the DPN connection. The shipped AWS values files use `oauth2.authMode: private_key_jwt` |
| 6 | **Certificate Manager container image available** | Built via the DSI-provided CI process or obtained prebuilt from the DSI GitHub Container Registry (GHCR). Its tag is supplied to the CD workflow as `imageTag` (see the CI/CD overview in [Common Configuration](00-common-dpn-configuration.md#continuous-integration-ci)) |
| 7 | **Config JSON and values file populated, with `cloudProvider: aws` set** | See [Pre-Deployment Configuration](#step3-environment-configuration) — the chart's base `values.yaml` sets no `cloudProvider`; the shipped `values/aws/*.yaml` files set `cloudProvider: aws` |
| 8 | **Certificate Manager AppRole provisioned** | Run `dpn-gha-certificate-manager-role-id-creation.yaml` with `component: certificate-manager` first. On AWS the CD workflow reads `dpn/<environment>-<cluster>/certificate-manager/VAULT_APPROLE_ROLE_ID` and fails if it is missing — see [Step2](#step2-configure-vault-authentication) |

> **No shared file share required by default.** The Certificate Manager does not need a provisioned file share — it builds the mTLS keystore/truststore in memory directly from Vault. An opt-in AWS EFS-backed shared file share exists (`fileShare.create: true`) for environments that need one; see [Step2](#step2-configure-vault-authentication) and the note in [Overview](#overview).

> **One-time setup:** Before running the CD workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) — the workflow **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), and populate `.github/config/aws/<environment>-<cluster>.json`.

## Step2: Configure Vault Authentication

The Certificate Manager reads and writes its certificate material directly in Vault. What you do need to decide is **how the Certificate Manager authenticates to Vault**:

| Method | `vault.authentication` | Notes |
|--------|------------------------|-------|
| Root token | `TOKEN` | The token has full access to Vault; see [Configure DPN Vault Service, Step 3B](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml) |
| AppRole | `APPROLE` | The chart itself defaults to `APPROLE`, and scoped, short-lived credentials are the recommended design (the shipped AWS values files use `APPROLE`). The provisioning workflow, `dpn-gha-certificate-manager-role-id-creation.yaml` (**DPN CD - Certificate Manager Role ID Creation (Vault AppRole Setup)**), takes `component` (`certificate-manager` — the only option in this repository's copy), `environment`, `cluster` and `cloud: aws` — see below |

`dpn-gha-certificate-manager-role-id-creation.yaml` runs `vault/setup-approle.sh` with `vault/certificate-manager-policy.hcl` inside the Vault pod (using the admin root token read from `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN` in Secrets Manager) to enable the `approle` auth method, write a least-privilege policy scoped to the selected component's own paths, create/update its AppRole role, and publish the generated credentials. On AWS it stores both values in Secrets Manager:

| Value | AWS Secrets Manager location | Consumed by |
|---|---|---|
| `secret-id` (sensitive) | `dpn/<environment>-<cluster>/certificate-manager/VAULT_APPROLE_SECRET_ID` | The chart's AWS `SecretProviderClass`, synced into the `certificate-manager-secrets` Kubernetes secret |
| `role-id` (not sensitive) | `dpn/<environment>-<cluster>/certificate-manager/VAULT_APPROLE_ROLE_ID` | `dpn-gha-certificate-manager-cd.yaml`, which fetches it and passes `--set vault.appRole.roleId=…` at deploy time. It is also printed in the workflow summary |

**On AWS you don't need to copy the role-id into the values file.** The **Fetch Vault AppRole Role ID (AWS)** step in `dpn-gha-certificate-manager-cd.yaml` reads `VAULT_APPROLE_ROLE_ID` from Secrets Manager and passes it to Helm with `--set vault.appRole.roleId`, overriding whatever the values file holds. That step fails if the secret does not exist, so run the AppRole setup workflow before the CD workflow. To switch over, set in the environment/cluster values file:

```yaml
vault:
  authentication: APPROLE
  appRole:
    role: "certificate-manager"
    roleId: <role_id>   # overridden on AWS by the CD workflow's --set from Secrets Manager
    mountPath: "approle"
```

The `secret-id` itself is delivered into the `certificate-manager-secrets` Kubernetes secret by the CSI driver — the same mechanism already used for `VAULT_TOKEN` (see [Step3b: Configure Secrets](#step3b-configure-secrets)). `VaultAuthStartupValidator` fails the deployment fast if `authentication: APPROLE` is set but the role-id/secret-id are missing. **The AppRole secret-id does not expire** (`secret_id_ttl=0`) — re-run the setup workflow periodically to rotate it, then redeploy the Certificate Manager to pick up the refreshed value.

---

## Step3: Environment Configuration

The following configurations are required in each environment: 

- `Helm values`
- `secrets` 

Organisations must change the default passwords during secret set up and follow periodic rotation of secrets.

### Step3a: Set Up Helm Values

Set the parameters below in your environment/cluster's values file (the workflow's `CHART_DIR` is `charts/certificate-manager` in the `dpn-federator-certificate-manager` repository, release `dpn-certificate-manager`). The CD workflow resolves `charts/certificate-manager/values/aws/<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
dpn-federator-certificate-manager/
└── charts/
      └── certificate-manager/
            ├── values.yaml                              <- Reference file; do not edit directly
            └── values/aws/<environment>-<cluster>.yaml <- Your environment overrides
```

> **Known limitation (current `develop` of `dpn-federator-certificate-manager`):** the `charts/certificate-manager` templates currently render only the Azure Key Vault `SecretProviderClass` (gated on `keyvault.enabled`) and do not reference `cloudProvider`, `secretsManager.*`, `serviceAccount.*` or `fileShare.*`. The `values/aws/<environment>-<cluster>.yaml` files set those keys, but the AWS behaviour described below only takes effect once the chart's AWS templates are present — confirm this with DSI before deploying on AWS.

DSI proposes only the selective changes below; other parameters may be customised if required. All of these map to container environment variables via the chart ConfigMap.

**Core deployment**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cloudProvider` | **Set to `aws`.** Selects the AWS Secrets Manager/IRSA/EFS-fileShare path below (see the known limitation above); the chart's base `values.yaml` sets no `cloudProvider` | `aws` |
| `managementNode.baseUrl` | DSI DSM Management Node URL for your environment | `https://management.dsm01.dsiXXX.neso.energy` |

**OAuth2 (Management Node authentication)**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `oauth2.clientId` | Client ID received from DSM | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `oauth2.tokenUri` | IDP token URL received from DSM | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| `oauth2.authMode` | Client authentication mode — the chart default is `client_credentials`; the shipped AWS values files use `private_key_jwt` (no client secret needed) | `private_key_jwt` |

**Vault connectivity** (see [Step2: Configure Vault Authentication](#step2-configure-vault-authentication))

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `vault.uri` | HTTPS address of the DPN Vault service | `https://vault-https.<namespace>.svc.cluster.local:8200` |
| `vault.authentication` | `TOKEN` or `APPROLE` — the chart itself defaults to `APPROLE`; see [Step2](#step2-configure-vault-authentication) | `APPROLE` |
| `vault.pkiMount` / `vault.secretPath` | KV v2 mount and path holding the certificate material | `pki-client` / `pki-client/node-net/client` |
| `vault.appRole.roleId` | Non-sensitive role-id, from the AppRole setup workflow's output. On AWS the CD workflow overrides it with `--set` from Secrets Manager | `<role_id>` |
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

**AWS EFS file share** (optional — see the [Overview](#overview) note; leave `fileShare.create: false` unless you need a shared file)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `fileShare.create` | Provision the shared PVC | `true` |
| `fileShare.storageClassName` | EFS-backed StorageClass (dynamic access-point provisioning — no PV or `nodeStageSecretRef` needed) | `efs-sc` |
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
| `secretsManager.enabled` | Use the AWS Secrets Store CSI driver (`SecretProviderClass` `dpn-certificate-manager-kv-secrets`) instead of the chart-managed Secret resource | `true` |
| `secretsManager.secretPrefix` | Prefix under which each secret is created in Secrets Manager | `dpn/<env>-<cluster>/certificate-manager` |
| `existingSecret.name` | Use the CSI-synced secret instead of a chart-created one — set to the name the `SecretProviderClass` syncs to | `certificate-manager-secrets` |

### Step3b: Configure Secrets

#### Option A — Through AWS Secrets Manager (`secretsManager.enabled: true`)

When `cloudProvider: aws` and `secretsManager.enabled: true`, the chart renders an AWS-native `SecretProviderClass` named `dpn-certificate-manager-kv-secrets` (the name the Deployment's CSI volume mounts). It pulls the following from `<secretsManager.secretPrefix>/<KEY_NAME>` and syncs them into the `certificate-manager-secrets` Kubernetes secret. Set `existingSecret.name: certificate-manager-secrets` so the Deployment reads that secret, as the shipped AWS values files do:

| Secrets Manager entry (under `secretPrefix/`) | Kubernetes secret / key | Purpose |
|---|---|---|
| `VAULT_TOKEN` | `VAULT_TOKEN` | Root token of the DPN HashiCorp Vault — always pulled, and used while `vault.authentication: TOKEN`. Kept in sync from `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN` by `dpn-gha-vault-https-cd.yaml` (see [Configure DPN Vault Service, Step 3B](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml)) |
| `VAULT_APPROLE_SECRET_ID` *(only when `vault.authentication: APPROLE`)* | `VAULT_APPROLE_SECRET_ID` | AppRole secret-id, from `dpn-gha-certificate-manager-role-id-creation.yaml` (see [Step2](#step2-configure-vault-authentication)) |

> **Not pulled from Secrets Manager.** The Vault truststore password is read directly from the `tls-auth-secret` Kubernetes secret (key `TRUSTSTORE_PASSWORD`, created by `dpn-gha-tls-cd.yml`) into `VAULT_SSL_TRUST_STORE_PASSWORD` and `OTEL_TRUSTSTORE_PASSWORD`. When `otel.oauth2.enabled` is `true`, `OTEL_OAUTH2_CLIENT_SECRET` comes from `dpn-keycloak-secrets` (key `KC_SERVICE_CLIENT_SECRET`). The `MTLS_KEYSTORE_PASSWORD` / `MTLS_TRUSTSTORE_PASSWORD` entries are no longer read, because the mTLS keystore/truststore use an ephemeral in-memory password. `OAUTH2_CLIENT_SECRET` is not read either, because the shipped values use `oauth2.authMode: private_key_jwt`.

#### Option B - Through Vault truststore (Kubernetes secret)

The Vault HTTPS truststore (`truststore.jks`) is loaded into the Kubernetes secret named by `vaultTruststore.secretName` (set to `cert-manager-truststore` in the shipped AWS values files; the chart default is empty) and mounted at `vaultTruststore.mountPath` (default `/app/truststore`). This secret is **created automatically by the `dpn-gha-tls-cd.yml` workflow** — no manual `kubectl create secret` is required. This is independent of which secrets backend (Option A or B) supplies the rest of the application secrets.

---

## Step4: Setup Deployment Configuration

The Certificate Manager is deployed with the `dpn-gha-certificate-manager-cd.yaml` GitHub Actions workflow:

```text
dpn-federator-certificate-manager/
└── .github/
    └── workflows/
        └── dpn-gha-certificate-manager-cd.yaml
```

Trigger it via **Actions → DPN CD - Certificate Manager → Run workflow**. The workflow runs **Applied Parameters** (rejects `imageTag`/`imageRepository` values with leading/trailing whitespace) → **Read Deployment Config** → **Cloud Login** → **Verify Cluster Access** → **Fetch Vault AppRole Role ID (AWS)** (reads `dpn/<environment>-<cluster>/certificate-manager/VAULT_APPROLE_ROLE_ID` from Secrets Manager and passes it as `--set vault.appRole.roleId`) → `helm lint` + dry-run → `helm upgrade --install dpn-certificate-manager charts/certificate-manager`, followed by a rolling restart (`kubectl rollout restart deployment/dpn-certificate-manager`) and a rollout status check. It then captures the deployed image digest as the `deployed-image-digest` workflow artifact. There is no approval-gate concept built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.

> **No `--wait`/`--timeout` on `helm upgrade` for this path.** Long-lived watches against the EKS API from the self-hosted runner were unreliable and timed out even when the rollout had actually completed on the cluster. The Helm Deploy and rolling-restart steps instead fire the command without waiting, then poll `kubectl rollout status --timeout=60s` up to five times with a short pause between attempts — a deploy that reports failure after all five attempts prints diagnostic `kubectl describe`/PVC/`SecretProviderClass`/events output before failing the job.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test`; resolves `.github/config/aws/<environment>-<cluster>.json` and `charts/certificate-manager/values/aws/<environment>-<cluster>.yaml` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `imageTag` | Tag of the Certificate Manager image to deploy — from the CI build or the prebuilt DSI image (required, no default) |
| `imageRepository` | Optional — overrides `image.repository` for this run only (path after `ghcr.io/energy-dsi/`, e.g. `1.0.1/certificate-manager`) — leave blank to use the environment's configured repository |

> **Note (Vault dependency):** Deploy the Certificate Manager only after Vault is fully set up — this workflow does not initialise Vault itself; that happens in [Step 3B of the Vault workflow](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml). If Vault's KV v2 engine is not yet enabled, the renewal/sync jobs will fail until it is. On AWS, also run the AppRole setup ([Step2](#step2-configure-vault-authentication)) first, or the **Fetch Vault AppRole Role ID (AWS)** step fails.

---
## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
