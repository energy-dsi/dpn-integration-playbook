Release : 2.1.0 - Oct 2026

# DPN REST Federator Gateway Configuration

This section describes how to configure and deploy the **DPN REST Federator Gateway**, provided by the `dpn-rest-federator-gateway` repository. It is a **REST/HTTPS-based alternative to the gRPC Federator Gateway**, for producers and consumers that need a synchronous, request/response API instead of a streamed Kafka-to-Kafka pipeline. It reuses the same Management Node, Identity Provider, and certificate infrastructure as the gRPC Federator Gateway, so both federation styles can be run side by side against a single DPN control plane.

> **Depends on Vault and the Certificate Manager.** Like the gRPC Federator Gateway, the REST Federator Gateway reads its mTLS keystore/truststore material directly from Vault at start-up. Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) first, and ensure the certificate's SANs cover this gateway's endpoint (e.g. `producer-rest01.<dpn>...`) in addition to the gRPC Federator's.

> **Single environment, single cluster, multi-cloud:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`). The CD workflow also takes a **`cloud`** input (`azure`/`aws`/`gcp`, default `aws` — select `azure` explicitly) that selects which per-cloud config file (`.github/config/azure/<environment>-<cluster>.json`) and values file (`values/azure/<environment>-<cluster>.yaml`) to resolve — see [Step4](#step4-configure-deployment-parameters).

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
  - [Step3f: Configure Redis Security](#step3f-configure-redis-security)
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

> **Azure is the chart's native target.** The `dpn-rest-federator` chart templates are Azure-specific today — the internal load-balancer Service (rendered when `restFederatorServer.service.internalLoadBalancer: true`) carries the `azure-load-balancer-internal` annotation, and the `SecretProviderClass` (rendered when `keyvault.enabled: true`) uses `provider: azure`. The `values/azure/<environment>-<cluster>.yaml` files do not set a `cloudProvider` key, and the HPA template is rendered whenever `hpa.enabled` is true — see [Step3](#step3-environment-configuration).

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed**, with this gateway's endpoint included in the certificate's SANs | e.g. `producer-rest01.<dpn>...` alongside the gRPC Federator's `producer.<dpn>...`/`consumer.<dpn>...` — see [Configure DPN Certificate Manager, Step3a](04-configure-dpn-certificate-manager.md#step3a-set-up-helm-values) |
| 3 | **`cert-manager-truststore` and `tls-auth-secret` Kubernetes secrets present** | `cert-manager-truststore` is created by the `dpn-gha-vault-tls-bootstrap-cd.yaml` workflow (`dpn-federator-certificate-manager` repository) and trusts Vault's HTTPS endpoint; the gateway pod also reads `VAULT_TRUSTSTORE_PASSWORD` from `tls-auth-secret`/`TRUSTSTORE_PASSWORD` |
| 4 | **Vault authentication configured — AppRole** | The Azure values files set `restFederatorServer.vault.authMethod: approle` — see prerequisite #13 and [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication) |
| 5 | **DPN Authentication Service (Keycloak) reachable** | Inbound JWTs are validated against its JWKS endpoint. See [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md) |
| 6 | **AKS cluster** | `AKS_CLUSTER` / `RESOURCE_GROUP` in the config JSON |
| 7 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding, same as the gRPC Federator |
| 8 | **A backend to proxy to** | The gateway forwards authorised requests verbatim to `backend.baseUrl` — this is the organisation's own service, not provided by this chart |
| 9 | **Backend API key created** | In **Azure Key Vault** at `BACKEND-API-KEY` (or via a Kubernetes `Secret` — see [Step2](#step2-configure-secrets)) |
| 10 | **Container image tag available** | Supplied to the CD workflow as `imageTag` |
| 11 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step3](#step3-environment-configuration) and [Step4](#step4-configure-deployment-parameters) |
| 12 | **Managed identity for Key Vault access (only if `keyvault.enabled: true`)** | User-assigned managed identity (`keyvault.clientID`) with `get`/`list` on the Key Vault secrets listed in `keyvault.objects` (default `BACKEND-API-KEY`) — see [Step3d](#step3d-configure-azure-serviceaccount-workload-identity) |
| 13 | **Vault AppRole configured for this component** | Run the **`DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)`** workflow (`dpn-gha-rest-federator-role-id-creation.yaml`) with `cloud: azure` once per environment/cluster **before** the first deploy — despite its name it supports Azure too. See [Step3b](#step3b-configure-vault-authentication) |

---

## Step2: Configure Secrets

Only the backend API key (and the Vault AppRole `secret-id`) is provisioned outside the chart on Azure — the certificate material itself is sourced the same way as the gRPC Federator Gateway.

| Secret | Mechanism | Purpose |
|--------|-----------|---------|
| Backend API key | Kubernetes `Secret` (`restFederatorServer.backend.apiKeySecret`, `dpn-backend-api-key`/`apiKey` in the Azure values files) created out of band, or synced via the CSI driver from **Azure Key Vault** (`BACKEND-API-KEY`) when `keyvault.enabled: true` (the Azure values files ship with `keyvault.enabled: false`) | Authenticates the gateway to the internal backend (`X-Backend-Api-Key` header) |
| Vault credentials | **AppRole** — the `DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)` workflow publishes the `secret-id` to Key Vault as `VAULT-APPROLE-SECRET-ID-REST-FEDERATOR` and prints the `role-id`, which is copied into the values file. The pod reads the `secret-id` from the Kubernetes Secret named by `restFederatorServer.vault.appRole.secretIdSecretName`/`secretIdSecretKey` (chart default `certificate-manager-secrets`/`VAULT_APPROLE_SECRET_ID`, not overridden in the Azure values files) — see [Step3b](#step3b-configure-vault-authentication) | Reads certificate material and keystore/truststore passwords from Vault |
| Vault truststore password | Read by the CD workflow from Key Vault (`TRUSTSTORE-PASSWORD`, the actively-rotated object written by the Certificate Manager's TLS workflow) and passed to the chart via `--set restFederatorServer.vault.truststorePassword` | Lets the gateway's outbound HTTPS client to Vault validate Vault's certificate |

---

## Step3: Environment Configuration

Set the parameters below in your environment/cluster's values file.

```text
dpn-rest-federator-gateway/
├── charts/
│     ├── dpn-rest-federator/
│     │     ├── values.yaml                                <- Reference file; do not edit directly
│     │     └── values/azure/<environment>-<cluster>.yaml <- Your environment + cluster overrides
│     └── dpn-redis/
│           ├── values.yaml
│           └── values/azure/<environment>-<cluster>.yaml <- Redis cache overrides (deploy-redis job)
└── scripts/
      └── vault/
            ├── rest-federator-policy.hcl
            └── setup-approle.sh                          <- Used by the Role ID Creation workflow
