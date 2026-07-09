# DPN Certificate Manager Configuration

This document describes how to configure and deploy the **DPN Federator Certificate Manager (CLM)** in a single target environment. The Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for the Federator Gateway — it renews the DSM-signed certificate and builds the keystore/truststore P12 files used for mutual TLS (mTLS).

> **Depends on Vault.** The Certificate Manager **cannot run without the DPN HashiCorp Vault service**. Vault must already be deployed, initialised (KV v2 enabled at `pki-client`), and loaded with the certificate bundle before you deploy the Certificate Manager. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md).

> **Single environment:** These instructions target **one environment** (`<env>`). Substitute your own environment name wherever you see `<env>` (for `config/<env>.json` and `values-<env>.yaml`). You do not need to create multiple environment files.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Pre-Deployment Configuration](#pre-deployment-configuration)
  - [Helm Values](#helm-values)
  - [Secrets Configuration](#secrets-configuration)
- [Deployment](#deployment)
- [Post-Deployment Configuration and Verification](#post-deployment-configuration-and-verification)
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
| `keypair`, `certificate`, `ca-chain` | Client key pair, DSM-signed certificate, CA chain | Vault bundle load (during [Vault setup](01-configure-dpn-vault-service.md#step-3--deployment)) |
| `intermediate-ca` | Intermediate CA certificate | Certificate Manager (renewal) |
| `keystore-password`, `truststore-password` | Passwords for the generated P12 files | Certificate Manager |

The service integrates with **HashiCorp Vault** (secret persistence), the **Management Node** API (PKI operations), and an **OAuth2 Identity Provider** (token auth). All external communication is over mTLS.

---

## Prerequisites

Ensure the following are in place **before** deploying the Certificate Manager:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Vault running over HTTPS, KV v2 enabled at `pki-client`, and the certificate bundle loaded into `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **`cert-manager-truststore` Kubernetes secret present** | Holds `truststore.jks` used to trust the Vault HTTPS endpoint. Created automatically by the Vault `vault-tls-bootstrap-cd` pipeline |
| 3 | **`VAULT-TOKEN` and `VAULT-TRUSTSTORE-PASSWORD` available** | The Vault root token (stored in Key Vault by the Vault init stage) and the Vault truststore password (from the Vault bootstrap). Both are consumed by the Certificate Manager |
| 4 | **Shared Azure File Share provisioned + `azure-fileshare-secret` created manually** | Common storage for the P12 files. The `azure-fileshare-secret` Kubernetes secret must be **created manually before deploy** (the PV mounts using it) — see [Shared File Share](#shared-file-share) below |
| 5 | **AKS cluster** + (if using Azure Key Vault for secrets) a **user-assigned managed identity** and the **Secrets Store CSI driver** | Required when `keyvault.enabled: true` |
| 6 | **OAuth2 client ID, client secret, and Management Node URL** | Received from DSM during onboarding to establish the DPN connection |
| 7 | **Certificate Manager container image available** | Built via the DSI-provided CI process or obtained prebuilt from the DSI GitHub Container Registry (GHCR). Its tag is supplied to the CD pipeline as `imageTag` (see the CI/CD overview in [Common Configuration](00-common-dpn-configuration.md#continuous-integration-ci)) |
| 8 | **`config/<env>.json` and `values-<env>.yaml` populated** | See [Pre-Deployment Configuration](#pre-deployment-configuration) |

> **Azure DevOps pipeline setup (one-time):** Before running the CD pipeline, complete [Azure DevOps Pipeline Prerequisites](00-common-dpn-configuration.md#azure-devops-pipeline-prerequisites) — the pipeline **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), set up the Azure **service connection**, and populate `config/<env>.json`.

### Shared File Share

The Certificate Manager, Federator Gateway Server, and Federator Gateway Client all require the P12 files and their password files at a common mount point (default `/tls`). The Certificate Manager creates these dynamically when it renews/fetches certificates; the Federator mounts them read-only.

```text
/file-share-mount-path
└── tls
    ├── keystore.p12
    └── truststore.p12
```

> **Note:** Only the P12 files are written to the file share. The keystore and truststore **passwords are held in Vault** (`pki-client/node-net/client/keystore-password` and `truststore-password`) and managed by the Certificate Manager — they are not written as `.password` files on the share.

The file share is provisioned by the certificate-manager chart (`charts/certificate-manager`, PV/PVC in `templates/pv-pvc.yaml`) when `fileShare.create: true`. Set it to `false` if the PV/PVC already exist.

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

---

## Pre-Deployment Configuration

Two things must be configured for your environment: the **Helm values** and the **secrets**. Use your own values — the examples below are placeholders only.

### Helm Values

Copy `values.yaml` (reference — do not edit directly) to `values-<env>.yaml` and set the parameters below. The CD pipeline resolves `values-<env>.yaml` from the environment you select at runtime.

```text
Root-Repository
  └── charts
        └── certificate-manager
              ├── values.yaml        <- Reference file; do not edit directly
              ├── values-<env>.yaml  <- Your environment overrides
              └── templates
                    └── pv-pvc.yaml
```

DSI proposes only the selective changes below; other parameters may be customised if required. All of these map to container environment variables via the chart ConfigMap.

**Core deployment**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `image.repository` | Complete URL of the image in the registry | `<DSI public image repository>/dpn-federator-certificate-manager` |
| `namespace` | Kubernetes namespace | `ns-dpn-01` |
| `replicaCount` | Keep `1` — the service writes to a shared file share | `1` |
| `managementNode.baseUrl` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` |

**Vault connectivity** (must match your deployed Vault)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `vault.uri` | HTTPS URL of the DPN Vault | `https://vault-https.<namespace>.svc.cluster.local:8200` |
| `vault.authentication` | Vault auth method — `TOKEN` or `KUBERNETES` | `TOKEN` |
| `vault.pkiMount` | Vault KV v2 mount for certificate secrets | `pki-client` |
| `vault.secretPath` | Base path under the mount | `node-net/client` |
| `vaultTruststore.secretName` | Kubernetes secret holding the Vault `truststore.jks` (from Vault bootstrap) | `cert-manager-truststore` |
| `vaultTruststore.mountPath` | Mount path for `truststore.jks` in the container | `/app/truststore` |

**OAuth2 (Management Node authentication)**

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `oauth2.clientId` | Client ID received from DSM | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `oauth2.tokenUri` | IDP token URL received from DSM | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| `oauth2.authMode` | Grant mode — `client_credentials` or `private_key_jwt` | `private_key_jwt` |
| `oauth2.jwtAlgorithm` | Signing algorithm for `private_key_jwt` | `RS256` |

**Certificate subject & scheduling** (the Certificate Manager generates its CSR and renews using these)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cert.renewalRateMs` | Renewal check interval (ms) | `3600000` (1 hour) |
| `cert.syncRateMs` | Filesystem sync interval (ms) | `60000` (1 minute) |
| `cert.renewalThresholdDays` | Renew when within this many days of expiry | `100` |
| `cert.keySize` | RSA key size for the client key | `2048` |
| `cert.subject.country` | CSR subject Country (C) | `UK` |
| `cert.subject.org` | CSR subject Organisation (O) | `<organisation abbreviation>` |
| `cert.subject.cn` | CSR subject Common Name (CN) | `dpn-<env>-01` |
| `cert.subject.altNames` | Comma-separated SANs (producer/consumer endpoints) | `producer.dpn01.dsiXXX.neso.energy,consumer.dpn01.dsiXXX.neso.energy` |
| `cert.bootstrapOid` | OID used during initial certificate bootstrap | `1.3.6.1.4.1.32473.1.1` |
| `cert.intermediateMinValidDays` | Minimum remaining validity for the intermediate CA before refresh | `14` |

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
| `fileShare.create` | Create the PV/PVC (`false` if they already exist) | `true` |
| `fileShare.storageAccount` | Storage account backing the file share | `st<env>dpn01<region>01` |
| `fileShare.shareName` | SMB file share name | `fs<env>dpn01<region>01` |
| `fileShare.secretName` | Kubernetes secret with the file-share credentials | `azure-fileshare-secret` |
| `fileShare.namespace` | Namespace for the file share | `ns-dpn-01` |
| `fileShare.pvName` / `fileShare.pvcName` | PV / PVC names | `pv-dpn-certs-fileshare` / `pvc-dpn-certs-fileshare` |
| `fileShare.size` | Capacity to allocate | `1Gi` |

**Secret source & Vault init**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `keyvault.enabled` | Use the Azure Key Vault CSI driver for secrets (`true`) instead of the chart-managed Secret rendered from the values file (`false`) | `true` |
| `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | AKV name, managed-identity client ID, tenant ID (when `keyvault.enabled: true`) | `kv-dpn-<env>-<region>-<seq>` / `<managed-identity-client-id>` / `<tenant-id>` |
| `existingSecret.name` | Consume a pre-created Kubernetes secret (set to the CSI-produced secret when `keyvault.enabled: true`) | `certificate-manager-secrets` |
| `vaultInitJob.enabled` | Run the one-time Job that enables Vault KV v2 + `pki-client` on first deploy. Leave `false` if Vault was already initialised during [Vault setup](01-configure-dpn-vault-service.md#step-3--deployment) | `false` |

### Secrets Configuration

The Certificate Manager supports **two secret-provisioning models**, selected by `keyvault.enabled`:

- **Chart-managed Secret from values (`keyvault.enabled: false`, default).** The chart's `secret.yaml` renders an Opaque Kubernetes Secret (`dpn-certificate-manager-secrets`) from the `secrets.*` block in the values file. Simplest for lower environments.
- **Azure Key Vault CSI driver (`keyvault.enabled: true`).** The chart's `secretproviderclass.yaml` pulls secrets from AKV into the `certificate-manager-secrets` Kubernetes secret. Set `existingSecret.name: certificate-manager-secrets` so the chart consumes it.

```text
Root-Repository
  └── charts
        └── certificate-manager
              └── templates
                    ├── secret.yaml                <- chart-managed Secret (keyvault.enabled: false)
                    └── secretproviderclass.yaml   <- AKV CSI SecretProviderClass (keyvault.enabled: true)
```

#### Option A — Azure Key Vault (`keyvault.enabled: true`)

Create the following secrets in `<keyvault.name>`. The `SecretProviderClass` maps them into two Kubernetes secrets — `certificate-manager-secrets` (application) and `azure-fileshare-secret` (file share):

| AKV Secret | Kubernetes secret / key | Purpose | Example (placeholder) |
|------------|-------------------------|---------|-----------------------|
| `MTLS-KEYSTORE-PASSWORD` | `certificate-manager-secrets` / `MTLS_KEYSTORE_PASSWORD` | Password for the mTLS keystore (`keystore.p12`) | `changeit` |
| `MTLS-TRUSTSTORE-PASSWORD` | `certificate-manager-secrets` / `MTLS_TRUSTSTORE_PASSWORD` | Password for the mTLS truststore (`truststore.p12`) | `changeit` |
| `VAULT-TOKEN` | `certificate-manager-secrets` / `VAULT_TOKEN` | Root token of the DPN HashiCorp Vault (from Vault init) | `hvs.xxxxxxxxxxx` |
| `OAUTH2-CLIENT-SECRET` | `certificate-manager-secrets` / `OAUTH2_CLIENT_SECRET` | OAuth2 client secret received from DSM | `xxxxxxxxxxx` |
| `VAULT-TRUSTSTORE-PASSWORD` | `certificate-manager-secrets` / `SPRING_CLOUD_VAULT_SSL_TRUST_STORE_PASSWORD` | Password for the Vault HTTPS truststore (`truststore.jks`) | `changeit` |
| `AZURE-STORAGE-ACCOUNT-NAME` | `azure-fileshare-secret` / `azurestorageaccountname` | Storage account name for the file share | `st<env>dpn01<region>01` |
| `AZURE-STORAGE-ACCOUNT-KEY` | `azure-fileshare-secret` / `azurestorageaccountkey` | Storage account key for the file share | `xxxxxxxxxxx` |

> **Note:** `VAULT-TOKEN` and `VAULT-TRUSTSTORE-PASSWORD` are produced during Vault setup — the token by the Vault init stage (`storeRootTokenInAkv: true`) and the truststore password by the Vault bootstrap pipeline. Confirm both exist in Key Vault before deploying.

> **Note:** Even when `keyvault.enabled: true`, the `azure-fileshare-secret` Kubernetes secret must still be **created manually before the first deploy** (see [Shared File Share](#shared-file-share)). The file-share PV mounts using it via `nodeStageSecretRef` before any CSI-synced secret exists, so the CSI sync alone is not sufficient for the initial mount.

#### Option B — Chart-managed values (`keyvault.enabled: false`)

Populate the equivalent values directly in `values-<env>.yaml` under the `secrets.*` block:

| Values key | Maps to secret key | Notes |
|------------|--------------------|-------|
| `secrets.mtlsKeystorePassword` | `MTLS_KEYSTORE_PASSWORD` | — |
| `secrets.mtlsTruststorePassword` | `MTLS_TRUSTSTORE_PASSWORD` | — |
| `secrets.certDestKeystorePassword` | `CERT_DEST_KEYSTORE_PASSWORD` | Password stamped onto the generated `keystore.p12` |
| `secrets.certDestTruststorePassword` | `CERT_DEST_TRUSTSTORE_PASSWORD` | Password stamped onto the generated `truststore.p12` |
| `secrets.oauth2ClientSecret` | `OAUTH2_CLIENT_SECRET` | — |
| `secrets.vaultToken` | `VAULT_TOKEN` | — |

#### Vault truststore (Kubernetes secret)

The Vault HTTPS truststore (`truststore.jks`) is loaded into the Kubernetes secret named by `vaultTruststore.secretName` (default `cert-manager-truststore`) and mounted at `vaultTruststore.mountPath`. This secret is **created automatically by the Vault `vault-tls-bootstrap-cd` pipeline** — no manual `kubectl create secret` is required.

---

## Deployment

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

## Post-Deployment Configuration and Verification

After the CD pipeline completes, verify the deployment. Replace `<namespace>` with your namespace and `<pod-name>` with the Certificate Manager pod (label `app=dpn-certificate-manager`).

**Rollout and pods healthy:**

```bash
kubectl rollout status deployment/dpn-certificate-manager -n <namespace> --timeout=300s
kubectl get pods -n <namespace> -l app=dpn-certificate-manager -o wide
kubectl get pvc  -n <namespace>
```

**P12 files generated on the shared file share** — confirm both are present:

```bash
kubectl -n <namespace> exec <pod-name> -- ls -l /tls
# expect: keystore.p12  truststore.p12
```

**Logs are clean** — the renewal and sync jobs run without errors:

```bash
kubectl logs <pod-name> -n <namespace>
```

> **First-run note (Vault):** On the very first start, the log-verification step may show Vault access errors if Vault configuration has not fully completed. Ensure Vault is initialised and the bundle is loaded, then restart the Certificate Manager pod:
> ```bash
> kubectl -n <namespace> delete pod/<pod-name>
> ```

### Post-configuration — align the P12 passwords with the Federator Gateway

The keystore/truststore P12 passwords are **managed in Vault** by the Certificate Manager (`pki-client/node-net/client/keystore-password` and `truststore-password`) — they are not written to the file share. The **Federator Gateway must be configured with the same P12 passwords** in its secret configuration (`SERVER-P12-PASSWORD`, `SERVER-TRUSTSTORE-PASSWORD`, `CLIENT-P12-PASSWORD`, `CLIENT-TRUSTSTORE-PASSWORD`).

To keep the passwords deterministic and easy to align, set fixed values via `secrets.certDestKeystorePassword` / `secrets.certDestTruststorePassword` (or the `CERT_DEST_*` Key Vault secrets). The Certificate Manager uses a configured value when present and only generates and stores a random password in Vault when none is provided. Configure the Federator Gateway with the matching values — see [Configure DPN Federator Gateway](03-configure-dpn-federator-gateway.md).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 15-May-2026 | DSI Assurance    | Draft  | V0.1.0 |
