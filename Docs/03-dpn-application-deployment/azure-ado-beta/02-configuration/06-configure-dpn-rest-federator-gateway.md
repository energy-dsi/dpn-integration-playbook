# DPN REST Federator Gateway Configuration

This section describes how to configure and deploy the **DPN REST Federator Gateway**, provided by the `dpn-rest-federator-gateway` repository. It is a **REST/HTTPS-based alternative to the gRPC Federator Gateway**, for producers and consumers that need a synchronous, request/response API instead of a streamed Kafka-to-Kafka pipeline. It reuses the same Management Node, Identity Provider, and certificate infrastructure as the gRPC Federator Gateway, so both federation styles can be run side by side against a single DPN control plane.

> **Depends on Vault and the Certificate Manager.** Like the gRPC Federator Gateway, the REST Federator Gateway reads its mTLS keystore/truststore material directly from Vault at start-up — there is no shared file share. Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) first, and ensure the certificate's SANs cover this gateway's endpoint (e.g. `producer-rest01.<dpn>...`) in addition to the gRPC Federator's.

> **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`), deployed to AKS via the same Azure DevOps pipeline model as the gRPC Federator — see [Step4](#step4-configure-deployment-parameters). An AWS deployment path exists as a separate, interim (non-pipeline) process documented in this playbook's AWS section; there is no single pipeline parameter that switches cloud target for this component today.

---

## Table of Contents

- [Overview](#overview)
- [REST Endpoint Behaviour and Release Scope](#rest-endpoint-behaviour-and-release-scope)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Configure the Gateway](#step3a-configure-the-gateway)
  - [Step3b: Configure Vault Authentication](#step3b-configure-vault-authentication)
  - [Step3c: Configure Autoscaling](#step3c-configure-autoscaling)
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

## REST Endpoint Behaviour and Release Scope

Unlike the gRPC Federator's static topic wiring, a REST product's endpoint shape is **not a Helm value** — it is fetched at runtime from the Management Node as part of that product's configuration (a `topic` array of `{request_type, request_path}` entries) and enforced by the gateway on every request: is the caller a registered consumer of this product → is its certificate still valid (OCSP) → does the requested method/path match one of the product's allowed entries. Any failed check returns `403`, and an unparseable or empty allowed-path configuration denies everything by default (fail closed).

This release delivers **endpoint registration, method-listing, GET/POST proxying, and consumer authorisation** (deny-if-unauthorised) end to end. The following are **explicitly out of scope for this release** and deferred to PI5, per functional-requirement review:

| Not yet delivered | Why |
|---|---|
| Payload/template alignment validation | The gateway is a generic byte-for-byte proxy — it does not inspect or reshape the payload against a Data Product's template. Requires a dedicated schema-validation service, planned for PI5 |
| Filtering / slicing and documented query parameters | No query-parameter handling exists beyond passthrough to the backend |
| REST metadata describing endpoint capabilities | Not generated by the gateway; would be part of the same PI5 schema-validation work |
| Audit logging of access attempts | Planned for a follow-up sprint via the OpenSearch/HTTPS observability work — not present in this release |

> **One-time connection reuse.** The `rest-federator-client` library builds one mTLS-enabled HTTP client per subscribed product when it starts up, and reuses that same client for the life of the process — it is rebuilt only on certificate rotation (via a file watcher), never per request. There is no separate "sharing agreement" record: a consumer's authorisation to connect is enforced by its membership in that product's consumer list, which the gateway fetches dynamically from the Management Node — this list **is** the technical sharing agreement check for REST.

> **Automatic pickup of new REST products.** The gateway re-fetches its producer/consumer configuration from the Management Node on a short TTL (`restFederatorServer.managementNode.cacheTtlSeconds`, default 60s) rather than only at start-up — so a newly-published REST product becomes reachable over an already-established connection with no gateway reconfiguration or restart. This release does **not** yet track a received version ID or timestamp for each update (no such field or storage exists); that bookkeeping, and the broader Data Product versioning design for REST, is deferred to PI5 (tracked separately as an enabler).

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed**, with this gateway's endpoint included in the certificate's SANs | e.g. `producer-rest01.<dpn>...` alongside the gRPC Federator's `producer.<dpn>...`/`consumer.<dpn>...` — see [Configure DPN Certificate Manager, Step3a](04-configure-dpn-certificate-manager.md#step3a-set-up-helm-values) |
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the Vault `vault-tls-bootstrap-cd` pipeline; trusts Vault's HTTPS endpoint |
| 4 | **Vault AppRole identity provisioned** *(recommended)*, or the root token | No policy file or setup script ships in this repository yet — the Vault-side AppRole role must be authored/created manually. See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended) |
| 5 | **DPN Authentication Service (Keycloak) reachable** | Inbound JWTs are validated against its JWKS endpoint. See [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md) |
| 6 | **AKS cluster, user-assigned managed identity, Secrets Store CSI driver** | Required when `keyvault.enabled: true` |
| 7 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding, same as the gRPC Federator |
| 8 | **A backend to proxy to** | The gateway forwards authorised requests verbatim to `backend.baseUrl` — this is the organisation's own service, not provided by this chart |
| 9 | **Backend API key created** | `kubectl create secret generic dpn-backend-api-key --from-literal=apiKey=<value> -n <namespace>` (or via Key Vault — see [Step2](#step2-configure-secrets)) |
| 10 | **Container image tag available** | Supplied to the CD pipeline as `imageTag` |
| 11 | **`values-<env>-<cluster>.yaml` populated** | See [Step3](#step3-environment-configuration) and [Step4](#step4-configure-deployment-parameters) |

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
| `restFederatorServer.vault.appRole.roleId` | Non-sensitive role-id for this component's AppRole role | `<role_id>` |
| `restFederatorServer.vault.appRole.useSecretIdRef` | Source the AppRole `secret-id` from a Kubernetes Secret (`certificate-manager-secrets` / `VAULT_APPROLE_SECRET_ID`) rather than a plaintext value | `true` |
| `restFederatorServer.vault.tlsBasePath` | KV v2 path holding the certificate material | `node-net/client` |
| `restFederatorServer.vault.tlsKeystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

