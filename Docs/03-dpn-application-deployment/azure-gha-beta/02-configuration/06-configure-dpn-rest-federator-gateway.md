Release : 2.1.0 - Oct 2026

# DPN REST Federator Gateway Configuration

This section describes how to configure and deploy the **DPN REST Federator Gateway**, provided by the `dpn-rest-federator-gateway` repository. It is a **REST/HTTPS-based alternative to the gRPC Federator Gateway**, for producers and consumers that need a synchronous, request/response API instead of a streamed Kafka-to-Kafka pipeline. It reuses the same Management Node, Identity Provider, and certificate infrastructure as the gRPC Federator Gateway, so both federation styles can be run side by side against a single DPN control plane.

> **Depends on Vault and the Certificate Manager.** Like the gRPC Federator Gateway, the REST Federator Gateway reads its mTLS keystore/truststore material directly from Vault at start-up. Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](03-configure-dpn-certificate-manager.md) first, and ensure the certificate's SANs cover this gateway's endpoint (e.g. `producer-rest01.<dpn>...`) in addition to the gRPC Federator's.

> **Single environment, single cluster, multi-cloud:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`). The CD workflow also takes a **`cloud`** input (`azure`/`aws`/`gcp`) that selects which per-cloud config file to resolve — see [Step4](#step4-configure-deployment-parameters).

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
- [Step3: Environment Configuration](#step3-environment-configuration)
  - [Step3a: Configure the Gateway](#step3a-configure-the-gateway)
  - [Step3b: Configure Vault Authentication](#step3b-configure-vault-authentication)
  - [Step3c: Configure Autoscaling](#step3c-configure-autoscaling)
  - [Step3d: Configure Azure ServiceAccount (Workload Identity)](#step3d-configure-azure-serviceaccount-workload-identity)
  - [Step3e: Configure OTel Collector Security](#step3e-configure-otel-collector-security)
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

> **`cloudProvider: azure`.** As with the gRPC Federator Gateway, every populated `values/azure/<environment>-<cluster>.yaml` file must set `cloudProvider: azure` — it switches the load-balancer annotations to the Azure Standard Load Balancer, the `SecretProviderClass` to Azure Key Vault, and enables the `ServiceAccount`/HPA templates covered in [Step3](#step3-environment-configuration).

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed**, with this gateway's endpoint included in the certificate's SANs | e.g. `producer-rest01.<dpn>...` alongside the gRPC Federator's `producer.<dpn>...`/`consumer.<dpn>...` — see [Configure DPN Certificate Manager, Step3a](03-configure-dpn-certificate-manager.md#step3a-set-up-helm-values) |
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the `dpn-gha-vault-tls-bootstrap-cd.yml` workflow; trusts Vault's HTTPS endpoint |
| 4 | **Vault authentication configured — root token today**, AppRole once available | See [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication) |
| 5 | **DPN Authentication Service (Keycloak) reachable** | Inbound JWTs are validated against its JWKS endpoint. See [Configure DPN Authentication Service](07-configure-dpn-authentication-service.md) |
| 6 | **AKS cluster** | AKS cluster name |
| 7 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding, same as the gRPC Federator |
| 8 | **A backend to proxy to** | The gateway forwards authorised requests verbatim to `backend.baseUrl` — this is the organisation's own service, not provided by this chart |
| 9 | **Backend API key created** | In **Azure Key Vault** at `BACKEND-API-KEY` (or via a Kubernetes `Secret` — see [Step2](#step2-configure-secrets)) |
| 10 | **Container image tag available** | Supplied to the CD workflow as `imageTag` |
| 11 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step3](#step3-environment-configuration) and [Step4](#step4-configure-deployment-parameters) |
| 12 | **Managed identity for the `ServiceAccount` (Workload Identity) created** | Granted `get`/`list` on Key Vault secrets for `BACKEND-API-KEY` and the Vault truststore password — see [Step3d](#step3d-configure-azure-serviceaccount-workload-identity) |
| 13 | **Vault AppRole configured for this component (AWS only today)** | The `DPN CD - REST Federator Role ID Creation` workflow's AppRole path is exercised on AWS; on Azure, `token` remains the only supported Vault authentication method for this gateway — see [Step3b](#step3b-configure-vault-authentication) |

---

## Step2: Configure Secrets

Only the backend API key is provisioned outside the chart on Azure — the certificate material itself is sourced the same way as the gRPC Federator Gateway.

| Secret | Mechanism | Purpose |
|--------|-----------|---------|
| Backend API key | Kubernetes `Secret` (`restFederatorServer.backend.apiKeySecret`, default name `dpn-backend-api-key`), or synced via the CSI driver from **Azure Key Vault** (`BACKEND-API-KEY`) on Azure | Authenticates the gateway to the internal backend (`X-Backend-Api-Key` header) |
| Vault credentials | **Root token** via `certificate-manager-secrets` on Azure — the same `VAULT_TOKEN` the Certificate Manager and gRPC Federator Gateway already consume. AppRole (`secret-id` published to Key Vault, `role-id` copied into the values file) is the AWS-only mechanism today — see [Step3b](#step3b-configure-vault-authentication) | Reads certificate material and keystore/truststore passwords from Vault |
| Vault truststore password | On Azure, read from Key Vault (`VAULT-TRUSTSTORE-PASSWORD`) and passed to the chart at deploy time | Lets the gateway's outbound HTTPS client to Vault validate Vault's certificate |

---

## Step3: Environment Configuration

Set the parameters below in your environment/cluster's values file.

```text
dpn-rest-federator-gateway/
  └── charts/
        └── dpn-rest-federator/
          └── values/
              └── azure/
                └── <environment>-<cluster>.yaml <- Your environment + cluster overrides
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

