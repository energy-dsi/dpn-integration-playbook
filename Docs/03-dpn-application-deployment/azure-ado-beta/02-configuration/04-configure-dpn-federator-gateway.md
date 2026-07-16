# DPN Federator Gateway Configuration

This section describes how to configure and deploy the **DPN Federator Gateway** (Server and Client, plus their supporting services) into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS). The Federator Gateway handles all secure communication between DPN node and other DPN nodes or the DSI DSM — sending and receiving data only to and from trusted parties over mutual TLS (mTLS).

> **Depends on Vault and the Certificate Manager.** The Federator Gateway cannot start correctly until:
> - the **DPN Vault** is deployed, initialised, and loaded (it supplies the keystore/truststore P12 **passwords** from `node-net/client/keystore-password` and `truststore-password`), and
> - the **Certificate Manager** has generated the `keystore.p12` / `truststore.p12` files onto the shared file share (`/tls`).
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

**certificates and passwords flow (MUST READ):**

- The **P12 files** (`keystore.p12`, `truststore.p12`) are produced by the Certificate Manager and mounted from the shared file share at `/tls`.
- The **P12 passwords are read from Vault** at start-up (`vaultConfig.keystorePasswordPath` / `truststorePasswordPath`) — they are **not** stored as Federator Key Vault secrets.
- The only Federator secrets in Key Vault are the **storage connection strings** (one for the Server, a separate one for the Client).

> **Storage account separation for Server and Client (MUST READ)**

Federator Server and Client use **separate storage accounts**. The Federator Client uses the **File Scan Service *source* storage account** (its blob endpoint and container are where scanned inbound files are deposited). Configure the Client's storage endpoint/connection string to point at the File Scan Service source storage account — not the Server's account.

The Server's storage account is used to keep the data product files created by the organisation per data product pipeline.

---

## Step1: Meet Prerequisites

Ensure the following are in place **before** deploying the Federator Gateway:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the P12 passwords at `pki-client/node-net/client/keystore-password` and `truststore-password`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed** | Produces `keystore.p12` / `truststore.p12` on the shared file share (`/tls`), and creates the `certificate-manager-secrets` Kubernetes secret |
| 3 | **Shared file share PVC present** | `pvc-dpn-certs-fileshare` — mounted read at `/tls` for the P12 files |
| 4 | **`cert-manager-truststore` Kubernetes secret present** | Created by the Vault `vault-tls-bootstrap-cd` pipeline; mounted at `/vault/truststore` so the gateway trusts Vault's HTTPS endpoint |
| 5 | **AKS cluster, user-assigned managed identity, Secrets Store CSI driver** | The managed identity must have *get* access to the Key Vault secrets |
| 6 | **Azure Key Vault secrets created** | The two storage connection strings — see [Step2: Configure Secrets](#step2-configure-secrets) |
| 7 | **Storage accounts provisioned** | The **Server's** storage account, and the **File Scan Service source** storage account used by the **Client** |
| 8 | **Fixed internal load balancer IPs reserved** | One for the Server service, one for the Client service (internal LB) |
| 9 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding |
| 10 | **Container image tag available** | Built by the DSI CI process or prebuilt DSI image; supplied to the CD pipeline as `imageTag` |
| 11 | **`config/<env>-<cluster>.json` and `values-<env>-<cluster>.yaml` populated** | See [Step3: Configure Environment](#step3-configure-environment) |

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
| `certificate-manager-secrets` | Created by the **Certificate Manager** deployment | Provides the Vault root token (`VAULT_TOKEN`) the gateway uses to authenticate to Vault and read the P12 passwords |
| `cert-manager-truststore` | Created by the Vault **`vault-tls-bootstrap-cd`** pipeline | `truststore.jks` mounted at `/vault/truststore` to trust the Vault HTTPS endpoint |

In addition, the shared file share PVC **`pvc-dpn-certs-fileshare`** must exist — it is mounted at `/tls` to provide `keystore.p12` and `truststore.p12`.

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
| `federatorClient.idp.jwksUrl` / `tokenUrl` / `authMode` | IDP endpoints and grant mode (as Server) | `https://auth-mtls.dsm01.dsiXXX.neso.energy/...` / `private_key_jwt` |
| `federatorClient.storage.azure.endpoint` | **Blob endpoint of the File Scan Service source storage account** if available else use a separate storage account (not the Server's account) | `https://stfss<env>dpn<region>01.blob.core.windows.net` |
| `federatorClient.storage.azure.container` | Container where inbound files are written (File Scan source container) | `dp-consumer-raw` |

### Step3c: Configure Key Vault If Used

The following parameter needs to be set if key vault is used as secret provider. 

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `keyvault.enable` | Use Azure Keyvault | true |
| `keyvault.name` | Key Vault holding the storage connection-string secrets | `kv-dpn-<env>-<region>-<seq>` |
| `keyvault.clientID` | Managed-identity client ID allowed to read from Key Vault | `<managed-identity-client-id>` |
| `keyvault.tenantId` | Azure AD tenant ID | `<tenant-id>` |

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
