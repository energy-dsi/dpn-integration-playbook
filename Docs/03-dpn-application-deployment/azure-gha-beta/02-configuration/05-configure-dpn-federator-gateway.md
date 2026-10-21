Release : 2.1.0 - Oct 2026

# DPN Federator Gateway Configuration

This section describes how to configure and deploy the **DPN Federator Gateway** (Server and Client, plus their supporting services) into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS). The Federator Gateway handles all secure communication between DPN node and other DPN nodes or the DSI DSM — sending and receiving data only to and from trusted parties over mutual TLS (mTLS).

**Depends on Vault and the Certificate Manager.** The Federator Gateway cannot start correctly until:

  - the **DPN Vault** is deployed, initialised, and loaded (it supplies the certificate, key pair, CA chain, and keystore/truststore **passwords** under `node-net/client/*`), and

  - the **Certificate Manager** has renewed the certificate into that same Vault path.

  The gateway reads this material directly from Vault and builds its mTLS keystore/truststore **in memory** at start-up (`vaultConfig.tlsEnabled: true`) — there is no shared file share to provision (`vaultConfig.mountCertFileShare: false`).

  Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) first.

  **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`, e.g. `dpn01`). Substitute your own values for `<env>` and `<cluster>` throughout. The Federator Client is deployed for a **single cluster only** — deploy one cluster at a time.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet Prerequisites](#step1-meet-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
- [Step3: Configure Environment](#step3-configure-environment)
  - [Step3a: Configure Federator Server](#step3a-configure-federator-server)
  - [Step3b: Configure Federator Client](#step3b-configure-federator-client)
  - [Step3c: Configure Kafka Security](#step3c-configure-kafka-security)
  - [Step3d: Configure Redis Security](#step3d-configure-redis-security)
  - [Step3e: Configure Azure ServiceAccount (Workload Identity)](#step3e-configure-azure-serviceaccount-workload-identity)
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
| Redis | In-memory cache for offsets and tokens, used by both Server and Client |
| **Federator Server** | Receives inbound connections from other DPNs' clients; reads from Kafka Source and streams data out over gRPC/mTLS |
| **Federator Client** | Connects outward to a remote Federator Server; writes received data into Kafka Target and its storage |

  **Kafka broker security.** Both Kafka Source and Kafka Target run with `SASL_SSL` on every listener by default (`kafka.authMode: sasl_ssl` — the production default; `ssl`/`plaintext` remain available for dev/test). The SASL mechanism is `OAUTHBEARER`: brokers and clients obtain and validate tokens from the DPN **Keycloak** realm (`kafkaSrc.oauth.tokenEndpointUrl` / `kafkaTarget.oauth.tokenEndpointUrl`), so both inter-broker and client Kafka traffic is authenticated against Keycloak, not static credentials. This client secret (`KC_SERVICE_CLIENT_SECRET`) is read directly from the `dpn-keycloak-secrets` Kubernetes secret created by the **DPN Authentication Service** deployment — Kafka Source/Target, Kafka UI, and the Federator Server/Client no longer pull an independent `KAFKA-OAUTH-CLIENT-SECRET` entry of their own, so there is one fewer secret to provision per environment.

 **`cloudProvider: azure`.** The `dpn-platform` chart's templates branch on this value to select Azure-native behaviour (Azure Standard Load Balancer, the Azure Key Vault Secrets Store CSI provider for Kafka's own credentials, Azure Blob Storage config, and the workload-identity `ServiceAccount` below) instead of the AWS equivalents. Every populated `values/azure/<environment>-<cluster>.yaml` file must set `cloudProvider: azure` — this is also the chart's own default.

**certificates and passwords flow (MUST READ):**

- The gateway builds its mTLS keystore/truststore **in memory** directly from certificate material in Vault (`vaultConfig.tlsEnabled: true`, `vaultConfig.tlsBasePath: node-net/client`) — no shared file share is used (`vaultConfig.mountCertFileShare: false`).

- The keystore/truststore **passwords are read from Vault** at start-up (`vaultConfig.keystorePasswordPath` / `truststorePasswordPath`) — they are **not** stored as Federator Key Vault secrets, except for the Vault truststore password itself (see below).

- The gateway can authenticate to Vault either via the Vault root token (`vaultConfig.authMethod: token`) or by **sharing the Certificate Manager's own AppRole identity** (`vaultConfig.authMethod: approle`, `vaultConfig.appRole.roleId` set to the Certificate Manager's `role_id`, `appRole.useSecretIdRef: true` so the `secret-id` is read from `certificate-manager-secrets` / `VAULT_APPROLE_SECRET_ID`) — the checked-in Azure values files all use the shared AppRole. The `dpn-federator-gateway` repository now also ships its own AppRole-provisioning workflow, `dpn-gha-certificate-manager-role-id-creation.yaml` (**DPN CD - Certificate Manager Role ID Creation (Vault AppRole Setup)**, `component: federator-gateway`), which creates a dedicated `federator` AppRole, stores its `secret-id` in Key Vault as `VAULT-APPROLE-SECRET-ID-FEDERATOR` (355-day expiry — re-run before it expires), and prints the `role_id` in the run summary to set as `vaultConfig.appRole.roleId` in `charts/dpn-platform/values/azure/<environment>-<cluster>.yaml`. See [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication).

- The Vault **truststore password** (Key Vault secret `TRUSTSTORE-PASSWORD`, the copy the Certificate Manager rewrites on every certificate renewal) is fetched from Azure Key Vault at deploy time and passed to the chart via `--set vaultConfig.truststorePassword` — this feeds the rendered properties ConfigMap only; the container's actual JVM flag reads the Secret directly (see [Step2](#step2-configure-secrets)). The only other Federator secrets in Key Vault are the **Azure Blob Storage access credentials** (one for the Server, a separate one for the Client) and, if using AppRole, the Vault `secret-id`.

**Storage separation for Server and Client (MUST READ)**

- Federator Server and Client use **separate Azure Blob Storage containers**. The Federator Client uses the **File Scan Service *source* container** (where scanned inbound files are deposited). Configure the Client's storage endpoint/credentials to point at the File Scan Service source container — not the Server's container.

- The Server's container is used to keep the data product files created by the organisation per data product pipeline.

---

## Step1: Meet Prerequisites

Ensure the following are in place **before** deploying the Federator Gateway:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed** | Renews the certificate into Vault, and creates the `certificate-manager-secrets` Kubernetes secret used for the Vault AppRole `secret-id` (or root token) |
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the `dpn-gha-vault-tls-bootstrap-cd.yaml` workflow (in the `dpn-federator-certificate-manager` repository); mounted at `/vault/truststore` so the gateway trusts Vault's HTTPS endpoint |
| 4 | **Vault authentication configured** | Set `vaultConfig.authMethod:` `approle` reusing the Certificate Manager's already-provisioned `role_id`/`secret_id` (what the checked-in Azure values files use), or `token`. See [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication) |
| 5 | **AKS cluster**, and an identity that can reach Azure Key Vault | Needed for the Vault truststore password and the Blob Storage credentials; see [Step2](#step2-configure-secrets) |
| 6 | **Azure Blob Storage container credentials created** | The two storage account keys/connection strings — see [Step2: Configure Secrets](#step2-configure-secrets) |
| 7 | **Azure Blob Storage containers provisioned** | The **Server's** container, and the **File Scan Service source** container used by the **Client** |
| 8 | **Azure Standard Load Balancers reserved** | One for the Server service — commonly **public-facing** with a reserved static public IP, since other DPN nodes must reach it externally — and one **internal** Standard Load Balancer for the Client service. See [Step3a](#step3a-configure-federator-server) |
| 9 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding |
| 10 | **Keycloak realm reachable** | Required when `kafka.authMode: sasl_ssl` (the production default) — the brokers and Kafka UI resolve tokens against `kafkaSrc.oauth.tokenEndpointUrl` / `kafkaTarget.oauth.tokenEndpointUrl` |
| 11 | **Container image tag available** | Built by the DSI CI process or prebuilt DSI image; supplied to the CD workflow as `imageTag` |
| 12 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step3: Configure Environment](#step3-configure-environment) |
| 13 | **Managed identity for the platform's `ServiceAccount` (Workload Identity)** | Required when `serviceAccount.create: true` (the Azure default) — see [Step3e](#step3e-configure-azure-serviceaccount-workload-identity) |

> **Kafka's Keycloak secrets come from a Kubernetes Secret, not Azure Key Vault.** On every cloud — not only Azure — Kafka Source/Target, Kafka UI, and the Federator Server/Client read the Keycloak admin password (`KEYCLOAK_ADMIN_PASSWORD`) and the OAuth client secret directly from the **`dpn-keycloak-secrets`** Kubernetes secret created by the **DPN Authentication Service** deployment (see the [Overview](#overview) note above) — no template in the `dpn-platform` chart currently reads a Key Vault prefix for these values, so configuring Key Vault alone will not provision them. This is separate from the Server/Client storage credentials in [Step2](#step2-configure-secrets), which continue to come from Azure Key Vault as before.

> **No shared file share — but check `mountCertFileShare` when provisioning a new environment.** The gateway reads its certificate material from Vault directly (see the certificates-and-passwords note in [Overview](#overview)) when `vaultConfig.mountCertFileShare: false` is set. The chart's own reference `values.yaml` still defaults this to `true` for backward compatibility — confirm your environment's values file explicitly sets it to `false` rather than relying on the reference default, or the deprecated file share is mounted again.

> **One-time setup:** Before running the CD workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) — the workflow **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`), and populate `dpn-federator-gateway/.github/config/azure/<environment>-<cluster>.json` (the workflow reads `RESOURCE_GROUP`, `AKS_CLUSTER`, `ARM_SUBSCRIPTION_ID`, `KEY_VAULT_NAME` and `NAMESPACE` from it — the release is deployed into `NAMESPACE`). The workflow logs in with the `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` repository or environment secrets (Azure OIDC federated identity).

