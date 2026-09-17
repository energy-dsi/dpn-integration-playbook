# DPN Federator Gateway Configuration

This section describes how to configure and deploy the **DPN Federator Gateway** (Server and Client, plus their supporting services) into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS). The Federator Gateway handles all secure communication between DPN node and other DPN nodes or the DSI DSM — sending and receiving data only to and from trusted parties over mutual TLS (mTLS).

> **Depends on Vault and the Certificate Manager.** The Federator Gateway cannot start correctly until:
> - the **DPN Vault** is deployed, initialised, and loaded (it supplies the certificate, key pair, CA chain, and keystore/truststore **passwords** under `node-net/client/*`), and
> - the **Certificate Manager** has renewed the certificate into that same Vault path.
>
> The gateway reads this material directly from Vault and builds its mTLS keystore/truststore **in memory** at start-up (`vaultConfig.tlsEnabled: true`) — there is no shared file share to provision (`vaultConfig.mountCertFileShare: false`).
>
> Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) first.

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
  - [Step3e: Configure Redis Security](#step3e-configure-redis-security)
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
| Redis | In-memory cache for offsets and tokens, used by both Server and Client. TLS-only (server-auth), access gated by Keycloak — see [Step3e](#step3e-configure-redis-security) |
| **Federator Server** | Receives inbound connections from other DPNs' clients; reads from Kafka Source and streams data out over gRPC/mTLS |
| **Federator Client** | Connects outward to a remote Federator Server; writes received data into Kafka Target and its storage |

> **Kafka broker security.** Both Kafka Source and Kafka Target run with `SASL_SSL` on every listener by default (`kafka.authMode: sasl_ssl` — the production default; `ssl`/`plaintext` remain available for dev/test). The SASL mechanism is `OAUTHBEARER`: brokers and clients obtain and validate tokens from the DPN **Keycloak** realm (`kafka.oauth.tokenEndpointUrl`), so both inter-broker and client Kafka traffic is authenticated against Keycloak, not static credentials.

**certificates and passwords flow (MUST READ):**

- The gateway builds its mTLS keystore/truststore **in memory** directly from certificate material in Vault (`vaultConfig.tlsEnabled: true`, `vaultConfig.tlsBasePath: node-net/client`) — no shared file share is used (`vaultConfig.mountCertFileShare: false`).
- The keystore/truststore **passwords are read from Vault** at start-up (`vaultConfig.keystorePasswordPath` / `truststorePasswordPath`) — they are **not** stored as Federator Key Vault secrets.
- The gateway authenticates to Vault itself via **AppRole** (`vaultConfig.authMethod: approle`, recommended) or the Vault root token (`token`). Unlike the Certificate Manager, there is no CD pipeline for this — the AppRole identity is provisioned by running this repository's own `vault/setup-approle.sh` manually against the Vault pod. See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended).
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
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the Vault `vault-tls-bootstrap-cd` pipeline; mounted at `/vault/truststore` so the gateway trusts Vault's HTTPS endpoint |
| 4 | **Vault AppRole identity provisioned** *(recommended)* | No CD pipeline exists for this yet — run this repository's `vault/setup-approle.sh` manually against the Vault pod, then set `vaultConfig.authMethod: approle` and `vaultConfig.appRole.roleId`. `token` remains available for backward compatibility. See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended) |
| 5 | **AKS cluster, user-assigned managed identity, Secrets Store CSI driver** | The managed identity must have *get* access to the Key Vault secrets |
| 6 | **Azure Key Vault secrets created** | The two storage connection strings — see [Step2: Configure Secrets](#step2-configure-secrets) |
| 7 | **Storage accounts provisioned** | The **Server's** storage account, and the **File Scan Service source** storage account used by the **Client** |
| 8 | **Fixed internal load balancer IPs reserved** | One for the Server service, one for the Client service (internal LB) |
| 9 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding |
| 10 | **Keycloak realm reachable** | Required when `kafka.authMode: sasl_ssl` (the production default) — the brokers and Kafka UI resolve tokens against `kafka.oauth.tokenEndpointUrl` |
| 11 | **Container image tag available** | Built by the DSI CI process or prebuilt DSI image; supplied to the CD pipeline as `imageTag` |
| 12 | **`config/<env>-<cluster>.json` and `values-<env>-<cluster>.yaml` populated** | See [Step3: Configure Environment](#step3-configure-environment) |

> **No shared file share.** Earlier releases mounted a shared file share (`pvc-dpn-certs-fileshare`) at `/tls` to pick up P12 files written by the Certificate Manager. That file share has been removed — the gateway reads its certificate material from Vault directly (see the certificates-and-passwords note in [Overview](#overview)).

> **Azure DevOps pipeline setup (one-time):** Before running the CD pipeline, complete [Azure DevOps Configuration](00-common-dpn-configuration.md#step2-azure-devops-configuration) — the pipeline **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), set up the Azure **service connection**, and populate the per-cluster `config/<env>-<cluster>.json`. Note the gateway uses a **per-cluster** config JSON and values file (`<env>-<cluster>`), unlike Vault/Certificate Manager which use `<env>` only.

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

> **Vault truststore password (deploy-time):** The gateway CD pipeline reads **`VAULT-TRUSTSTORE-PASSWORD`** from this Key Vault (`az keyvault secret show`) and injects it as `vaultConfig.truststorePassword`, which is rendered into the Federator common config at deploy time. This secret is created earlier by the Vault `vault-tls-bootstrap-cd` pipeline — confirm it exists in Key Vault before deploying the gateway.
>
> **Rotating this password:** it is captured **at deploy time** and baked into the rendered config, so restarting the Federator pods keeps the **old** value. To rotate it: update `VAULT-TRUSTSTORE-PASSWORD` in Key Vault (via `vault-tls-bootstrap-cd`), then **re-run the gateway CD pipeline** (`azure-dpn-cd`) so the config is re-rendered with the new value — a pod restart alone is not sufficient.

---

### Option B - Use Kubernetes Secrets

The following Kubernetes secrets must be present in the namespace when the gateway pods start. Two are created automatically by the CSI driver from Key Vault; two are provided by earlier components.

| Kubernetes Secret | Provided by | Used for |
|-------------------|-------------|----------|
| `federator-server-secrets` | CSI driver from AKV `STORAGE-CONNECTION-STRING` (Server `SecretProviderClass`) | Server storage connection string |
| `federator-client-secrets` | CSI driver from AKV `CLIENT-STORAGE-CONNECTION-STRING` (Client `SecretProviderClass`) | Client storage connection string |
| `certificate-manager-secrets` | Created by the **Certificate Manager** deployment | Provides the credential the gateway uses to authenticate to Vault and read the certificate material/passwords — the AppRole `secret-id` (recommended, `vaultConfig.authMethod: approle`) or the root token (`VAULT_TOKEN`, `authMethod: token`) |
| `cert-manager-truststore` | Created by the Vault **`vault-tls-bootstrap-cd`** pipeline | `truststore.jks` mounted at `/vault/truststore` to trust the Vault HTTPS endpoint |

---

## Step3: Configure Environment

The gateway chart is in the `dpn-federator-gateway` repository. Copy `values.yaml` (reference — do not edit directly) to `values-<env>-<cluster>.yaml` and set the parameters below. The CD pipeline resolves the values file from the `environment` and `dpncluster` you select at runtime.

```text
Root-Repository
  └── charts
        └── dpn-platform
              ├── values.yaml               <- Default settings for all components; do not edit directly
              └── values-<env>-<cluster>.yaml <- Your environment + cluster overrides
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

> Switching `kafka.authMode` is a single value that reconfigures all broker listeners simultaneously — there is no need to change Kafka Source and Kafka Target separately. See [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md) to deploy the Keycloak instance and realm this depends on.

### Step3e: Configure Redis Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `redis.tls.enabled` | Whether Redis only accepts TLS connections — **on by default** in every environment, not opt-in | `true` |
| `redis.truststore.path` / `redis.truststore.password` | Client-side truststore the Server/Client use to trust Redis's certificate. Identical for both roles, so set once in `common-configuration.properties` rather than duplicated per role | as received alongside the other TLS material |

Redis's own server certificate is **not** a separate value to configure — it's extracted at pod start-up (by an init container, using `openssl`) from the same shared `dpn-tls` keystore Kafka already uses, whose SAN already covers the in-cluster Redis hostname. Redis is configured for **server-authentication only** (`--tls-auth-clients no`) — there is no client certificate/mTLS requirement for connecting to it, mirroring Kafka's own `SASL_SSL` listener (`KAFKA_SSL_CLIENT_AUTH=none`).

> **No Redis username/password (ACL) authentication.** Earlier releases supported `redis.username`/`redis.password` for Redis's own ACL auth — these have been **removed**. Access control is now enforced entirely at the application layer: every Redis-touching call site (other than the Federator's own IDP token cache, which deliberately bypasses this to avoid a circular dependency) requires a valid Keycloak session before a connection is returned. This is independent of `kafka.authMode` / Keycloak's SASL role for Kafka — Redis TLS and its Keycloak gate apply regardless of that Kafka setting.
>
> **Only this component's own Redis is TLS-enabled today.** The REST Federator Gateway's separate `dpn-redis` release (its own cache, not this one) does not yet have TLS — that migration is tracked as a separate, not-yet-delivered enabler.

---

## Step4: Configure Deployment Parameters

The Federator Gateway is deployed with a **single run** of the CD pipeline `azure-dpn-cd.yaml` in the `dpn-federator-gateway` repository. One run applies `values-<env>-<cluster>.yaml` on top of `values.yaml` and deploys all components in the single Helm release `dpn-platform`.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── azure-dpn-cd.yaml
```

Runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `ServiceConnection` | Azure service connection for your environment |
| `environment` | Your target environment |
| `dpncluster` | The **single** target DPN cluster — `dpn01` or `dpn02`. Deploy one cluster at a time; the Client is configured for this one cluster |
| `imageTag` | Tag of the Federator images to deploy (from the CI build or prebuilt DSI image) |

To run it: **Pipelines → `azure-dpn-cd` → Run pipeline**, fill in the parameters, then **Run**. On success, the deployment stage ends with:

```text
DPN DEPLOYMENT COMPLETE
```

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-Jul-2026 | DSI Assurance | Final | V1.0.0 |