> **No DSI-provided AppRole automation exists yet for this component.** Unlike the Certificate Manager (automated pipeline) and the Federator Gateway (a manual script shipped in that repo), the `dpn-rest-federator-gateway` repository ships no Vault policy file or setup script at all — the chart above accepts AppRole values, but there is nothing to run to actually provision the role in Vault. An organisation using `authMethod: approle` for this component must author its own policy (the `pki-client/*` read/list shape used by the other two components is a reasonable starting point) and create the AppRole role directly, following the same manual pattern described for the Federator Gateway. See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended).

> As with the gRPC Federator, `vault.tlsEnabled: true` is what removes the need for a shared file share — the gateway reads its TLS material straight from Vault. The TLS bundle is written to a short-lived, ephemeral-password file on disk at start-up (a JVM-managed temp location, not a mounted volume) rather than being applied purely in memory, and is rewritten on the same schedule as `vault.tls.reload.interval.seconds` (default 3600s) — hot-swapped with no pod restart. No configuration keys changed for this; it is the same `vault.tls*` settings above, just delivered through a more reliable mechanism.

### Step3c: Configure Autoscaling

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `hpa.enabled` | Horizontal Pod Autoscaler for the gateway — **on by default**, not opt-in | `true` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.scaleUp.cpuUtilization` / `.memoryUtilization` | Target average utilisation (%) that triggers scale-up | `80` / `80` |
| `hpa.scaleUpBehavior.stabilizationWindowSeconds` / `hpa.scaleDown.stabilizationWindowSeconds` | How long a scale-up/scale-down decision must hold before acting | `60` / `300` |

No per-environment values file currently overrides these — every environment inherits the chart defaults above.

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