```

> Both charts ship populated `values/azure/<environment>-<cluster>.yaml` files for `dev-dpn01`/`dev-dpn02`/`test-dpn01`/`test-dpn02`. The chart directories also still contain legacy flat `values-<environment>-<cluster>.yaml` files at the chart root; the GitHub Actions workflows use only the `values/<cloud>/...` files.

### Step3a: Configure the Gateway

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.tls.enabled` | Whether this listener terminates HTTPS itself | `true` |
| `restFederatorServer.mtls.enabled` | Require inbound connections to present a client certificate. Off by default so the gateway can sit behind infrastructure that cannot present one (e.g. health probes) | `false` |
| `restFederatorServer.backend.baseUrl` | Internal backend the gateway proxies authorised requests to | `http://<backend-service>:8080` |
| `restFederatorServer.producerId` | This producer's identifier, as registered with the Management Node | `<producer-id>` |
| `restFederatorServer.managementNode.baseUrl` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` |
| `restFederatorServer.idp.clientId` / `jwksUrl` / `tokenUrl` | Identity Provider client ID and endpoints (as the gRPC Federator) | `https://auth-mtls.dsm01.dsiXXX.neso.energy/...` |
| `restFederatorServer.redis.host` / `port` | Points at the Service of the separate `dpn-redis` release (its `redisCache.name`) | `dpn-rest-federator-redis-1.<namespace>.svc.cluster.local` / `6379` |

