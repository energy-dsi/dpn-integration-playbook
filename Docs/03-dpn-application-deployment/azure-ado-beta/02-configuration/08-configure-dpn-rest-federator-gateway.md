# DPN REST Federator Gateway Configuration

This section describes how to configure and deploy the **DPN REST Federator Gateway**, provided by the `dpn-rest-federator-gateway` repository. It is a **REST/HTTPS-based alternative to the gRPC Federator Gateway**, for producers and consumers that need a synchronous, request/response API instead of a streamed Kafka-to-Kafka pipeline. It reuses the same Management Node, Identity Provider, and certificate infrastructure as the gRPC Federator Gateway, so both federation styles can be run side by side against a single DPN control plane.

> **Depends on Vault and the Certificate Manager.** Like the gRPC Federator Gateway, the REST Federator Gateway reads its mTLS keystore/truststore material directly from Vault at start-up — there is no shared file share. Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](03-configure-dpn-certificate-manager.md) first, and ensure the certificate's SANs cover this gateway's endpoint (e.g. `producer-rest01.<dpn>...`) in addition to the gRPC Federator's.

> **Single environment, single cluster, multi-cloud:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`). Unlike the gRPC Federator, the CD pipeline also takes a **`cloud`** parameter (`azure`/`aws`/`gcp`) that selects which per-cloud config file to resolve — see [Step4](#step4-configure-deployment-parameters).

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Configure the Gateway](#step3a-configure-the-gateway)
  - [Step3b: Configure Vault Authentication](#step3b-configure-vault-authentication)
- [Step4: Configure Deployment Parameters](#step4-configure-deployment-parameters)
- [Integrating a Consumer](#integrating-a-consumer)
- [Review Notes](#review-notes)

---

## Overview

The gateway is a **generic authorising reverse proxy** — it carries no business logic and no knowledge of any particular data product. On the producer (server) side:

1. Terminates mTLS and validates the caller's JWT against the DSM Identity Provider (Keycloak) — client identity comes from the token's `azp`/`client_id` claim.
2. Verifies the caller is a registered consumer of a REST data product via the Management Node's product configuration.
3. Verifies the caller's certificate has not been revoked, via an OCSP check against the Management Node.
4. Checks the request's HTTP method and path against that product's allowed-path configuration.
5. Forwards the authorised request — method, path, query string, headers and body — verbatim to a configured internal backend (authenticated with a shared API key, since the backend sits outside the DPN trust chain), and returns the backend's response verbatim.

On the consumer (client) side, an organisation imports the `rest-federator-client` library into its own application rather than deploying a separate component. The library bootstraps from the Management Node (`getConsumerConfig`) to discover subscribed products, builds a per-product mTLS-enabled HTTP client with certificate hot-reload, attaches a Bearer token, and exposes `get`/`post`/`put`/`patch`/`delete(ProductKey(organisation, productName), path, ...)`. The client does **not** police allowed paths itself — the gateway enforces that authoritatively.

| Component | Purpose |
|-----------|---------|
| REST Federator Server (`dpn-rest-federator`) | The gateway described above. Deployed as a container |
| Redis (`dpn-redis`, this chart's own release) | Cache used by the gateway; deployed and rolled back independently of the gateway itself |
| `rest-federator-client` | Importable library jar — not a deployed component. A consumer's own application depends on it |

Supporting HTTP verbs: GET, POST, PUT, PATCH, DELETE.

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed**, with this gateway's endpoint included in the certificate's SANs | e.g. `producer-rest01.<dpn>...` alongside the gRPC Federator's `producer.<dpn>...`/`consumer.<dpn>...` — see [Configure DPN Certificate Manager, Step3a](03-configure-dpn-certificate-manager.md#step3a-set-up-helm-values) |
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the Vault `vault-tls-bootstrap-cd` pipeline; trusts Vault's HTTPS endpoint |
| 4 | **Vault AppRole identity provisioned** *(recommended)*, or the root token | See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-vault-approle-setup-cd-recommended) |
| 5 | **DPN Authentication Service (Keycloak) reachable** | Inbound JWTs are validated against its JWKS endpoint. See [Configure DPN Authentication Service](07-configure-dpn-authentication-service.md) |
| 6 | **AKS cluster, user-assigned managed identity, Secrets Store CSI driver** | Required when `keyvault.enabled: true` |
| 7 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding, same as the gRPC Federator |
| 8 | **A backend to proxy to** | The gateway forwards authorised requests verbatim to `backend.baseUrl` — this is the organisation's own service, not provided by this chart |
| 9 | **Backend API key created** | `kubectl create secret generic dpn-backend-api-key --from-literal=apiKey=<value> -n <namespace>` (or via Key Vault — see [Step2](#step2-configure-secrets)) |
| 10 | **Container image tag available** | Supplied to the CD pipeline as `imageTag` |
| 11 | **`config/<cloud>/<env>-<cluster>.json` and `values-<env>-<cluster>.yaml` populated** | See [Step3](#step3-environment-configuration) and [Step4](#step4-configure-deployment-parameters) |

---

## Step2: Configure Secrets

Only the backend API key is provisioned outside the chart — everything else (certificate material, Vault credentials) is sourced the same way as the gRPC Federator Gateway.

| Secret | Mechanism | Purpose |
|--------|-----------|---------|
| Backend API key | Kubernetes `Secret` (`restFederatorServer.backend.apiKeySecret`, default name `dpn-backend-api-key`), or synced from Key Vault (`BACKEND-API-KEY`) via the CSI driver when `keyvault.enabled: true` | Authenticates the gateway to the internal backend (`X-Backend-Api-Key` header) |
| Vault credentials | AppRole `secret-id` (recommended) or root token, via `certificate-manager-secrets` — same mechanism as the gRPC Federator Gateway | Reads certificate material and keystore/truststore passwords from Vault |

---

## Step3: Environment Configuration

Copy `values.yaml` (reference — do not edit directly) to `values-<env>-<cluster>.yaml`.

```text
Root-Repository
  └── charts
        └── dpn-rest-federator
              ├── values.yaml                  <- Reference file; do not edit directly
              └── values-<env>-<cluster>.yaml  <- Your environment + cluster overrides
