Release : 2.1.0 - Oct 2026

# DPN REST Federator Gateway Configuration

This section describes how to configure and deploy the **DPN REST Federator Gateway**, provided by the `dpn-rest-federator-gateway` repository. It is a **REST/HTTPS-based alternative to the gRPC Federator Gateway**, for producers and consumers that need a synchronous, request/response API instead of a streamed Kafka-to-Kafka pipeline. It reuses the same Management Node, Identity Provider, and certificate infrastructure as the gRPC Federator Gateway, so both federation styles can be run side by side against a single DPN control plane.

> **Depends on Vault and the Certificate Manager.** Like the gRPC Federator Gateway, the REST Federator Gateway reads its mTLS keystore/truststore material directly from Vault at start-up — there is no shared file share. Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) first, and ensure the certificate's SANs cover this gateway's endpoint (e.g. `producer-rest01.<dpn>...`) in addition to the gRPC Federator's.

> **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`), deployed to AKS via the same Azure DevOps pipeline model as the gRPC Federator — see [Step4](#step4-configure-deployment-parameters). An AWS deployment path exists as a separate, interim (non-pipeline) process documented in this playbook's AWS section; there is no single pipeline parameter that switches cloud target for this component today.

---

## Table of Contents

- [Overview](#overview)
- [Repository Components](#repository-components)
  - [Running the reference demo](#running-the-reference-demo)
- [REST Endpoint Behaviour and Release Scope](#rest-endpoint-behaviour-and-release-scope)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Configure the Gateway](#step3a-configure-the-gateway)
  - [Step3b: Configure Vault Authentication](#step3b-configure-vault-authentication)
  - [Step3c: Configure Autoscaling](#step3c-configure-autoscaling)
  - [Step3d: Configure OTel Collector Security](#step3d-configure-otel-collector-security)
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

## Repository Components

The `dpn-rest-federator-gateway` repository is a Maven multi-module build (`mvn clean install` from the root builds everything, in dependency order) containing four distinct pieces. Only the first two are part of the actual DPN data path — the other two are an illustrative reference implementation, useful for testing a deployment end to end but not required by it.

| Module (path in repo) | Artifact / release | Role |
|---|---|---|
| `server/` — `rest-federator-server` | Deployed container (`dpn-rest-federator`) | **The gateway itself** — the generic authorising reverse proxy described in [Overview](#overview). This is the only server-side piece a producer runs. |
| `client/` — `rest-federator-client` | Importable library jar | The **consumer's** integration point — a participant imports this into their own application (it is never deployed as its own container) and gets mTLS, JWT, OCSP, Management Node bootstrap, and certificate hot-reload handled for it. See [Integrating a Consumer](#integrating-a-consumer). |
| `demo/demo-runner-server/` — `demo-runner-server` | Deployed container, its own Helm chart (`dpn-demo-runner-server`) | **Example only — illustrative, not production.** A standalone Spring Boot backend implementing a subset of the MHHS FMAR specification (`GET/POST /api/v1/fmar/...`), sitting *behind* the gateway as its internal backend. Data is held in memory, not persisted. Terminates HTTPS with the same Vault-issued certificate the gateway uses (server-only TLS) and requires the shared backend API key on every call. |
| `demo/demo-runner-client/` — `demo-runner-client` | One-shot Kubernetes Job, its own Helm chart (`dpn-demo-runner-client`) | **Example only.** A plain Java console application (no Spring) that imports `rest-federator-client` and drives a scripted call sequence against `demo-runner-server` *through* the gateway — register an asset, look it up, attempt a duplicate registration (expects `409`), and call a path deliberately outside the product's allowed-path configuration (expects `403`) — to demonstrate the gateway's authorisation working end to end. |

`server` and `client` are the two sides of a federated exchange — the gateway is the sole authority on authorisation (consumer + method/path, from producer config); the client library only handles the plumbing and lets the integrator drive the calls. `demo-runner-server`/`demo-runner-client` are a worked example of exactly that shape, useful for validating a new environment's deployment without needing a second real organisation to test against.

### Running the reference demo

Deployed by its own pipeline, independent of the gateway's own CD pipeline:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── demo-runner-cd.yml
```