Unlike on AWS, the REST Federator Gateway has **no AppRole automation of its own on Azure** today — `dpn-rest-federator-gateway/scripts/vault/{rest-federator-policy.hcl,setup-approle.sh}` and the `DPN CD - REST Federator Role ID Creation` GitHub Actions workflow currently exercise AppRole provisioning against the AWS Secrets Manager backend only; `token` remains the only supported method here, same as the gRPC Federator Gateway and Certificate Manager's root-token path.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.vault.authMethod` | `token` — the only supported method on the Azure path | `token` |
| `restFederatorServer.vault.appRole.roleId` | Non-sensitive role-id. Only relevant once AppRole is extended to Azure — leave at the checked-in placeholder (`REPLACE_ME_VAULT_APPROLE_ROLE_ID`) while `authMethod: token` | `REPLACE_ME_VAULT_APPROLE_ROLE_ID` |
| `restFederatorServer.vault.appRole.mountPath` | Vault mount path the `approle` auth method would be enabled at, once in use | `approle` |
| `restFederatorServer.vault.appRole.useSecretIdRef` | Source the AppRole `secret-id` from a Kubernetes Secret rather than a plaintext value, once in use | `true` |
| `restFederatorServer.vault.tlsBasePath` | KV v2 path holding the certificate material | `node-net/client` |
| `restFederatorServer.vault.tlsKeystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

> As with the gRPC Federator, `vault.tlsEnabled: true` is what removes the need for a shared file share — the gateway reads its TLS material straight from Vault. The TLS bundle is written to a short-lived, ephemeral-password file on disk at start-up (a JVM-managed temp location, not a mounted volume) rather than being applied purely in memory, and is rewritten on the same schedule as `vault.tls.reload.interval.seconds` (default 3600s) — hot-swapped with no pod restart. No configuration keys changed for this; it is the same `vault.tls*` settings above, just delivered through a more reliable mechanism.

#### Vault root token (Azure, today)

With `authMethod: token`, the gateway reads `VAULT_TOKEN` from the `certificate-manager-secrets` Kubernetes secret — the same root token already delivered there for the Certificate Manager and gRPC Federator Gateway (see [Configure DPN Certificate Manager, Step2](04-configure-dpn-certificate-manager.md#step2-configure-vault-authentication)). No separate per-component setup workflow run is required on Azure before the first deploy.

> **Prerequisites:** Vault deployed and unsealed; the admin/root token available in Azure Key Vault as `VAULT-TOKEN`; KV v2 enabled at `pki-client`.

### Step3c: Configure Autoscaling

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `hpa.enabled` | Horizontal Pod Autoscaler for the gateway — **on by default**, not opt-in | `true` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.scaleUp.cpuUtilization` / `.memoryUtilization` | Target average utilisation (%) that triggers scale-up | `80` / `80` |
| `hpa.scaleUpBehavior.stabilizationWindowSeconds` / `hpa.scaleDown.stabilizationWindowSeconds` | How long a scale-up/scale-down decision must hold before acting | `60` / `300` |