```

### Step3a: Configure the Gateway

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.tls.enabled` | Whether this listener terminates HTTPS itself | `true` |
| `restFederatorServer.mtls.enabled` | Require inbound connections to present a client certificate. Off by default so the gateway can sit behind infrastructure that cannot present one (e.g. health probes) | `false` |
| `restFederatorServer.backend.baseUrl` | Internal backend the gateway proxies authorised requests to | `http://<backend-service>:8080` |
| `restFederatorServer.producerId` | This producer's identifier, as registered with the Management Node | `<producer-id>` |
| `restFederatorServer.managementNode.baseUrl` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` |
| `restFederatorServer.idp.clientId` / `jwksUrl` / `tokenUrl` | Identity Provider client ID and endpoints (as the gRPC Federator) | `https://auth-mtls.dsm01.dsiXXX.neso.energy/...` |
| `restFederatorServer.redis.host` / `port` | Points at this chart's own `dpn-redis` release | `dpn-rest-federator-redis` / `6379` |

### Step3b: Configure Vault Authentication

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.vault.authMethod` | `token` or `approle` (recommended) | `approle` |
| `restFederatorServer.vault.appRole.roleId` | Non-sensitive role-id, from `vault-approle-setup-cd` | `<role_id>` |
| `restFederatorServer.vault.appRole.useSecretIdRef` | Source the AppRole `secret-id` from a Kubernetes Secret (`certificate-manager-secrets` / `VAULT_APPROLE_SECRET_ID`) rather than a plaintext value | `true` |
| `restFederatorServer.vault.tlsBasePath` | KV v2 path holding the certificate material | `node-net/client` |
| `restFederatorServer.vault.tlsKeystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

> As with the gRPC Federator, `vault.tlsEnabled: true` is what removes the need for a shared file share — the gateway reads its TLS material straight from Vault.

---

## Step4: Configure Deployment Parameters

Deployed with the CD pipeline `rest-federator-cd.yml` in the `dpn-rest-federator-gateway` repository:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── rest-federator-cd.yml
```

The pipeline runs two stages, each independently rollback-able: **Deploy_Redis** (the cache this chart owns) → **Deploy_RestFederator** (the gateway). Each stage begins with its own environment-bound approval gate.

Runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `ServiceConnection` | Azure service connection for your environment |
| `environment` | Your target environment |
| `cluster` | The target DPN cluster — `dpn01` or `dpn02` |
| `cloud` | Target cloud provider — `azure`, `aws`, or `gcp`. Resolves `.pipelines/azure-pipelines/config/<cloud>/<env>-<cluster>.json` |
| `imageTag` | Tag of the REST Federator Server image to deploy (the CI run's build ID) |

---

## Integrating a Consumer

A consumer does not deploy a component from this chart — it imports the `rest-federator-client` library into its own application:

```xml
<dependency>
  <groupId>org.dsi.dpn</groupId>
  <artifactId>rest-federator-client</artifactId>
  <version>1.0.0</version>
</dependency>
```

The client is configured via a `client.properties` file (pointed to by the `FEDERATOR_CLIENT_PROPERTIES` environment variable) naming a shared `common-configuration.properties` — the same properties file shape the gRPC Federator client uses, supplying the Management Node URL, Identity Provider settings, and either keystore/truststore file paths or `vault.*` keys to source mTLS material from Vault instead.

Once initialised, the client bootstraps a registration per subscribed product and exposes it by `ProductKey(organisation, productName)`:

```java
PropertyUtil.init(new File(System.getenv()
        .getOrDefault("FEDERATOR_CLIENT_PROPERTIES", "client.properties")));

RestClient client = new RestClient();   // bootstraps from getConsumerConfig

ProductKey orgB = new ProductKey("Org B", "Data Product X");
String body = client.get(orgB, "/api/v1/things?id=42", Map.of());
```

See the `dpn-rest-federator-gateway` repository's `demo/demo-runner-client` for a complete worked example, including the expected `403` behaviour when a path falls outside a product's allowed-path configuration.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| — | — | Draft — pending DSI Assurance review | V0.1.0 |