### Step3b: Configure Vault Authentication

The REST Federator Gateway has its **own** AppRole automation, via `scripts/vault/{rest-federator-policy.hcl,setup-approle.sh}` and the `DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)` GitHub Actions workflow (`.github/workflows/dpn-gha-rest-federator-role-id-creation.yaml`), both in the `dpn-rest-federator-gateway` repository. Despite the "AWS" in its display name, the workflow supports `cloud: azure` (Key Vault backend). All four Azure values files set `authMethod: approle`.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.vault.authMethod` | `token` or `approle`; the Azure values files use `approle`. With `token`, the pod reads `VAULT_TOKEN` from `certificate-manager-secrets` | `approle` |
| `restFederatorServer.vault.appRole.roleId` | Non-sensitive role-id. On Azure the CD workflow does **not** fetch it — copy the value printed in the Role ID Creation workflow's run summary into the values file | `<role-id-uuid>` |
| `restFederatorServer.vault.appRole.mountPath` | Vault mount path the `approle` auth method is enabled at | `approle` |
| `restFederatorServer.vault.appRole.useSecretIdRef` | Source the AppRole `secret-id` from a Kubernetes Secret rather than a plaintext value | `true` |
| `restFederatorServer.vault.appRole.secretIdSecretName` / `secretIdSecretKey` | Kubernetes Secret and key holding the `secret-id`. Not overridden in the Azure values files, so the chart default applies | `certificate-manager-secrets` / `VAULT_APPROLE_SECRET_ID` |
| `restFederatorServer.vault.tlsBasePath` | KV v2 path holding the certificate material | `node-net/client` |
| `restFederatorServer.vault.tlsKeystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

> As with the gRPC Federator, `vault.tlsEnabled: true` is what removes the need for a shared file share — the gateway reads its TLS material straight from Vault. The TLS bundle is written to a short-lived, ephemeral-password file on disk at start-up (a JVM-managed temp location, not a mounted volume) rather than being applied purely in memory, and is rewritten on the same schedule as `vault.tls.reload.interval.seconds` (default 3600s) — hot-swapped with no pod restart. No configuration keys changed for this; it is the same `vault.tls*` settings above, just delivered through a more reliable mechanism.

#### One-time AppRole setup (Azure, before first deploy)

Run **Actions → DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup) → Run workflow** (`.github/workflows/dpn-gha-rest-federator-role-id-creation.yaml`) with `cloud: azure`, once per `<environment>-<cluster>` combination, **after** Vault is deployed and initialised and **before** the first `dpn-gha-rest-federator-cd.yaml` run. In one run it:

1. Resolves the Vault pod (`app=dpn-vault-https`) in the config JSON's `NAMESPACE`, copies `setup-approle.sh` and `rest-federator-policy.hcl` into it, and runs the script there (using the admin token read from Key Vault `VAULT-TOKEN`) to enable the `approle` auth method, write the `rest-federator-policy`, and create/update the `rest-federator` AppRole role (`token_ttl=1h`, `token_max_ttl=4h`, non-expiring `secret_id`).
2. Publishes the generated **`secret-id`** to Key Vault (`KEY_VAULT_NAME`) as `VAULT-APPROLE-SECRET-ID-REST-FEDERATOR`, stamped with a +355-day expiry to satisfy the Key Vault maximum-validity governance policy.
3. Prints the **`role-id`** in the run summary — set it as `restFederatorServer.vault.appRole.roleId` in `charts/dpn-rest-federator/values/azure/<environment>-<cluster>.yaml`, then redeploy.