---

## Step2: Configure Secrets

The following Kubernetes secrets must be present in the namespace when the gateway pods start. Two are created automatically by the CSI driver from Key Vault; two are provided by earlier components.

| Kubernetes Secret | Provided by | Used for |
|-------------------|-------------|----------|
| `federator-server-secrets` | CSI driver from AKV Server Blob Storage credentials | Server Blob Storage access |
| `federator-client-secrets` | CSI driver from AKV Client Blob Storage credentials | Client Blob Storage access |
| `certificate-manager-secrets` | Created by the **Certificate Manager** deployment | Provides the credential the gateway uses to authenticate to Vault and read the certificate material/passwords — either the root token (`VAULT_TOKEN`, `authMethod: token`) or, by pointing `vaultConfig.appRole.roleId` at the Certificate Manager's own `role_id`, its shared AppRole `secret-id` |
| `cert-manager-truststore` | Created by the **`dpn-gha-vault-tls-bootstrap-cd.yaml`** workflow (`dpn-federator-certificate-manager` repository) | `truststore.jks` mounted at `/vault/truststore` to trust the Vault HTTPS endpoint |
| `tls-auth-secret` | Created once by **`dpn-gha-tls-cd.yaml`** (`dpn-federator-certificate-manager` repository) — the same platform-wide secret the Certificate Manager reads (see [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md#step2-configure-vault-authentication)) | `TRUSTSTORE_PASSWORD`/`KEYSTORE_PASSWORD` keys, injected as `VAULT_TRUSTSTORE_PASSWORD` and (when `kafka.authMode: sasl_ssl`) `KAFKA_SSL_TRUSTSTORE_PASSWORD`/`KAFKA_SSL_KEYSTORE_PASSWORD` |

---

## Step3: Configure Environment

The gateway chart is `charts/dpn-platform` in `dpn-federator-gateway`. Set the parameters below in your environment/cluster's values file. The CD workflow resolves the values file from the `environment` and `cluster` inputs you select at runtime.

```text
dpn-federator-gateway/
  └── charts/
        └── dpn-platform/
          └── values/
              └── azure/
                └── <environment>-<cluster>.yaml <- Your environment + cluster overrides
```

> All component images (`redis`, `zookeeperSrc/Target`, `kafkaSrc/Target`, `kafkaUI`, `federatorServer`, `federatorClient`) point at GitHub Container Registry via `image.repository`, e.g. `ghcr.io/energy-dsi/<image>` — the provided Azure values files already do this; keep them on the DSI-published GHCR images. Only the parameters most likely to change per deployment are listed below.

### Step3a: Configure Federator Server

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorServer.config.management_node_base_url` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` |
| `federatorServer.idp.clientId` | Client ID received from DSM for this DPN node | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `federatorServer.idp.jwksUrl` | JWKS endpoint for verifying identity tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/certs` |
| `federatorServer.idp.tokenUrl` | Token endpoint for access tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| `federatorServer.service.internalLoadBalancer` | Whether the Server's Azure Standard Load Balancer is internal-only. The Server's is commonly set to `"false"` (**public-facing**) so external DPN nodes can reach it — unlike the Client, which stays internal | `"false"` |
| `federatorServer.service.publicIpResourceId` | Reserved Azure public IP resource ID(s) to pin to the Server's external Load Balancer, **comma-separated** if more than one front-end IP is needed | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/publicIPAddresses/<pip-name>` (leave unset for dynamically-assigned addresses) |

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
| `federatorClient.storage.provider` | `AZURE` on this path | `AZURE` — important to set based on cloud provider; this parameter decides which storage provider is invoked |
| `federatorClient.storage.azure.container` | **The File Scan Service source container**, if available, else a separate container (not the Server's) — note the key is `storage.azure.container`, **not** `storage.s3.bucket` | `dp-consumer-raw` |
| `federatorClient.storage.azure.endpoint` | Blob service endpoint of the storage account hosting the Client's container | `https://<storage-account-name>.blob.core.windows.net` |

**JobRunr dashboard authentication** (optional — off by default; see [Federator Client — JobRunr Dashboard User Guide](../../../05-dpn-user-interfaces/03-federator-client-job-runner-ui-operations.md) for the end-user access flow)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorClient.auth.enabled` | Front the JobRunr dashboard with a built-in Keycloak-authenticating gateway (`JobRunnerAuthGateway`) instead of leaving it open on the internal network | `true` |
| `federatorClient.auth.issuerUrl` / `.audience` | Keycloak realm issuer and OIDC client ID (reuses the same client Kafka's OAuth already uses) | as received from DSM |
| `federatorClient.auth.adminRole` / `.readerRole` | Keycloak roles gating full vs. view-only dashboard access — leave both blank to allow any authenticated user full access | `dpnadmin` / `dpnreader` |
| `federatorClient.service.jobRunnerAuthPort` | The gateway's own bind port — must differ from `jobRunnerPort`. Exposed via the `-external` Load Balancer Service **only when `nginxSidecar.enabled: false`** (see below) | `8086` |
| `federatorClient.tls.gatewaySecretName` | Optional Kubernetes `Secret` mounted at `/tls-gateway` for a browser-facing TLS identity in front of the Job Runner dashboard. Empty by default (no mount) — set once the DPN universal TLS prerequisite pipeline has issued a certificate for this hostname | `fed-gateway-tls` |

> **Keycloak redirect URI:** register `https://<federatorClient.name>-external.<namespace>.svc.cluster.local:<jobRunnerAuthPort>/oauth2/callback` on the Keycloak client.

**Nginx reverse-proxy sidecar (required)** — fronts the JobRunr dashboard for TLS termination:

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorClient.nginxSidecar.enabled` | Must be set to `true`. The chart default is `false`, which falls back to the Java-based proxy — known to have latency/stalling issues under load. Requires `federatorClient.auth.enabled: true` | `true` |
| `federatorClient.service.jobRunnerInternalPort` | Dashboard's internal bind port once nginx fronts it | `18085` |

### Step3c: Configure Kafka Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `kafka.authMode` | Security protocol for **every** Kafka listener (Source and Target) — `sasl_ssl` (production default), `ssl` (TLS only), or `plaintext` (dev/test only) | `sasl_ssl` |
| `kafkaSrc.oauth.tokenEndpointUrl` / `kafkaTarget.oauth.tokenEndpointUrl` | Keycloak token endpoint used for `OAUTHBEARER` login/validation when `authMode: sasl_ssl` | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| `kafkaUI.oauth.clientId` | OIDC client ID Kafka UI itself authenticates with (separate from `kafkaUI.oidcRbac`, below) | as received from DSM/Keycloak |
| `kafkaUI.tls.enabled` | Terminate HTTPS on Kafka UI's own listener, reusing the same `dpn-tls` keystore Kafka brokers and Redis already use. **Off by default** — only enable it in an environment where nothing else (e.g. an `oauth2-proxy`) depends on this listener staying plain HTTP, since Kafka UI drops its HTTP listener entirely once TLS is on | `false` |

> Switching `kafka.authMode` is a single value that reconfigures all broker listeners simultaneously — there is no need to change Kafka Source and Kafka Target separately. See [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md) to deploy the Keycloak instance and realm this depends on.

> **OpenTelemetry export.** `otel.tls.enabled` (default `true`) drives both the Federator Server/Client's OTLP exporter endpoint scheme and whether the OTel Collector truststore env vars are set at all — see [Configure DPN Health Monitoring Service](03-configure-dpn-health-monitoring-service.md) if your Collector's OTLP receiver terminates TLS (the default). `otel.collector.host` / `otel.collector.port` point at the Collector Service. See also [Step3f](#step3f-configure-otel-collector-security) for OTel's own TLS/OAuth2 security parameters.

### Step3d: Configure Redis Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorServer.redis.tlsEnabled` / `federatorClient.redis.tlsEnabled` | Whether the Server/Client connect to Redis over TLS (rendered as `redis.tls.enabled`) — **on by default** in every environment, not opt-in | `true` |
| `federatorServer.redis.truststorePath` / `federatorClient.redis.truststorePath` | Client-side truststore the Server/Client use to trust Redis's certificate (rendered as `redis.truststore.path`). The checked-in Azure values files point both at the `dpn-tls` truststore mounted at `/etc/secrets` | `/etc/secrets/truststore.jks` |

Redis's own server certificate is **not** a separate value to configure — it's extracted at pod start-up (by an init container, using `openssl`) from the same shared `dpn-tls` keystore Kafka and Kafka UI already use (see [Step3c](#step3c-configure-kafka-security)), whose SAN already covers the in-cluster Redis hostname. Redis is configured for **server-authentication only** (`--tls-auth-clients no`) — there is no client certificate/mTLS requirement for connecting to it, mirroring Kafka's own `SASL_SSL` listener (`KAFKA_SSL_CLIENT_AUTH=none`).

> **No Redis username/password (ACL) authentication.** Earlier releases supported `redis.username`/`redis.password` for Redis's own ACL auth — these have been **removed**. Access control is now enforced entirely at the application layer: every Redis-touching call site (other than the Federator's own IDP token cache, which deliberately bypasses this to avoid a circular dependency) requires a valid Keycloak session before a connection is returned. This is independent of `kafka.authMode` — Redis TLS and its Keycloak gate apply regardless of that Kafka setting.
>
> **The REST Federator Gateway's separate `dpn-redis` release is also TLS-only with Keycloak gating.** It is a different cache with its own settings — see [Configure DPN REST Federator Gateway, Step3f](06-configure-dpn-rest-federator-gateway.md#step3f-configure-redis-security).

### Step3e: Configure Azure ServiceAccount (Workload Identity)

A single `ServiceAccount`, shared by Kafka Source/Target, Zookeeper Source/Target, the Federator Server, and the Federator Client, provides Azure Workload Identity credentials to the Secrets Store CSI driver.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `serviceAccount.create` | Render the `ServiceAccount` and attach it to every pod in this release | `true` |
| `serviceAccount.name` | Name of the `ServiceAccount` | `dpn-federator-gateway` |
| `serviceAccount.azureClientId` | Client ID of the user-assigned managed identity the `ServiceAccount` is federated to | `<azure-client-id>` |
| `keyvault.clientID` | Client ID of the user-assigned managed identity the Key Vault CSI driver uses. Set in `charts/dpn-platform/values/azure/<environment>-<cluster>.yaml` | `<azure-client-id>` |
| `keyvault.name` | Azure Key Vault the CSI driver reads from. Set in `charts/dpn-platform/values/azure/<environment>-<cluster>.yaml` | `<key-vault-name>` |
| `keyvault.tenantId` | Microsoft Entra tenant ID of that Key Vault. Set in `charts/dpn-platform/values/azure/<environment>-<cluster>.yaml` | `<tenant-id>` |
| `secretsManager.secretPrefix` | Not used on Azure — Key Vault objects are read by flat name, not a prefixed path (Kafka's Keycloak admin password and OAuth client secret come from the `dpn-keycloak-secrets` Kubernetes secret instead; see the note above [Step1](#step1-meet-prerequisites)) | n/a |

The managed identity's federated credential must scope the OIDC subject to `system:serviceaccount:<namespace>:<serviceAccount.name>`, and the identity must be granted Key Vault `get`/`list` on secrets for `federatorClient.storage.azure.container`'s access keys — the Server has no static container parameter of its own (see [Step3a](#step3a-configure-federator-server)).

> **Kafka pods on AWS disable Python auto-instrumentation; Azure is unaffected.** Kafka Source/Target and Zookeeper Source/Target pods carry `instrumentation.opentelemetry.io/inject-python: "false"` only when `cloudProvider: aws` — on this Azure path the cluster's OTel auto-instrumentation webhook injects normally, since the incompatibility is specific to the AWS path's Python 3.9 startup tooling. No action needed on Azure.

### Step3f: Configure OTel Collector Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `otel.tls.enabled` | Whether OTLP export uses HTTPS against the Collector — **on by default**, matching every environment's behaviour before this flag existed | `true` |
| `otel.oauth.enabled` | Attach an `Authorization: Bearer` token (fetched via the `dpn-service-client` Keycloak client — the same one already used to gate Redis access, see [Step3d](#step3d-configure-redis-security)) to every OTLP export call — **on by default in every environment** | `true` |
| `otel.truststorePath` | Trust anchor for the Collector's OTLP HTTPS receiver (server-side TLS only). Same JKS truststore Redis and the JobRunr dashboard auth already use | `/etc/secrets/truststore.jks` |

No separate Keycloak client or secret is provisioned for OTel — it reuses `dpn-service-client`, the same credential already wired for Redis/Kafka OAuth (delivered via the `dpn-keycloak-secrets` Kubernetes secret's `KC_SERVICE_CLIENT_SECRET` key — see the [Overview](#overview) note). Setting `otel.tls.enabled: false` only works once the Collector side also exposes a genuine plaintext listener — today it terminates TLS unconditionally, so a plaintext exporter against it fails the handshake outright rather than falling back.

---

## Step4: Configure Deployment Parameters

The Federator Gateway is deployed with a **single run** of the `dpn-gha-federator-gateway-cd.yaml` GitHub Actions workflow in `dpn-federator-gateway`. One run applies the environment/cluster values file on top of `values.yaml` and deploys all components in the single Helm release `dpn-platform`.

```text
dpn-federator-gateway/
├── .github/
│   ├── workflows/
│   │   ├── dpn-gha-federator-gateway-cd.yaml
│   │   ├── dpn-gha-federator-gateway-rollback.yaml    <- DPN Rollback - Federator Gateway
│   │   └── dpn-gha-federator-gateway-uninstall.yaml   <- DPN Uninstall - Federator Gateway
│   ├── config/
│   │   └── azure/<environment>-<cluster>.json
│   └── actions/
│       └── cloud-login/action.yml
└── charts/
    └── dpn-platform/
        └── values/azure/<environment>-<cluster>.yaml
```

The workflow sets `PARAMETERS_FILE=.github/config/azure/<environment>-<cluster>.json`, `HELM_DIR=charts/dpn-platform`, `RELEASE_NAME=dpn-platform` and `VALUES_FILE=charts/dpn-platform/values/azure/<environment>-<cluster>.yaml` (the `azure` segment comes from the `cloud` input), and its job runs on a `[self-hosted, vmss]` runner bound to the GitHub Environment `<environment>-<cluster>`.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | The **single** target DPN cluster — `dpn01` or `dpn02` (default `dpn01`). Deploy one cluster at a time; the Client is configured for this one cluster |
| `cloud` | `azure` / `aws` / `gcp` — the default is `aws`, so select `azure` explicitly on this path |
| `imageTag` | **Required**, no default — tag of the Federator images to deploy (from the CI build or prebuilt DSI image); applied to both `federatorServer.image.tag` and `federatorClient.image.tag` |
| `serverImageRepository` | Optional — override the Server image path after `ghcr.io/energy-dsi/` for this run only (e.g. `dpn-federator-server`). Leave blank to use the environment's configured repository |
| `clientImageRepository` | Optional — same override for the Client image path (e.g. `dpn-federator-client`). Leave blank to use the environment's configured repository |

To run it: **Actions → DPN CD - Federator Gateway → Run workflow**, fill in the inputs, then **Run workflow**. On success, the deployed image digests are captured as a workflow artifact.

Once this is deployed, provision the per-product producer/consumer pods and the Blob Storage container/Kafka-topic prerequisites they need — see [Configure DPN Data Pipelines](07-configure-dpn-data-pipelines.md) and the [installation guide](../03-installation/05-dpn-federator-gateway-installation-process.md).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
