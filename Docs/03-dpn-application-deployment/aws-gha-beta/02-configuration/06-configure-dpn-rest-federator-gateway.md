# DPN REST Federator Gateway Configuration

This section describes how to configure and deploy the **DPN REST Federator Gateway**, provided by the `dpn-rest-federator-gateway` repository. It is a **REST/HTTPS-based alternative to the gRPC Federator Gateway**, for producers and consumers that need a synchronous, request/response API instead of a streamed Kafka-to-Kafka pipeline. It reuses the same Management Node, Identity Provider, and certificate infrastructure as the gRPC Federator Gateway, so both federation styles can be run side by side against a single DPN control plane.

> **Depends on Vault and the Certificate Manager.** Like the gRPC Federator Gateway, the REST Federator Gateway reads its mTLS keystore/truststore material directly from Vault at start-up — there is no shared file share. Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](03-configure-dpn-certificate-manager.md) first, and ensure the certificate's SANs cover this gateway's endpoint (e.g. `producer-rest01.<dpn>...`) in addition to the gRPC Federator's.

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
  - [Step3d: Configure AWS ServiceAccount (IRSA)](#step3d-configure-aws-serviceaccount-irsa)
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

> **`cloudProvider: aws`.** As with the gRPC Federator Gateway, every populated `values/aws/<environment>-<cluster>.yaml` file must set `cloudProvider: aws` — it switches the load-balancer annotations to NLB, the `SecretProviderClass` to AWS Secrets Manager, and enables the `ServiceAccount`/HPA templates covered in [Step3](#step3-environment-configuration).

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed**, with this gateway's endpoint included in the certificate's SANs | e.g. `producer-rest01.<dpn>...` alongside the gRPC Federator's `producer.<dpn>...`/`consumer.<dpn>...` — see [Configure DPN Certificate Manager, Step3a](03-configure-dpn-certificate-manager.md#step3a-set-up-helm-values) |
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the `dpn-vault-tls-bootstrap-cd.yml` workflow; trusts Vault's HTTPS endpoint |
| 4 | **Vault authentication configured — root token today**, AppRole once available | See [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-planned-not-yet-available) |
| 5 | **DPN Authentication Service (Keycloak) reachable** | Inbound JWTs are validated against its JWKS endpoint. See [Configure DPN Authentication Service](07-configure-dpn-authentication-service.md) |
| 6 | **EKS cluster** | Backs the `keyvault.enabled: true` gate that mounts the CSI-driver secret volume — on AWS this pulls from **AWS Secrets Manager**, not Azure Key Vault, despite the parameter's name (kept for template parity with the Azure path) |
| 7 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding, same as the gRPC Federator |
| 8 | **A backend to proxy to** | The gateway forwards authorised requests verbatim to `backend.baseUrl` — this is the organisation's own service, not provided by this chart |
| 9 | **Backend API key created** | In **AWS Secrets Manager** at `<secretsManager.secretPrefix>/BACKEND_API_KEY` (or via a Kubernetes `Secret` — see [Step2](#step2-configure-secrets)) |
| 10 | **Container image tag available** | Supplied to the CD workflow as `imageTag` |
| 11 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step3](#step3-environment-configuration) and [Step4](#step4-configure-deployment-parameters) |
| 12 | **IAM role for the `ServiceAccount` (IRSA) created** | The `dpn-rest-federator-cd.yml` workflow's **Provision AWS IRSA Role + Secrets** step creates/updates this role automatically on each run (idempotent) — see [Step4](#step4-configure-deployment-parameters) |
| 13 | **Vault AppRole configured for this component** | Run the **`DPN CD - REST Federator Role ID Creation`** workflow once per environment/cluster **before** the first deploy — see [Step3b](#step3b-configure-vault-authentication) |

> **This is ahead of the general Vault AppRole rollout.** [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-planned-not-yet-available) still describes AppRole as "planned, not yet available" for Certificate Manager and the gRPC Federator Gateway generally — that remains true for those components. The REST Federator Gateway has its **own**, already-automated AppRole workflow on AWS (prerequisite #13 above), independent of that general rollout.

---

## Step2: Configure Secrets

Only the backend API key (and, on AWS, the Vault AppRole secret-id) is provisioned outside the chart — the certificate material itself is sourced the same way as the gRPC Federator Gateway.

| Secret | Mechanism | Purpose |
|--------|-----------|---------|
| Backend API key | Kubernetes `Secret` (`restFederatorServer.backend.apiKeySecret`, default name `dpn-backend-api-key`), or synced via the CSI driver when `keyvault.enabled: true` — from Key Vault (`BACKEND-API-KEY`) on the Azure path, or **AWS Secrets Manager** (`<secretsManager.secretPrefix>/BACKEND_API_KEY`) on AWS | Authenticates the gateway to the internal backend (`X-Backend-Api-Key` header) |
| Vault credentials | **AppRole** on AWS — the `secret-id` is published to `<secretsManager.secretPrefix>/VAULT_APPROLE_SECRET_ID` by the `DPN CD - REST Federator Role ID Creation` workflow and synced into the same CSI secret as the backend API key; the `role-id` is fetched at deploy time and passed via `--set` (see [Step3b](#step3b-configure-vault-authentication) and [Step4](#step4-configure-deployment-parameters)). Root token via `certificate-manager-secrets` remains the mechanism on Azure | Reads certificate material and keystore/truststore passwords from Vault |
| Vault truststore password | On AWS, published to `<secretsManager.secretPrefix>/VAULT_TRUSTSTORE_PASSWORD` and fetched by the CD workflow at deploy time — **must match the real AWS Vault truststore password**; a placeholder starts the pod but fails to open the truststore at runtime | Lets the gateway's outbound HTTPS client to Vault validate Vault's certificate |

> **`certificate-manager-secrets` must already exist in the namespace at `helm install`/`upgrade` time, not just before the pod starts.** The rendered ConfigMap's `vault.truststore.password=` line is resolved via a Helm `lookup` against that Kubernetes `Secret`'s `VAULT_SSL_TRUST_STORE_PASSWORD` key **at chart-render time** — this is the one genuinely real secret value baked into the properties ConfigMap (every other value there is either blank or overridden by an environment variable at runtime). If Certificate Manager hasn't been deployed yet in this namespace, the lookup returns nothing, the rendered password is empty, and bean construction fails outright on newer Spring Boot/Java builds that enforce strict PKCS12 MAC verification. Deploy [Certificate Manager](03-configure-dpn-certificate-manager.md) first.

---

## Step3: Environment Configuration

Set the parameters below in your environment/cluster's values file.

```text
dpn-rest-federator-gateway/
  └── charts/
        └── dpn-rest-federator/
              ├── values.yaml                              <- Reference file; do not edit directly
              └── values/aws/<environment>-<cluster>.yaml <- Your environment + cluster overrides
```

> `dpn-redis`'s own `values.yaml` now honours the chart-wide `imagePullSecret` too (previously only the gateway's own pod did) — no action needed if you already set `imagePullSecret` for the release.

> **`dpn-redis`'s `test-dpn02` AWS values file is still a placeholder.** Unlike `dpn-rest-federator`, whose `values/aws/<environment>-<cluster>.yaml` is populated for all four `dev-dpn01`/`dev-dpn02`/`test-dpn01`/`test-dpn02` combinations, `dpn-redis/values/aws/test-dpn02.yaml` is still the unpopulated stub — populate it (e.g. from `dpn-redis/values/aws/test-dpn01.yaml`) before running **deploy-redis** for `test`/`dpn02` on AWS.

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

Unlike the gRPC Federator Gateway and Certificate Manager (still token-only — see [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-planned-not-yet-available)), the REST Federator Gateway has its **own** AppRole automation on AWS, via `dpn-rest-federator-gateway/scripts/vault/{rest-federator-policy.hcl,setup-approle.sh}` and the `DPN CD - REST Federator Role ID Creation` GitHub Actions workflow.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.vault.authMethod` | `approle` on AWS; `token` remains the only supported method on the Azure path | `approle` |
| `restFederatorServer.vault.appRole.roleId` | Non-sensitive role-id. The checked-in values file only needs a placeholder (`REPLACE_ME_VAULT_APPROLE_ROLE_ID`) — the CD workflow fetches the real value from AWS Secrets Manager at deploy time and overrides it via `--set` | `REPLACE_ME_VAULT_APPROLE_ROLE_ID` |
| `restFederatorServer.vault.appRole.mountPath` | Vault mount path the `approle` auth method is enabled at | `approle` |
| `restFederatorServer.vault.appRole.useSecretIdRef` | Source the AppRole `secret-id` from a Kubernetes Secret rather than a plaintext value | `true` |
| `restFederatorServer.vault.tlsBasePath` | KV v2 path holding the certificate material | `node-net/client` |
| `restFederatorServer.vault.tlsKeystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

> As with the gRPC Federator, `vault.tlsEnabled: true` is what removes the need for a shared file share — the gateway reads its TLS material straight from Vault. The TLS bundle is written to a short-lived, ephemeral-password file on disk at start-up (a JVM-managed temp location, not a mounted volume) rather than being applied purely in memory, and is rewritten on the same schedule as `vault.tls.reload.interval.seconds` (default 3600s) — hot-swapped with no pod restart. No configuration keys changed for this; it is the same `vault.tls*` settings above, just delivered through a more reliable mechanism.

#### One-time AppRole setup (AWS, before first deploy)

Run **Actions → DPN CD - REST Federator Role ID Creation → Run workflow** once per `<environment>-<cluster>` combination, **after** Vault is deployed and initialised ([Configure DPN Vault Service, Step 3B](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml)) and **before** the first `dpn-rest-federator-cd.yml` run. In one run it:

1. Runs `setup-approle.sh` inside the Vault pod (using the admin token from AWS Secrets Manager) to enable the `approle` auth method, write the `rest-federator-policy` (read-only access to `pki-client/{data,metadata}/node-net/client/*`), and create/update the `rest-federator` AppRole role (`token_ttl=1h`, `token_max_ttl=4h`, non-expiring `secret_id`).
2. Publishes the generated **`secret-id`** to `<secretsManager.secretPrefix>/VAULT_APPROLE_SECRET_ID` in AWS Secrets Manager.
3. Publishes the **`role-id`** to `<secretsManager.secretPrefix>/VAULT_APPROLE_ROLE_ID` (not sensitive, but stored so the deploy workflow can fetch it programmatically instead of a human copy/pasting it) and prints it in the run summary.

`workflow_dispatch` inputs: `environment`, `cluster`, `cloud`.

> **Prerequisites:** Vault deployed and unsealed; the admin/root token available in AWS Secrets Manager at `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN`; KV v2 enabled at `pki-client`.

Re-run this workflow to rotate the `secret-id`, then re-run `dpn-rest-federator-cd.yml` so the pod picks up the refreshed value.

### Step3c: Configure Autoscaling

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `hpa.enabled` | Horizontal Pod Autoscaler for the gateway — **on by default**, not opt-in | `true` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.scaleUp.cpuUtilization` / `.memoryUtilization` | Target average utilisation (%) that triggers scale-up | `80` / `80` |
| `hpa.scaleUpBehavior.stabilizationWindowSeconds` / `hpa.scaleDown.stabilizationWindowSeconds` | How long a scale-up/scale-down decision must hold before acting | `60` / `300` |

No per-environment values file currently overrides these — every environment inherits the chart defaults above. Unlike the AppRole/`ServiceAccount`/`SecretProviderClass` work in [Step3b](#step3b-configure-vault-authentication) and [Step3d](#step3d-configure-aws-serviceaccount-irsa), the HPA template and its defaults are identical on the Azure path — see [Configure DPN REST Federator Gateway (Azure), Step3c](../../azure-ado-beta/02-configuration/06-configure-dpn-rest-federator-gateway.md#step3c-configure-autoscaling).

### Step3d: Configure AWS ServiceAccount (IRSA)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `serviceAccount.create` | Render this chart's own `ServiceAccount` (separate from the gRPC Federator Gateway's) and attach it to the REST Federator Server pod | `true` |
| `serviceAccount.name` | Name of the `ServiceAccount` | `dpn-rest-federator` |
| `serviceAccount.irsaRoleArn` | ARN of the IAM role the `ServiceAccount` assumes, granting `secretsmanager:GetSecretValue`/`DescribeSecret` on `secretsManager.secretPrefix/*` | `arn:aws:iam::<account-id>:role/dpn-rest-federator-secrets-role` |
| `secretsManager.enabled` | Switch the gateway's `SecretProviderClass` to AWS Secrets Manager (mirrors `keyvault.enabled` on the Azure path) | `true` |
| `secretsManager.secretPrefix` | Path prefix for `BACKEND_API_KEY` and `VAULT_APPROLE_SECRET_ID` | `dpn/<environment>-<cluster>/rest-federator` |

The IAM role and its trust policy (scoped to `system:serviceaccount:<namespace>:<serviceAccount.name>`) do **not** need to be created manually — the `dpn-rest-federator-cd.yml` workflow's **Provision AWS IRSA Role + Secrets** step creates/updates the role idempotently on every run, and seeds `BACKEND_API_KEY`/`VAULT_TRUSTSTORE_PASSWORD` placeholders in Secrets Manager the first time (update them to real values before relying on the deployment).

---

## Step4: Configure Deployment Parameters

Deployed with the `dpn-rest-federator-cd.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`:

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        └── dpn-rest-federator-cd.yml
```

The workflow runs two jobs in order, each independently re-runnable: **deploy-redis** (the cache this chart owns) → **deploy-rest-federator** (the gateway, `needs: deploy-redis`). There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before either job runs.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | The target DPN cluster — `dpn01` or `dpn02` |
| `cloud` | Target cloud provider — `azure`, `aws`, or `gcp` (gcp not yet supported — config pending). Resolves `.github/config/<cloud>/<environment>-<cluster>.json` |
| `imageTag` | Tag of the REST Federator Server image to deploy |
| `imageRepository` | Image path after `ghcr.io/energy-dsi/` — leave blank to use the environment's configured registry (`IMAGE_REGISTRY` on AWS, `BASE_REGISTRY` on Azure) |

On AWS, the **deploy-rest-federator** job runs three additional steps ahead of the Helm lint/deploy, none of which exist on the Azure path:

1. **Provision AWS IRSA Role + Secrets** — creates/updates the `dpn-rest-federator-secrets-role` IAM role (idempotent) and seeds `BACKEND_API_KEY`/`VAULT_TRUSTSTORE_PASSWORD` placeholders in Secrets Manager if they don't already exist — see [Step3d](#step3d-configure-aws-serviceaccount-irsa).
2. **Fetch Vault Truststore Password (AWS)** — reads `VAULT_TRUSTSTORE_PASSWORD` from Secrets Manager and passes it as `restFederatorServer.vault.truststorePassword`.
3. **Fetch Vault AppRole Role ID (AWS)** — reads `VAULT_APPROLE_ROLE_ID` (published by the `DPN CD - REST Federator Role ID Creation` workflow — see [Step3b](#step3b-configure-vault-authentication)) and passes it as `restFederatorServer.vault.appRole.roleId`, so the checked-in values file placeholder never needs manual editing.

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