`workflow_dispatch` inputs: `environment` (`dev`/`test`, default `test`), `cluster` (`dpn01`/`dpn02`, default `dpn01`), `cloud` (default `aws` — select `azure`). The temporary script/policy files are removed from the Vault pod at the end of every run. Re-run the workflow before the Key Vault copy expires to rotate the `secret-id`, then redeploy.

> **Prerequisites:** Vault deployed and unsealed; the admin/root token available in Azure Key Vault as `VAULT-TOKEN`; KV v2 enabled at `pki-client`.

> **Open point:** the workflow writes the `secret-id` to Key Vault, but the chart reads it from the Kubernetes Secret named by `secretIdSecretName` (default `certificate-manager-secrets`/`VAULT_APPROLE_SECRET_ID`). Nothing in this repository syncs `VAULT-APPROLE-SECRET-ID-REST-FEDERATOR` into that Secret — confirm how the value reaches the pod in your environment.

### Step3c: Configure Autoscaling

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `hpa.enabled` | Horizontal Pod Autoscaler for the gateway — **on by default**, not opt-in | `true` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.scaleUp.cpuUtilization` / `.memoryUtilization` | Target average utilisation (%) that triggers scale-up | `80` / `80` |
| `hpa.scaleUpBehavior.stabilizationWindowSeconds` / `hpa.scaleDown.stabilizationWindowSeconds` | How long a scale-up/scale-down decision must hold before acting | `60` / `300` |

No per-environment values file currently overrides these — every environment inherits the chart defaults above. Unlike the Vault/Key Vault wiring in [Step3b](#step3b-configure-vault-authentication) and [Step3d](#step3d-configure-azure-serviceaccount-workload-identity), the HPA template and its defaults are identical on the AWS path — see [Configure DPN REST Federator Gateway (AWS), Step3c](../../aws-gha-beta/02-configuration/06-configure-dpn-rest-federator-gateway.md#step3c-configure-autoscaling).

### Step3d: Configure Azure ServiceAccount (Workload Identity)

> **No `ServiceAccount`/Workload Identity in the chart today.** The `dpn-rest-federator` chart has no `ServiceAccount` template and the Azure values files set no `serviceAccount.*` keys. Key Vault access goes through the secrets-store CSI driver's `SecretProviderClass`, which uses a **user-assigned managed identity** (`useVMManagedIdentity: "true"`, `userAssignedIdentityID: keyvault.clientID`); `keyvault.clientID` is also rendered as the pod's `AZURE_CLIENT_ID` environment variable.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.service.loadBalancerIP` | Static private IP of the REST Federator Server internal LoadBalancer. The `dpn-demo-runner-server` chart has the same key under `service.loadBalancerIP`. Use an unused address in the AKS subnet, one per service. Set in `charts/dpn-rest-federator/values/azure/<environment>-<cluster>.yaml` | `<private-ip-in-aks-subnet>` |
| `keyvault.enabled` | Render the Azure Key Vault `SecretProviderClass` and mount its CSI volume. **`false` in all Azure values files today** | `false` |
| `keyvault.clientID` | Client ID of the user-assigned managed identity with Key Vault `get`/`list` on the secrets in `keyvault.objects` | `<managed-identity-client-id>` |
| `keyvault.name` / `keyvault.tenantId` | Key Vault the CSI driver reads from, and its tenant | `<key-vault-name>` / `<tenant-id>` |
| `keyvault.secretName` / `keyvault.mountPath` | Kubernetes Secret the CSI driver syncs into, and the volume mount path | `dpn-rest-federator-server-secrets` / `/mnt/secrets` |
| `keyvault.objects` | Key Vault secrets to sync (`objectName` → Secret `key`). Chart default: `BACKEND-API-KEY` → `BACKEND_API_KEY` and `REDIS-IDP-CLIENT-SECRET` → `REDIS_IDP_CLIENT_SECRET` | `BACKEND-API-KEY` |

