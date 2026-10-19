Release : 2.1.0 - Oct 2026

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
  - [Step3f: Configure OTel Collector Security](#step3f-configure-otel-collector-security)
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

> **Kafka broker security.** Both Kafka Source and Kafka Target run with `SASL_SSL` on every listener by default (`kafka.authMode: sasl_ssl` — the production default; `ssl`/`plaintext` remain available for dev/test). The SASL mechanism is `OAUTHBEARER`: brokers and clients obtain and validate tokens from the DPN **Keycloak** realm (`kafkaSrc.oauth.tokenEndpointUrl` / `kafkaTarget.oauth.tokenEndpointUrl` — there is no shared top-level `kafka.oauth.*` key), so both inter-broker and client Kafka traffic is authenticated against Keycloak, not static credentials.

**certificates and passwords flow (MUST READ):**

- The gateway builds its mTLS keystore/truststore **in memory** directly from certificate material in Vault (`vaultConfig.tlsEnabled: true`, `vaultConfig.tlsBasePath: node-net/client`) — no shared file share is used (`vaultConfig.mountCertFileShare: false`).
- The keystore/truststore **passwords are read from Vault** at start-up (`vaultConfig.keystorePasswordPath` / `truststorePasswordPath`) — they are **not** stored as Federator Key Vault secrets.
- The gateway authenticates to Vault itself via **AppRole** (`vaultConfig.authMethod: approle`, recommended) or the Vault root token (`token`). **Current practice: reuse the Certificate Manager's AppRole identity rather than provisioning a separate one.** `vault-approle-setup-cd` (run once, for the Certificate Manager) already puts the `secret-id` in Key Vault as `VAULT-APPROLE-SECRET-ID`, which this component's own `SecretProviderClass` syncs into the same `certificate-manager-secrets` Kubernetes secret the Certificate Manager uses — no extra action needed for that part. The `role-id` is **not** stored anywhere automatically (it isn't sensitive, so the pipeline only prints it in its run log) — manually copy that same role-id into `vaultConfig.appRole.roleId` here too. See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended) — a dedicated identity via this repository's own `vault/setup-approle.sh` is also possible if your organisation wants stricter per-component isolation.
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
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the `dpn-tls-cd` pipeline; mounted at `/vault/truststore` so the gateway trusts Vault's HTTPS endpoint |
| 4 | **Vault AppRole identity provisioned** *(recommended)* | Reuse the Certificate Manager's — run `vault-approle-setup-cd` once (if not already done for the Certificate Manager), then set `vaultConfig.authMethod: approle` and manually paste that same role-id into `vaultConfig.appRole.roleId` here. `token` remains available for backward compatibility. See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended) |
| 5 | **AKS cluster, user-assigned managed identity, Secrets Store CSI driver** | The managed identity must have *get* access to the Key Vault secrets |
| 6 | **Azure Key Vault secrets created** | The two storage connection strings — see [Step2: Configure Secrets](#step2-configure-secrets) |
| 7 | **Storage accounts provisioned** | The **Server's** storage account, and the **File Scan Service source** storage account used by the **Client** |
| 8 | **Fixed internal load balancer IPs reserved** | One for the Server service, one for the Client service (internal LB) |
| 9 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding |
| 10 | **Keycloak realm reachable** | Required when `kafka.authMode: sasl_ssl` (the production default) — the brokers and Kafka UI resolve tokens against `kafkaSrc.oauth.tokenEndpointUrl` / `kafkaTarget.oauth.tokenEndpointUrl` |
| 11 | **Container image tag available** | Built by the DSI CI process or prebuilt DSI image; supplied to the CD pipeline as `imageTag` |
| 12 | **`config/<env>-<cluster>.json` and `values-<env>-<cluster>.yaml` populated** | See [Step3: Configure Environment](#step3-configure-environment) |

> **No shared file share — but check `mountCertFileShare` when provisioning a new environment.** Earlier releases mounted a shared file share (`pvc-dpn-certs-fileshare`) at `/tls` to pick up P12 files written by the Certificate Manager. Every populated environment (`values-<env>-<cluster>.yaml`) sets `vaultConfig.mountCertFileShare: false`, so the gateway reads its certificate material from Vault directly (see the certificates-and-passwords note in [Overview](#overview)). The chart's own reference `values.yaml` still defaults `mountCertFileShare: true` for backward compatibility, though — if you provision a **new** environment by copying `values.yaml` (per [Step3](#step3-configure-environment)) and don't explicitly override this to `false`, the deprecated file share is mounted again. Confirm `mountCertFileShare: false` is set explicitly in your environment's values file rather than relying on the reference default.

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

> **Vault truststore password (deploy-time):** The gateway CD pipeline reads **`TRUSTSTORE-PASSWORD`** from this Key Vault (`az keyvault secret show`) and injects it as `vaultConfig.truststorePassword`, which is rendered into the Federator common config at deploy time. This secret is written by the `dpn-tls-cd` pipeline on every certificate renewal — see [Configure DPN Vault Service, Step 3A](01-configure-dpn-vault-service.md#step-3a-configure-dpn-universal-tls-dpn-tls-cd).
>
> **Rotating this password:** it is captured **at deploy time** and baked into the rendered config, so restarting the Federator pods keeps the **old** value. To rotate it: re-run `dpn-tls-cd` with the new `truststorePassword`, then **re-run the gateway CD pipeline** (`azure-dpn-cd`) so the config is re-rendered with the new value — a pod restart alone is not sufficient.

---

### Option B - Use Kubernetes Secrets

The following Kubernetes secrets must be present in the namespace when the gateway pods start. Two are created automatically by the CSI driver from Key Vault; two are provided by earlier components.

| Kubernetes Secret | Provided by | Used for |
|-------------------|-------------|----------|
| `federator-server-secrets` | CSI driver from AKV `STORAGE-CONNECTION-STRING` (Server `SecretProviderClass`) | Server storage connection string |
| `federator-client-secrets` | CSI driver from AKV `CLIENT-STORAGE-CONNECTION-STRING` (Client `SecretProviderClass`) | Client storage connection string |
| `certificate-manager-secrets` | Created by the **Certificate Manager** deployment | Provides the credential the gateway uses to authenticate to Vault and read the certificate material/passwords — the AppRole `secret-id` (recommended, `vaultConfig.authMethod: approle`) or the root token (`VAULT_TOKEN`, `authMethod: token`) |
| `cert-manager-truststore` | Created by the **`dpn-tls-cd`** pipeline | `truststore.jks` mounted at `/vault/truststore` to trust the Vault HTTPS endpoint |

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

> **`federatorServer.idp.clientId` (and the equivalent audience check on inbound requests) is now compared case-sensitively**, per RFC 7519 §4.1.3 — a client ID that previously matched regardless of case will now be rejected if its case doesn't match exactly what DSM issued. Confirm the value configured here matches DSM's registration byte-for-byte.
>
> **Heartbeat interval is now 15 minutes (was 1 hour).** This is a fixed value in the chart's rendered config (`server.heartbeat.interval=PT15M`, an ISO-8601 duration) — it is **not** a `values.yaml` key today, so changing it per environment means editing the chart template itself, not an environment's values file.

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
| `federatorClient.auth.enabled` | Front the JobRunr dashboard with a built-in Keycloak-authenticating gateway (`JobRunnerAuthGateway`) instead of leaving it open on the internal network | `true` |
| `federatorClient.auth.issuerUrl` / `.audience` | Keycloak realm issuer and OIDC client ID (reuses the same client Kafka's OAuth already uses) | as received from DSM |
| `federatorClient.auth.adminRole` / `.readerRole` | Keycloak roles gating full vs. view-only dashboard access — leave both blank to allow any authenticated user full access | `dpnadmin` / `dpnreader` |
| `federatorClient.service.jobRunnerAuthPort` | The gateway's own bind port. Exposed via the `-external` LoadBalancer Service **only when `nginxSidecar.enabled: false`** (see below) | `8086` |

> **Keycloak redirect URI:** register `https://<federatorClient.name>-external.<namespace>.svc.cluster.local:<jobRunnerAuthPort>/oauth2/callback` on the Keycloak client.

**Nginx reverse-proxy sidecar (required)** — fronts the JobRunr dashboard for TLS termination:

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorClient.nginxSidecar.enabled` | Must be set to `true`. The chart default is `false`, which falls back to the Java-based proxy — known to have latency/stalling issues under load | `true` |
| `federatorClient.service.jobRunnerInternalPort` | Dashboard's internal bind port once nginx fronts it | `18085` |

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
| `kafka.authMode` | Security protocol for **every** Kafka listener (Source and Target) — `sasl_ssl` (production default), `ssl` (TLS only, no OAuth), or `plaintext` (dev/test only) | `sasl_ssl` |
| `kafkaSrc.oauth.clientId` / `kafkaTarget.oauth.clientId` | Keycloak client ID each broker's `OAuthBearerLoginModule` authenticates as | `dpn-service-client` |
| `kafkaSrc.oauth.tokenEndpointUrl` / `.jwksUrl` (and the same under `kafkaTarget.oauth`) | Keycloak token/JWKS endpoints used for `OAUTHBEARER` login and token validation when `authMode: sasl_ssl` | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/{token,certs}` |
| `kafkaSrc.oauth.expectedAudience` / `.expectedIssuer` (and the same under `kafkaTarget.oauth`) | Values the broker validates incoming tokens against | `dpn-service-client` / `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm` |
| `kafkaSrc.oauth.adminUser` / `kafkaTarget.oauth.adminUser` | Keycloak admin username used for realm bootstrap checks | `admin` |
| `kafkaSrc.tls.*` / `kafkaTarget.tls.*` | Broker's own TLS keystore/truststore paths and mTLS enforcement (`clientAuth: none` or `required`) — used whenever `authMode` is `ssl` or `sasl_ssl`, independent of the OAuth settings above | see chart defaults |

> **Secrets this depends on.** The `oauth.*` fields above are non-secret config; the actual client secret and passwords are read at runtime from two existing secrets — `dpn-keycloak-secrets` (`KC_SERVICE_CLIENT_SECRET`, `KEYCLOAK_ADMIN_PASSWORD`) and `tls-auth-secret` (`KEYSTORE_PASSWORD`, `TRUSTSTORE_PASSWORD`, created by `dpn-tls-cd`). Provisioning `dpn-keycloak-secrets` is out of scope for this playbook — see [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md).

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

### Step3f: Configure OTel Collector Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `otel.tls.enabled` | Whether OTLP export uses HTTPS against the Collector — **on by default**, matching every environment's behaviour before this flag existed | `true` |
| `otel.oauth.enabled` | Attach an `Authorization: Bearer` token (fetched via the `dpn-service-client` Keycloak client — the same one already used to gate Redis access) to every OTLP export call — **on by default in every environment** | `true` |
| `otel.truststorePath` | Trust anchor for the Collector's OTLP HTTPS receiver (server-side TLS only). Same JKS truststore Redis and the JobRunr dashboard auth already use | `/etc/secrets/truststore.jks` |

No separate Keycloak client or secret is provisioned for OTel — it reuses `dpn-service-client`, the same credential already wired for Redis/Kafka OAuth. Setting `otel.tls.enabled: false` only works once the Collector side also exposes a genuine plaintext listener — today it terminates TLS unconditionally, so a plaintext exporter against it fails the handshake outright rather than falling back.

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

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 | 
| Oct-2026 | DSI Assurance   | Final  | V2.1.0 | 
