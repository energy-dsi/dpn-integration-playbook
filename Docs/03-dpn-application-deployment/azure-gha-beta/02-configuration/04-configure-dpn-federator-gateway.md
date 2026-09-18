# DPN Federator Gateway Configuration

This section describes how to configure and deploy the **DPN Federator Gateway** (Server and Client, plus their supporting services) into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS). The Federator Gateway handles all secure communication between DPN node and other DPN nodes or the DSI DSM — sending and receiving data only to and from trusted parties over mutual TLS (mTLS).

> **Depends on Vault and the Certificate Manager.** The Federator Gateway cannot start correctly until:
> - the **DPN Vault** is deployed, initialised, and loaded (it supplies the certificate, key pair, CA chain, and keystore/truststore **passwords** under `node-net/client/*`), and
> - the **Certificate Manager** has renewed the certificate into that same Vault path.
>
> The gateway reads this material directly from Vault and builds its mTLS keystore/truststore **in memory** at start-up (`vaultConfig.tlsEnabled: true`) — there is no shared file share to provision (`vaultConfig.mountCertFileShare: false`).
>
> Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](03-configure-dpn-certificate-manager.md) first.

> **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`, e.g. `dpn01`). Substitute your own values for `<env>` and `<cluster>` throughout. The Federator Client is deployed for a **single cluster only** — deploy one cluster at a time.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet Prerequisites](#step1-meet-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
  - [Option A - Use Azure Key Vault](#option-a---use-azure-key-vault)
  - [Option B - Use Kubernetes Secrets](#option-b---use-kubernetes-secrets)
- [Step3: Configure Environment](#step3-configure-environment)
  - [Step3a: Configure Federator Server](#step3a-configure-federator-server)
  - [Step3b: Configure Federator Client](#step3b-configure-federator-client)
  - [Step3c: Configure Key Vault If Used](#step3c-configure-key-vault-if-used)
  - [Step3d: Configure Kafka Security](#step3d-configure-kafka-security)
- [Step4: Configure Deployment Parameters](#step4-configure-deployment-parameters)
- [Review Notes](#review-notes)

---

## Overview

The Federator Gateway is deployed as a **single Helm release (`dpn-platform`)** that includes Federator gRPC Server, Federator gRPC Client, and other supporting services — all into the same namespace and cluster. Refer to the following:

| Component | Purpose |
|-----------|---------|
| Zookeeper Source / Target | Coordination for the Source / Target Kafka clusters (must start before Kafka) |
| Kafka Source | Stages the DPN's outgoing data; the Federator **Server** reads from here to send data out |
| Kafka Target | Receives incoming data from other DPNs; the Federator **Client** writes received data here |
| Kafka UI | Web dashboard to monitor topics/messages in both Kafka clusters (testing) |
| Redis | In-memory cache for offsets and tokens, used by both Server and Client |
| **Federator Server** | Receives inbound connections from other DPNs' clients; reads from Kafka Source and streams data out over gRPC/mTLS |
| **Federator Client** | Connects outward to a remote Federator Server; writes received data into Kafka Target and its storage |

> **Kafka broker security.** Both Kafka Source and Kafka Target run with `SASL_SSL` on every listener by default (`kafka.authMode: sasl_ssl` — the production default; `ssl`/`plaintext` remain available for dev/test). The SASL mechanism is `OAUTHBEARER`: brokers and clients obtain and validate tokens from the DPN **Keycloak** realm (`kafka.oauth.tokenEndpointUrl`), so both inter-broker and client Kafka traffic is authenticated against Keycloak, not static credentials.

**certificates and passwords flow (MUST READ):**

- The gateway builds its mTLS keystore/truststore **in memory** directly from certificate material in Vault (`vaultConfig.tlsEnabled: true`, `vaultConfig.tlsBasePath: node-net/client`) — no shared file share is used (`vaultConfig.mountCertFileShare: false`).
- The keystore/truststore **passwords are read from Vault** at start-up (`vaultConfig.keystorePasswordPath` / `truststorePasswordPath`) — they are **not** stored as Federator Key Vault secrets.
- The gateway authenticates to Vault itself via the Vault root token (`vaultConfig.authMethod: token`) — **AppRole (`approle`) is the long-term design but isn't automated on this path yet**; see [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-planned-not-yet-available).
- The only Federator secrets in Key Vault are the **storage connection strings** (one for the Server, a separate one for the Client) and, if using AppRole, the Vault `secret-id`.

> **Storage account separation for Server and Client (MUST READ)**

Federator Server and Client use **separate storage accounts**. The Federator Client uses the **File Scan Service *source* storage account** (its blob endpoint and container are where scanned inbound files are deposited). Configure the Client's storage endpoint/connection string to point at the File Scan Service source storage account — not the Server's account.

The Server's storage account is used to keep the data product files created by the organisation per data product pipeline.

---

## Step1: Meet Prerequisites

Ensure the following are in place **before** deploying the Federator Gateway:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed** | Renews the certificate into Vault, and creates the `certificate-manager-secrets` Kubernetes secret used for the Vault AppRole `secret-id` (or root token) |
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the `dpn-vault-tls-bootstrap-cd.yml` workflow; mounted at `/vault/truststore` so the gateway trusts Vault's HTTPS endpoint |
| 4 | **Vault authentication configured** | Set `vaultConfig.authMethod: token` — AppRole isn't automated on this path yet. See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-planned-not-yet-available) |
| 5 | **AKS cluster, user-assigned managed identity, Secrets Store CSI driver** | The managed identity must have *get* access to the Key Vault secrets |
| 6 | **Azure Key Vault secrets created** | The two storage connection strings — see [Step2: Configure Secrets](#step2-configure-secrets) |
| 7 | **Storage accounts provisioned** | The **Server's** storage account, and the **File Scan Service source** storage account used by the **Client** |
| 8 | **Fixed internal load balancer IPs reserved** | One for the Server service, one for the Client service (internal LB) |
| 9 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding |
| 10 | **Keycloak realm reachable** | Required when `kafka.authMode: sasl_ssl` (the production default) — the brokers and Kafka UI resolve tokens against `kafka.oauth.tokenEndpointUrl` |
| 11 | **Container image tag available** | Built by the DSI CI process or prebuilt DSI image; supplied to the CD workflow as `imageTag` |
| 12 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step3: Configure Environment](#step3-configure-environment) |

> **No shared file share — but check `mountCertFileShare` when provisioning a new environment.** Earlier releases mounted a shared file share (`pvc-dpn-certs-fileshare`) at `/tls` to pick up P12 files written by the Certificate Manager. Every populated environment sets `vaultConfig.mountCertFileShare: false`, so the gateway reads its certificate material from Vault directly (see the certificates-and-passwords note in [Overview](#overview)). The chart's own reference `values.yaml` still defaults `mountCertFileShare: true` for backward compatibility, though — confirm your environment's values file explicitly overrides this to `false` rather than relying on the reference default, or the deprecated file share is mounted again.

> **One-time setup:** Before running the CD workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) — the workflow **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), and populate `.github/config/azure/<environment>-<cluster>.json`. Every DPN component now uses this same `<environment>-<cluster>` config/values naming — there's no longer a distinction between Vault/Certificate Manager (`<env>`-only) and the gateway (`<env>-<cluster>`).

---

## Step2: Configure Secrets 

Secrets can be configured in two different approaches. 

### Option A - Use Azure Key Vault

Provision the following in Azure Key Vault (`<keyvault.name>`). The chart's `SecretProviderClass` templates pull them into Kubernetes secrets via the CSI driver. Example values are **placeholders** — use your own.

| AKV Secret | Synced to Kubernetes secret / key | Consumed by | Purpose |
|------------|-----------------------------------|-------------|---------|
| `STORAGE-CONNECTION-STRING` | `federator-server-secrets` / `STORAGE_CONNECTION_STRING` | Federator **Server** | Connection string for the Server's storage account |
| `CLIENT-STORAGE-CONNECTION-STRING` | `federator-client-secrets` / `STORAGE_CONNECTION_STRING` | Federator **Client** | Connection string for the Client's storage account (**the File Scan Service source storage account**) |

Example connection-string format (placeholder):

```text
https://<storage-account>.blob.core.windows.net/?<sas-token>
```

> **Note:** The keystore/truststore P12 passwords are **not** provisioned here — the gateway reads them from Vault at runtime. Only the storage connection strings live in Key Vault for the Federator Gateway.

> **Vault truststore password (deploy-time):** The `dpn-federator-gateway-cd.yml` workflow reads **`VAULT-TRUSTSTORE-PASSWORD`** from this Key Vault (`az keyvault secret show`) and injects it as `vaultConfig.truststorePassword`, which is rendered into the Federator common config at deploy time. This secret is created earlier by the `dpn-vault-tls-bootstrap-cd.yml` workflow — confirm it exists in Key Vault before deploying the gateway.
>
> **Rotating this password:** it is captured **at deploy time** and baked into the rendered config, so restarting the Federator pods keeps the **old** value. To rotate it: update `VAULT-TRUSTSTORE-PASSWORD` in Key Vault (via `dpn-vault-tls-bootstrap-cd.yml`), then **re-run `dpn-federator-gateway-cd.yml`** so the config is re-rendered with the new value — a pod restart alone is not sufficient.

---

### Option B - Use Kubernetes Secrets

The following Kubernetes secrets must be present in the namespace when the gateway pods start. Two are created automatically by the CSI driver from Key Vault; two are provided by earlier components.

| Kubernetes Secret | Provided by | Used for |
|-------------------|-------------|----------|
| `federator-server-secrets` | CSI driver from AKV `STORAGE-CONNECTION-STRING` (Server `SecretProviderClass`) | Server storage connection string |
| `federator-client-secrets` | CSI driver from AKV `CLIENT-STORAGE-CONNECTION-STRING` (Client `SecretProviderClass`) | Client storage connection string |
| `certificate-manager-secrets` | Created by the **Certificate Manager** deployment | Provides the credential the gateway uses to authenticate to Vault and read the certificate material/passwords — the root token (`VAULT_TOKEN`, `authMethod: token`) today; AppRole `secret-id` once that workflow exists |
| `cert-manager-truststore` | Created by the **`dpn-vault-tls-bootstrap-cd.yml`** workflow | `truststore.jks` mounted at `/vault/truststore` to trust the Vault HTTPS endpoint |

---

## Step3: Configure Environment

The gateway chart is `dpn-federator-gateway/charts/dpn-platform` in `dpn-containerised-deployment-service`. Set the parameters below in your environment/cluster's values file. The CD workflow resolves the values file from the `environment` and `cluster` inputs you select at runtime.

```text
dpn-federator-gateway/
  └── charts/
        └── dpn-platform/
              ├── values.yaml                              <- Default settings for all components; do not edit directly
              └── values/azure/<environment>-<cluster>.yaml <- Your environment + cluster overrides