The pipeline runs two independent stages — **Deploy_DemoRunnerServer** (a normal Deployment + Service) and **Run_DemoRunnerClient** (a one-shot Job; since a Job's pod spec is immutable, every run creates a *new* Job object suffixed with the build ID, rather than re-triggering an existing one).

| Parameter | Description |
|-----------|-------------|
| `ServiceConnection` / `environment` / `cluster` | As with the gateway's own CD pipeline |
| `imageTag` | Tag of the demo-runner images to deploy (a separate CI build from the gateway's own) |
| `deployServer` / `runClient` | Booleans — run either stage independently, e.g. `runClient: true` with `deployServer: false` to re-run just the client against an already-deployed server |
| `mpan`, `postcode`, `assetId`, `fspId` | Demo run parameters passed into the client Job's environment — the specific asset to register/look up on each run |

`organisationName`/`productName` (which organisations/products the client targets) are **not** pipeline parameters — they're set in the `dpn-demo-runner-client` chart's own values file per environment (blank targets every subscribed product). Completed Jobs are kept for `ttlSecondsAfterFinished` (1h default) so their output can be read afterward:

```bash
kubectl logs job/dpn-demo-runner-client-<buildId> -n <namespace>
```

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

> **Automatic pickup of new REST products.** The gateway re-fetches its producer/consumer configuration from the Management Node on a short TTL (`restFederatorServer.managementNode.cacheTtlSeconds`, default 60s) rather than only at start-up — so a newly-published REST product becomes reachable over an already-established connection with no gateway reconfiguration or restart. 
---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed**, with this gateway's endpoint included in the certificate's SANs | e.g. `producer-rest01.<dpn>...` alongside the gRPC Federator's `producer.<dpn>...`/`consumer.<dpn>...` — see [Configure DPN Certificate Manager, Step3a](04-configure-dpn-certificate-manager.md#step3a-set-up-helm-values) |
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the `dpn-tls-cd` pipeline; trusts Vault's HTTPS endpoint |
| 4 | **Vault AppRole identity provisioned** *(recommended)*, or the root token | Reuse the Certificate Manager's — run `vault-approle-setup-cd` once (if not already done for the Certificate Manager), then manually paste that same role-id into `restFederatorServer.vault.appRole.roleId` below. No separate policy/script is needed. See [Configure DPN Vault Service, Step 3D](01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended) |
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

> **Vault truststore password (deploy-time).** The gateway CD pipeline reads **`TRUSTSTORE-PASSWORD`** from Key Vault and injects it as `restFederatorServer.vault.truststorePassword`, rendered into the backend's config at deploy time. This secret is written by the `dpn-tls-cd` pipeline on every certificate renewal — no manual creation needed, provided `dpn-tls-cd` has already run (see [Configure DPN Vault Service, Step 3A](01-configure-dpn-vault-service.md#step-3a-configure-dpn-universal-tls-dpn-tls-cd)). As with the gRPC Federator Gateway, this value is captured at deploy time — re-run this CD pipeline after a `dpn-tls-cd` password rotation to pick up the new value.

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
| `restFederatorServer.mtls.enabled` | Require inbound connections to present a client certificate | `true` - **Note** - Set this value to false when the mTLS is negotiated over Edge proxy or at layer 7 load balancer |
| `restFederatorServer.backend.baseUrl` | Internal backend the gateway proxies authorised requests to | `https://<backend-service>:<port-number>` |
| `restFederatorServer.managementNode.baseUrl` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` where XXX is based on DSI environment |
| `restFederatorServer.idp.clientId` / `jwksUrl` / `tokenUrl` | Identity Provider client ID and endpoints (as the gRPC Federator) | `https://auth-mtls.dsm01.dsiXXX.neso.energy/...` |
| `restFederatorServer.redis.host` / `port` | Points at this chart's own `dpn-redis` release | `dpn-rest-federator-redis` / `6379` |

### Step3b: Configure Vault Authentication

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.vault.authMethod` | `token` or `approle` (recommended) | `approle` |
| `restFederatorServer.vault.appRole.roleId` | The **same** role-id as the Certificate Manager's AppRole — copied manually from the `vault-approle-setup-cd` pipeline's log output, same as every other component reusing this identity | `<role_id>` |
| `restFederatorServer.vault.appRole.useSecretIdRef` | Source the AppRole `secret-id` from a Kubernetes Secret (`certificate-manager-secrets` / `VAULT_APPROLE_SECRET_ID`) rather than a plaintext value | `true` |
| `restFederatorServer.vault.tlsBasePath` | KV v2 path holding the certificate material | `node-net/client` |
| `restFederatorServer.vault.tlsKeystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

### Step3c: Configure Autoscaling

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `hpa.enabled` | Horizontal Pod Autoscaler for the gateway — **on by default**, not opt-in | `true` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.scaleUp.cpuUtilization` / `.memoryUtilization` | Target average utilisation (%) that triggers scale-up | `80` / `80` |
| `hpa.scaleUpBehavior.stabilizationWindowSeconds` / `hpa.scaleDown.stabilizationWindowSeconds` | How long a scale-up/scale-down decision must hold before acting | `60` / `300` |

No per-environment values file currently overrides these — every environment inherits the chart defaults above.

### Step3d: Configure OTel Collector Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.otel.tls.enabled` | Turns on HTTPS for OTLP export to the Collector. Defaults to `false`, so existing environments aren't affected unless someone opts in | `false` |
| `restFederatorServer.otel.oauth2.enabled` | Adds an `Authorization: Bearer` token to OTLP export, using the `dpn-service-client` Keycloak client already used elsewhere in this chart (no new client or secret to set up). Defaults to `false` | `false` |

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

See the `dpn-rest-federator-gateway` repository's `demo/demo-runner-client` for a complete worked example, including the different result behaviour with both success and failure examples

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 | 