No per-environment values file currently overrides these — every environment inherits the chart defaults above. Unlike the AppRole/`ServiceAccount`/`SecretProviderClass` work in [Step3b](#step3b-configure-vault-authentication) and [Step3d](#step3d-configure-azure-serviceaccount-workload-identity), the HPA template and its defaults are identical on the AWS path — see [Configure DPN REST Federator Gateway (AWS), Step3c](../../aws-gha-beta/02-configuration/06-configure-dpn-rest-federator-gateway.md#step3c-configure-autoscaling).

### Step3d: Configure Azure ServiceAccount (Workload Identity)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `serviceAccount.create` | Render this chart's own `ServiceAccount` (separate from the gRPC Federator Gateway's) and attach it to the REST Federator Server pod | `true` |
| `serviceAccount.name` | Name of the `ServiceAccount` | `dpn-rest-federator` |
| `serviceAccount.azureClientId` | Client ID of the managed identity the `ServiceAccount` is federated to, granting Key Vault `get`/`list` on secrets | `<azure-client-id>` |
| `keyvault.enabled` | Switch the gateway's `SecretProviderClass` to Azure Key Vault (mirrors `secretsManager.enabled` on the AWS path) | `true` |
| `keyvault.name` | Key Vault holding `BACKEND-API-KEY` and `VAULT-TRUSTSTORE-PASSWORD` | `kv-dpn-azure-dev-uks-001` |

The managed identity and its federated credential (scoped to `system:serviceaccount:<namespace>:<serviceAccount.name>`) must be created manually before the first deploy on Azure — unlike the AWS path, this CD workflow does not create/update an IAM role automatically. Seed `BACKEND-API-KEY`/`VAULT-TRUSTSTORE-PASSWORD` in Key Vault yourself before relying on the deployment.

### Step3e: Configure OTel Collector Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.otel.tls.enabled` | Turns on HTTPS for OTLP export to the Collector. Defaults to `false`, so existing environments aren't affected unless someone opts in | `false` |
| `restFederatorServer.otel.oauth2.enabled` | Adds an `Authorization: Bearer` token to OTLP export, using the `dpn-service-client` Keycloak client already used elsewhere in this chart (no new client or secret to set up). Defaults to `false` | `false` |

> **Both default to `false` here, unlike the gRPC Federator Gateway's `otel.tls.enabled`/`otel.oauth.enabled`, which default to `true`** (see [Configure DPN Federator Gateway, Step3f](05-configure-dpn-federator-gateway.md#step3f-configure-otel-collector-security)). This inconsistency between the two gateways is real and intentional per the chart's current defaults, not a documentation error — confirm which behaviour your environment actually needs before relying on either default.

---

## Step4: Configure Deployment Parameters

Deployed with the `dpn-gha-rest-federator-cd.yml` GitHub Actions workflow in `dpn-rest-federator-gateway`:

```text
root/
└── .pipelines/
    └── github-actions-pipelines/
      └── workflows/
          └── dpn-gha-rest-federator-cd.yml
```

The workflow runs two jobs in order, each independently re-runnable: **deploy-redis** (the cache this chart owns) → **deploy-rest-federator** (the gateway, `needs: deploy-redis`). There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before either job runs.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | The target DPN cluster — `dpn01` or `dpn02` |
| `cloud` | Target cloud provider — `azure`, `aws`, or `gcp` (gcp not yet supported — config pending). Resolves `.pipelines/github-actions-pipelines/config/<cloud>/<environment>-<cluster>.json` |
| `imageTag` | Tag of the REST Federator Server image to deploy |
| `imageRepository` | Image path after `ghcr.io/energy-dsi/` — leave blank to use the environment's configured registry (`BASE_REGISTRY` on Azure, `IMAGE_REGISTRY` on AWS) |

On Azure, the **deploy-rest-federator** job runs one additional step ahead of the Helm lint/deploy, which does not exist on the AWS path:

1. **Fetch Vault Truststore Password (Azure)** — reads `VAULT-TRUSTSTORE-PASSWORD` from Key Vault and passes it as `restFederatorServer.vault.truststorePassword`.

Unlike AWS, Azure does not run an equivalent "Provision IRSA Role + Secrets" or "Fetch Vault AppRole Role ID" step — the managed identity and its Key Vault secrets are provisioned manually ahead of time (see [Step3d](#step3d-configure-azure-serviceaccount-workload-identity)), and `restFederatorServer.vault.authMethod` stays at `token`.

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

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