To read the backend API key from the synced Secret, point `restFederatorServer.backend.apiKeySecret.name`/`key` at `keyvault.secretName`/`BACKEND_API_KEY`. The managed identity and its Key Vault access must be set up manually before enabling this — unlike the AWS path, this CD workflow does not create any identity or seed Key Vault secrets.

> **Note:** the `keyvault.name` in the Azure values files (e.g. `kv-dpn-dev-uks-01`) differs from the config JSON's `KEY_VAULT_NAME` (e.g. `kv-dpn-azure-dev-uks-001`) that the workflows use for `TRUSTSTORE-PASSWORD`, `VAULT-TOKEN` and the AppRole `secret-id`. Confirm which Key Vault applies before enabling the CSI sync.

### Step3e: Configure OTel Collector Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.otel.tls.enabled` | HTTPS for OTLP export to the Collector. Reuses the mounted vault truststore, so no new secret is needed. Default `false` | `true` |
| `restFederatorServer.otel.oauth2.enabled` | Send an `Authorization: Bearer` token with OTLP export, using the `redisIdp` Keycloak client (`dpn-service-client`). Default `false` | `true` |

Enable both together where the Collector enforces HTTPS and Bearer auth.

### Step3f: Configure Redis Security

`dpn-redis` is TLS-only (plaintext disabled) and uses the shared `dpn-tls` certificate. There is no Redis username/password; access is gated by a Keycloak session.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.redis.host` / `port` | Service of the `dpn-redis` release | `dpn-rest-federator-redis-1.<namespace>.svc.cluster.local` / `6379` |
| `restFederatorServer.redis.tlsEnabled` | Always `true`. `dpn-redis` is TLS-only | `true` |
| `restFederatorServer.keycloakAuthEnabled` | Gate Redis access with a Keycloak session. `true` in every real environment | `true` |
| `restFederatorServer.redisIdp.tokenUrl` | Keycloak token endpoint. Set per environment | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| `restFederatorServer.redisIdp.clientId` | Keycloak client used for Redis and OTLP authentication | `dpn-service-client` |
| `restFederatorServer.redisIdp.clientSecretEnabled` | Read the client secret from `dpn-keycloak-secrets` (`KC_SERVICE_CLIENT_SECRET`) | `true` |

> The `dpn-keycloak-secrets` Secret must exist in the namespace before deploy.

---

## Step4: Configure Deployment Parameters

Deployed with the **`DPN CD - REST Federator Gateway`** GitHub Actions workflow (`dpn-gha-rest-federator-cd.yaml`) in the `dpn-rest-federator-gateway` repository:

```text
dpn-rest-federator-gateway/
└── .github/
    ├── workflows/
    │   ├── dpn-gha-rest-federator-cd.yaml
    │   ├── dpn-gha-rest-federator-role-id-creation.yaml
    │   ├── dpn-gha-demo-runner-cd.yaml
    │   ├── dpn-gha-rest-federator-rollback.yaml    <- DPN Rollback - REST Federator Gateway
    │   └── dpn-gha-rest-federator-uninstall.yaml   <- DPN Uninstall - REST Federator Gateway
    ├── actions/
    │   └── cloud-login/action.yml      <- Shared cloud login (Azure OIDC) + AKS kubeconfig step
    └── config/
        └── azure/<environment>-<cluster>.json