```

> All component images (`redis`, `zookeeperSrc/Target`, `kafkaSrc/Target`, `kafkaUI`, `federatorServer`, `federatorClient`) point at the container registry via `image.repository`. Set these to your registry, e.g. `<DSI public image registry>/<image>`. Only the parameters most likely to change per deployment are listed below.

### Step3a: Configure Federator Server

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorServer.config.management_node_base_url` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` |
| `federatorServer.idp.clientId` | Client ID received from DSM for this DPN node | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `federatorServer.idp.jwksUrl` | JWKS endpoint for verifying identity tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/certs` |
| `federatorServer.idp.tokenUrl` | Token endpoint for access tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| `federatorServer.storage.azure.endpoint` | Blob endpoint of the **Server's** storage account | `https://st<env>dpn01<region>01.blob.core.windows.net` |

### Step3b: Configure Federator Client

> **Single cluster:** the Client (and this whole release) targets one DPN cluster. Its connection configuration points at a single remote Federator Server.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorClient.config.management_node_base_url` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` |
| `federatorClient.config.targetTopic` | Target topic for received data | `dp-consumer-topic-stage` |
| `federatorClient.idp.clientId` | Client ID received from DSM | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `federatorClient.idp.jwksUrl` / `tokenUrl` | IDP endpoints and grant mode (as Server) | `https://auth-mtls.dsm01.dsiXXX.neso.energy/...` / |
| `federatorClient.storage.azure.endpoint` | **Blob endpoint of the File Scan Service source storage account** if available else use a separate storage account (not the Server's account) | `https://stfss<env>dpn<region>01.blob.core.windows.net` |
| `federatorClient.storage.provider` | `AZURE/S3/GCP/LOCAL` | Note. Important to set this value based on cloud provider. This parameter decides which storage provider to be invoked based on cloud type |
| `federatorClient.storage.azure.container` | Container where inbound files are written (File Scan source container) | `dp-consumer-raw` |

**JobRunr dashboard authentication** (optional — off by default; see [Federator Client — JobRunr Dashboard User Guide](../../../05-dpn-user-interfaces/03-federator-client-job-runner-ui-operations.md) for the end-user access flow)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorClient.auth.enabled` | Front the JobRunr dashboard with a built-in Keycloak-authenticating gateway instead of leaving it open on the internal network | `true` |
| `federatorClient.auth.issuerUrl` / `.audience` | Keycloak realm issuer and OIDC client ID (reuses the same client Kafka's OAuth already uses) | as received from DSM |
| `federatorClient.auth.adminRole` / `.readerRole` | Keycloak roles gating full vs. view-only dashboard access — leave both blank to allow any authenticated user full access | `dpnadmin` / `dpnreader` |
| `federatorClient.service.jobRunnerAuthPort` | The gateway's own bind port — must differ from `jobRunnerPort`, and is the **only** port exposed via the `-external` LoadBalancer Service | `8086` |

> **Keycloak redirect URI must use the `-external` hostname.** The gateway runs its own OIDC authorization-code login. Register `https://<federatorClient.name>-external.<namespace>.svc.cluster.local:<jobRunnerAuthPort>/oauth2/callback` as the redirect URI on the Keycloak client — pointing it at the plain in-cluster hostname instead breaks the login callback (state-cookie mismatch), since Keycloak always redirects back to whichever hostname is configured here regardless of which one the browser actually started the login from.

### Step3c: Configure Key Vault If Used

The following parameter needs to be set if key vault is used as secret provider. 

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `keyvault.enable` | Use Azure Keyvault | true |
| `keyvault.name` | Key Vault holding the storage connection-string secrets | `kv-dpn-<env>-<region>-<seq>` |
| `keyvault.clientID` | Managed-identity client ID allowed to read from Key Vault | `<managed-identity-client-id>` |
| `keyvault.tenantId` | Azure AD tenant ID | `<tenant-id>` |

### Step3d: Configure Kafka Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `kafka.authMode` | Security protocol for **every** Kafka listener (Source and Target) — `sasl_ssl` (production default), `ssl` (TLS only), or `plaintext` (dev/test only) | `sasl_ssl` |
| `kafka.oauth.tokenEndpointUrl` | Keycloak token endpoint used for `OAUTHBEARER` login/validation when `authMode: sasl_ssl` | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |

> Switching `kafka.authMode` is a single value that reconfigures all broker listeners simultaneously — there is no need to change Kafka Source and Kafka Target separately. See [Configure DPN Authentication Service](07-configure-dpn-authentication-service.md) to deploy the Keycloak instance and realm this depends on.

---

## Step4: Configure Deployment Parameters

The Federator Gateway is deployed with a **single run** of the `dpn-federator-gateway-cd.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`. One run applies the environment/cluster values file on top of `values.yaml` and deploys all components in the single Helm release `dpn-platform`.

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        └── dpn-federator-gateway-cd.yml
```

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | The **single** target DPN cluster — `dpn01` or `dpn02`. Deploy one cluster at a time; the Client is configured for this one cluster |
| `cloud` | `azure` |
| `imageTag` | Tag of the Federator images to deploy (from the CI build or prebuilt DSI image) |

To run it: **Actions → DPN CD - Federator Gateway → Run workflow**, fill in the inputs, then **Run workflow**. On success, the deployed image digests are captured as a workflow artifact.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-Jul-2026 | DSI Assurance | Final | V1.0.0 |