```

The workflow's environment variables point at the charts in the same repository:

| Variable | Value |
|----------|-------|
| `PARAMETERS_FILE` | `.github/config/<cloud>/<environment>-<cluster>.json` |
| `HELM_DIR` / `RELEASE_NAME` | `charts/dpn-rest-federator` / `dpn-rest-federator` |
| `REDIS_HELM_DIR` / `REDIS_RELEASE_NAME` | `charts/dpn-redis` / `dpn-redis` |
| `VALUES_FILE` | `values/<cloud>/<environment>-<cluster>.yaml` (relative to each chart directory) |

Every key in the config JSON (`AZURE_SUBSCRIPTION_ID`, `ARM_SUBSCRIPTION_ID`, `RESOURCE_GROUP`, `AKS_CLUSTER`, `KEY_VAULT_NAME`, `NAMESPACE`, and so on) is exported as an environment variable. The shared `cloud-login` action logs in to Azure with OIDC using the `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` repository or Environment secrets, selects `ARM_SUBSCRIPTION_ID`, and fetches the AKS kubeconfig from `RESOURCE_GROUP`/`AKS_CLUSTER`. Both releases are installed into `NAMESPACE`.

One-time repository setup (from the repository's `.github/workflows/README.md`): a GitHub Environment named `<environment>-<cluster>` for each target, the `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` secrets (Azure OIDC federated identity), and a self-hosted runner registered with the `[self-hosted, vmss]` labels the jobs target.

The workflow runs two jobs in order, each independently re-runnable: **deploy-redis** (the cache this chart owns) → **deploy-rest-federator** (the gateway, `needs: deploy-redis`). There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before either job runs.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | The target DPN cluster — `dpn01` or `dpn02` (default `dpn01`) |
| `cloud` | Target cloud provider — `azure`, `aws`, or `gcp` (default `aws`, so select `azure`; gcp not yet supported — config pending). Resolves `.github/config/<cloud>/<environment>-<cluster>.json` |
| `imageTag` | Tag of the REST Federator Server image to deploy (required) |
| `imageRepository` | Optional. Image path after `ghcr.io/energy-dsi/` (e.g. `dpn-rest-federator-server`) — leave blank to use `ghcr.io/energy-dsi/dpn-rest-federator-server` on Azure (`<IMAGE_REGISTRY>/dpn-rest-federator-server` on AWS) |

On Azure, the **deploy-rest-federator** job runs one additional step ahead of the Helm lint/deploy:

1. **Fetch Vault Truststore Password** — reads `TRUSTSTORE-PASSWORD` from Key Vault (`KEY_VAULT_NAME`) and passes it as `restFederatorServer.vault.truststorePassword`.

Unlike AWS, Azure does not run an equivalent "Provision AWS IRSA Role + Secrets" or "Fetch Vault AppRole Role ID" step — any Key Vault identity and secrets are provisioned manually ahead of time (see [Step3d](#step3d-configure-azure-serviceaccount-workload-identity)), and the AppRole `role-id` comes from the checked-in values file (see [Step3b](#step3b-configure-vault-authentication)).

The **deploy-redis** job runs `helm lint` and a `--dry-run` before `helm upgrade --install dpn-redis`, then waits for the Redis Deployment (named by `redisCache.name`) to roll out. The **deploy-rest-federator** job likewise runs **Helm Lint + Dry Run** before **Helm Deploy**, overriding `restFederatorServer.image.repository`/`image.tag` from the inputs.

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

See the `dpn-rest-federator-gateway` repository's `demo/demo-runner-client` for a complete worked example, including the expected `403` behaviour when a path falls outside a product's allowed-path configuration. The demo runner can also be deployed to the cluster from the same repository: its charts are `charts/dpn-demo-runner-server` and `charts/dpn-demo-runner-client` (each with `values/azure/<environment>-<cluster>.yaml`), deployed by the **`DPN CD - Demo Runner`** workflow (`.github/workflows/dpn-gha-demo-runner-cd.yaml`) as the `dpn-demo-runner-server` and `dpn-demo-runner-client` releases. Its `deployServer`/`runClient` inputs select which job runs; the client runs as a one-shot Kubernetes Job (named with the run ID) driven by the `mpan`, `postcode`, `assetId` and `fspId` inputs. On Azure both read the Vault truststore password from Key Vault `TRUSTSTORE-PASSWORD`.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
