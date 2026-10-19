Release : 2.1.0 - Oct 2026

# DPN REST Federator Gateway Configuration

This section describes how to configure and deploy the **DPN REST Federator Gateway**, provided by the `dpn-rest-federator-gateway` repository — its Helm charts (`charts/dpn-rest-federator`, `charts/dpn-redis`), Vault AppRole scripts (`scripts/vault/`) and the GitHub Actions workflows that deploy them (`.github/workflows/`) all live in that one repository. It is a **REST/HTTPS-based alternative to the gRPC Federator Gateway**, for producers and consumers that need a synchronous, request/response API instead of a streamed Kafka-to-Kafka pipeline. It reuses the same Management Node, Identity Provider, and certificate infrastructure as the gRPC Federator Gateway, so both federation styles can be run side by side against a single DPN control plane.

> **Depends on Vault and the Certificate Manager.** Like the gRPC Federator Gateway, the REST Federator Gateway reads its mTLS keystore/truststore material directly from Vault at start-up — there is no shared file share. Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) first, and ensure the certificate's SANs cover this gateway's endpoint (e.g. `producer-rest01.<dpn>...`) in addition to the gRPC Federator's.

> **Single environment, single cluster, multi-cloud:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`). The CD workflow also takes a **`cloud`** input (`azure`/`aws`/`gcp`, default `aws`) that selects which per-cloud config file (`.github/config/aws/<environment>-<cluster>.json`) and values file (`values/aws/<environment>-<cluster>.yaml`) to resolve — see [Step4](#step4-configure-deployment-parameters).

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
  - [Step3e: Configure Redis Security](#step3e-configure-redis-security)
  - [Step3f: Configure OTel Collector Security](#step3f-configure-otel-collector-security)
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

> **`cloudProvider: aws`.** As with the gRPC Federator Gateway, every populated `values/aws/<environment>-<cluster>.yaml` file sets `cloudProvider: aws`, alongside the AWS-specific `secretsManager.*` and `serviceAccount.*` blocks covered in [Step3](#step3-environment-configuration).
>
> **Chart template gap (current `develop`):** the `dpn-rest-federator` chart's templates do not yet read `cloudProvider`, `secretsManager.*` or `serviceAccount.*` — there is no `ServiceAccount` template, the `SecretProviderClass` template is hard-coded to `provider: azure`, and the internal load-balancer Service carries only the Azure `azure-load-balancer-internal` annotation. The AWS values are in place, but confirm the chart templates support them before relying on IRSA, Secrets Manager sync, or an NLB on EKS.

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed**, with this gateway's endpoint included in the certificate's SANs | e.g. `producer-rest01.<dpn>...` alongside the gRPC Federator's `producer.<dpn>...`/`consumer.<dpn>...` — see [Configure DPN Certificate Manager, Step3a](04-configure-dpn-certificate-manager.md#step3a-set-up-helm-values) |
| 3 | **`cert-manager-truststore` and `tls-auth-secret` Kubernetes secrets present** | `cert-manager-truststore` is created by the `dpn-gha-vault-tls-bootstrap-cd.yaml` workflow (`dpn-federator-certificate-manager` repository) and trusts Vault's HTTPS endpoint; the gateway pod also reads `VAULT_TRUSTSTORE_PASSWORD` from `tls-auth-secret`/`TRUSTSTORE_PASSWORD` |
| 4 | **Vault authentication configured — AppRole on AWS** | The AWS values files set `restFederatorServer.vault.authMethod: approle` — see prerequisite #13 and [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-dpn-gha-certificate-manager-role-id-creationyaml) |
| 5 | **DPN Authentication Service (Keycloak) reachable** | Inbound JWTs are validated against its JWKS endpoint. See [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md) |
| 6 | **EKS cluster** | Backs the `keyvault.enabled: true` gate that mounts the CSI-driver secret volume — on AWS this pulls from **AWS Secrets Manager**, despite the parameter's name |
| 7 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding, same as the gRPC Federator |
| 8 | **A backend to proxy to** | The gateway forwards authorised requests verbatim to `backend.baseUrl` — this is the organisation's own service, not provided by this chart |
| 9 | **Backend API key created** | In **AWS Secrets Manager** at `<secretsManager.secretPrefix>/BACKEND_API_KEY` (or via a Kubernetes `Secret` — see [Step2](#step2-configure-secrets)) |
| 10 | **Container image tag available** | Supplied to the CD workflow as `imageTag` |
| 11 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step3](#step3-environment-configuration) and [Step4](#step4-configure-deployment-parameters) |
| 12 | **IAM role for the `ServiceAccount` (IRSA) created** | The `dpn-gha-rest-federator-cd.yaml` workflow's **Provision AWS IRSA Role + Secrets** step creates/updates the `dpn-rest-federator-secrets-role` role automatically on each run (idempotent). Its ARN must still be set as `serviceAccount.irsaRoleArn` in the values file — see [Step3d](#step3d-configure-aws-serviceaccount-irsa) and [Step4](#step4-configure-deployment-parameters) |
| 13 | **Vault AppRole configured for this component** | Run the **`DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)`** workflow (`dpn-gha-rest-federator-role-id-creation.yaml`) once per environment/cluster **before** the first deploy — see [Step3b](#step3b-configure-vault-authentication) |

> **This component has its own AppRole workflow.** [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-dpn-gha-certificate-manager-role-id-creationyaml) covers AppRole setup for the Certificate Manager. The REST Federator Gateway has its **own**, dedicated AppRole workflow in the `dpn-rest-federator-gateway` repository (prerequisite #13 above), which also publishes the `role_id` so the CD workflow can fetch it automatically.

---

## Step2: Configure Secrets

Only the backend API key (and, on AWS, the Vault AppRole secret-id) is provisioned outside the chart — the certificate material itself is sourced the same way as the gRPC Federator Gateway.

| Secret | Mechanism | Purpose |
|--------|-----------|---------|
| Backend API key | **AWS Secrets Manager** (`<secretsManager.secretPrefix>/BACKEND_API_KEY`), synced by the CSI `SecretProviderClass` into the Kubernetes `Secret` named by `restFederatorServer.backend.apiKeySecret` (chart default `dpn-backend-api-key`/`apiKey`; the AWS values files set it to `dpn-rest-federator-server-secrets`/`BACKEND_API_KEY`, matching `keyvault.secretName`) | Authenticates the gateway to the internal backend (`X-Backend-Api-Key` header) |
| Vault credentials | **AppRole** on AWS — the `secret-id` is published to `<secretsManager.secretPrefix>/VAULT_APPROLE_SECRET_ID` by the `DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)` workflow and synced into the same CSI secret as the backend API key; the `role-id` is fetched at deploy time and passed via `--set` (see [Step3b](#step3b-configure-vault-authentication) and [Step4](#step4-configure-deployment-parameters))| Reads certificate material and keystore/truststore passwords from Vault |
| Vault truststore password | On AWS, published to `<secretsManager.secretPrefix>/VAULT_TRUSTSTORE_PASSWORD` and fetched by the CD workflow at deploy time — **must match the real AWS Vault truststore password**; a placeholder starts the pod but fails to open the truststore at runtime | Lets the gateway's outbound HTTPS client to Vault validate Vault's certificate |

> **The Vault truststore password is baked into the rendered ConfigMap at `helm install`/`upgrade` time, not read live at pod start-up.** The ConfigMap's `vault.truststore.password=` line is rendered from `restFederatorServer.vault.truststorePassword`, which the CD workflow sets via `--set` from the `VAULT_TRUSTSTORE_PASSWORD` Secrets Manager entry fetched above (the checked-in values files leave it `""`). If that entry still holds the `REPLACE_ME` placeholder, or is otherwise wrong, the rendered password will not open the truststore and bean construction fails on newer Spring Boot/Java builds that enforce strict PKCS12 MAC verification. The pod additionally reads `VAULT_TOKEN` (optional, token mode only) from `certificate-manager-secrets` and `VAULT_TRUSTSTORE_PASSWORD` from `tls-auth-secret`, so deploy [Certificate Manager](04-configure-dpn-certificate-manager.md) first.

---

## Step3: Environment Configuration

Set the parameters below in your environment/cluster's values file.

```text
dpn-rest-federator-gateway/
├── charts/
│     ├── dpn-rest-federator/
│     │     ├── values.yaml                              <- Reference file; do not edit directly
│     │     └── values/aws/<environment>-<cluster>.yaml <- Your environment + cluster overrides
│     └── dpn-redis/
│           ├── values.yaml
│           └── values/aws/<environment>-<cluster>.yaml <- Redis cache overrides (deploy-redis job)
└── scripts/
      └── vault/
            ├── rest-federator-policy.hcl
            └── setup-approle.sh                        <- Used by the Role ID Creation workflow
```

> `dpn-redis`'s own `values.yaml` now honours the chart-wide `imagePullSecret` too (previously only the gateway's own pod did) — no action needed if you already set `imagePullSecret` for the release.

> Both `dpn-rest-federator` and `dpn-redis` ship populated `values/aws/<environment>-<cluster>.yaml` files for all four `dev-dpn01`/`dev-dpn02`/`test-dpn01`/`test-dpn02` combinations. Review them for your environment before the first run — the `dpn-rest-federator` files carry a header listing the values that must be confirmed (Secrets Manager placeholders, IRSA role ARN, AppRole role-id, IDP URLs).
>
> The `dpn-rest-federator` and `dpn-redis` chart directories also still contain legacy flat `values-<environment>-<cluster>.yaml` files at the chart root; the GitHub Actions workflows use only the `values/<cloud>/<environment>-<cluster>.yaml` files.

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

Unlike the gRPC Federator Gateway (see [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-dpn-gha-certificate-manager-role-id-creationyaml)), the REST Federator Gateway has its **own** AppRole automation, via `scripts/vault/{rest-federator-policy.hcl,setup-approle.sh}` and the `DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)` GitHub Actions workflow (`.github/workflows/dpn-gha-rest-federator-role-id-creation.yaml`), both in the `dpn-rest-federator-gateway` repository.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.vault.authMethod` | `token` or `approle`; the AWS values files use `approle` | `approle` |
| `restFederatorServer.vault.appRole.roleId` | Non-sensitive role-id. The value checked into the AWS values file is only a fallback — the CD workflow fetches the real value from AWS Secrets Manager (`<secretsManager.secretPrefix>/VAULT_APPROLE_ROLE_ID`) at deploy time and overrides it via `--set` | `<role-id-uuid>` |
| `restFederatorServer.vault.appRole.mountPath` | Vault mount path the `approle` auth method is enabled at | `approle` |
| `restFederatorServer.vault.appRole.useSecretIdRef` | Source the AppRole `secret-id` from a Kubernetes Secret rather than a plaintext value | `true` |
| `restFederatorServer.vault.appRole.secretIdSecretName` / `secretIdSecretKey` | Kubernetes Secret and key holding the `secret-id`. The chart default (`certificate-manager-secrets`) is overridden in the AWS values files to this chart's own CSI-synced Secret | `dpn-rest-federator-server-secrets` / `VAULT_APPROLE_SECRET_ID` |
| `restFederatorServer.vault.tlsBasePath` | KV v2 path holding the certificate material | `node-net/client` |
| `restFederatorServer.vault.tlsKeystoreAlias` | Alias used for the in-memory keystore entry | `federator` |

> As with the gRPC Federator, `vault.tlsEnabled: true` is what removes the need for a shared file share — the gateway reads its TLS material straight from Vault. The TLS bundle is written to a short-lived, ephemeral-password file on disk at start-up (a JVM-managed temp location, not a mounted volume) rather than being applied purely in memory, and is rewritten on the same schedule as `vault.tls.reload.interval.seconds` (default 3600s) — hot-swapped with no pod restart. No configuration keys changed for this; it is the same `vault.tls*` settings above, just delivered through a more reliable mechanism.

#### One-time AppRole setup (AWS, before first deploy)

Run **Actions → DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup) → Run workflow** (`.github/workflows/dpn-gha-rest-federator-role-id-creation.yaml`) once per `<environment>-<cluster>` combination, **after** Vault is deployed and initialised ([Configure DPN Vault Service, Step 3B](01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-gha-vault-https-cdyaml)) and **before** the first `dpn-gha-rest-federator-cd.yaml` run. In one run it:

1. Resolves the Vault pod (`app=dpn-vault-https`) in the config JSON's `NAMESPACE`, copies `setup-approle.sh` and `rest-federator-policy.hcl` into it, and runs the script there (using the admin token from AWS Secrets Manager) to enable the `approle` auth method, write the `rest-federator-policy` (read-only access to `pki-client/{data,metadata}/node-net/client/*`), and create/update the `rest-federator` AppRole role (`token_ttl=1h`, `token_max_ttl=4h`, non-expiring `secret_id`).
2. Publishes the generated **`secret-id`** to `dpn/<environment>-<cluster>/rest-federator/VAULT_APPROLE_SECRET_ID` in AWS Secrets Manager. This path is fixed in the workflow, so `secretsManager.secretPrefix` must stay `dpn/<environment>-<cluster>/rest-federator`.
3. Publishes the **`role-id`** to `dpn/<environment>-<cluster>/rest-federator/VAULT_APPROLE_ROLE_ID` (not sensitive, but stored so the deploy workflow can fetch it programmatically instead of a human copy/pasting it) and prints it in the run summary.

`workflow_dispatch` inputs: `environment` (`dev`/`test`, default `test`), `cluster` (`dpn01`/`dpn02`, default `dpn01`), `cloud` (default `aws`). The temporary script/policy files are removed from the Vault pod at the end of every run.

> **Prerequisites:** Vault deployed and unsealed; the admin/root token available in AWS Secrets Manager at `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN`; KV v2 enabled at `pki-client`.

Re-run this workflow to rotate the `secret-id`, then re-run `dpn-gha-rest-federator-cd.yaml` so the pod picks up the refreshed value.

### Step3c: Configure Autoscaling

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `hpa.enabled` | Horizontal Pod Autoscaler for the gateway — **on by default**, not opt-in | `true` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.scaleUp.cpuUtilization` / `.memoryUtilization` | Target average utilisation (%) that triggers scale-up | `80` / `80` |
| `hpa.scaleUpBehavior.stabilizationWindowSeconds` / `hpa.scaleDown.stabilizationWindowSeconds` | How long a scale-up/scale-down decision must hold before acting | `60` / `300` |

### Step3d: Configure AWS ServiceAccount (IRSA)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `serviceAccount.create` | Render this chart's own `ServiceAccount` (separate from the gRPC Federator Gateway's) and attach it to the REST Federator Server pod | `true` |
| `serviceAccount.name` | Name of the `ServiceAccount` | `dpn-rest-federator` |
| `serviceAccount.irsaRoleArn` | ARN of the IAM role the `ServiceAccount` assumes, granting `secretsmanager:GetSecretValue`/`DescribeSecret` on `secretsManager.secretPrefix/*`. Not injected by the workflow — set it in the values file (the workflow prints the ARN in its log) | `arn:aws:iam::<account-id>:role/dpn-rest-federator-secrets-role` |
| `secretsManager.enabled` | Switch the gateway's `SecretProviderClass` to AWS Secrets Manager (mirrors `keyvault.enabled` on the Azure path) | `true` |
| `secretsManager.secretPrefix` | Path prefix for `BACKEND_API_KEY` and `VAULT_APPROLE_SECRET_ID` | `dpn/<environment>-<cluster>/rest-federator` |
| `keyvault.enabled` / `keyvault.secretName` | Despite the name, this gate mounts the CSI secret volume on AWS too; `secretName` is the Kubernetes Secret the `SecretProviderClass` syncs into | `true` / `dpn-rest-federator-server-secrets` |

The IAM role and its trust policy (scoped to `system:serviceaccount:<NAMESPACE>:dpn-rest-federator`, where `NAMESPACE` comes from the config JSON) do **not** need to be created manually — the `dpn-gha-rest-federator-cd.yaml` workflow's **Provision AWS IRSA Role + Secrets** step creates/updates the role idempotently on every run, and seeds `BACKEND_API_KEY`/`VAULT_TRUSTSTORE_PASSWORD` placeholders in Secrets Manager the first time (update them to real values before relying on the deployment).

### Step3e: Configure Redis Security

`dpn-redis` is TLS-only (plaintext disabled) and uses the shared `dpn-tls` certificate. There is no Redis username/password; access is gated by a Keycloak session.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.redis.host` / `port` | Service of the `dpn-redis` release | `dpn-rest-federator-redis-1.ns-dpn-01.svc.cluster.local` / `6379` |
| `restFederatorServer.redis.tlsEnabled` | Always `true`. `dpn-redis` is TLS-only | `true` |
| `restFederatorServer.keycloakAuthEnabled` | Gate Redis access with a Keycloak session. `true` in every real environment | `true` |
| `restFederatorServer.redisIdp.tokenUrl` | Keycloak token endpoint. Set per environment | `https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| `restFederatorServer.redisIdp.clientId` | Keycloak client used for Redis and OTLP authentication | `dpn-service-client` |
| `restFederatorServer.redisIdp.clientSecretEnabled` | Read the client secret from `dpn-keycloak-secrets` (`KC_SERVICE_CLIENT_SECRET`) | `true` |

> The `dpn-keycloak-secrets` Secret must exist in the namespace before deploy.

### Step3f: Configure OTel Collector Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `restFederatorServer.otel.tls.enabled` | HTTPS for OTLP export to the Collector. Reuses the mounted vault truststore, so no new secret is needed. Default `false` | `true` |
| `restFederatorServer.otel.oauth2.enabled` | Send an `Authorization: Bearer` token with OTLP export, using the `redisIdp` Keycloak client (`dpn-service-client`). Default `false` | `true` |

Enable both together where the Collector enforces HTTPS and Bearer auth.

---

## Step4: Configure Deployment Parameters

Deployed with the **`DPN CD - REST Federator Gateway`** GitHub Actions workflow (`dpn-gha-rest-federator-cd.yaml`) in the `dpn-rest-federator-gateway` repository:

```text
dpn-rest-federator-gateway/
└── .github/
    ├── workflows/
    │   ├── dpn-gha-rest-federator-cd.yaml
    │   ├── dpn-gha-rest-federator-role-id-creation.yaml
    │   └── dpn-gha-demo-runner-cd.yaml
    ├── actions/
    │   └── cloud-login/action.yml      <- Shared cloud login + EKS kubeconfig step
    └── config/
        └── aws/<environment>-<cluster>.json
```

The workflow's environment variables point at the charts in the same repository:

| Variable | Value |
|----------|-------|
| `PARAMETERS_FILE` | `.github/config/<cloud>/<environment>-<cluster>.json` |
| `HELM_DIR` / `RELEASE_NAME` | `charts/dpn-rest-federator` / `dpn-rest-federator` |
| `REDIS_HELM_DIR` / `REDIS_RELEASE_NAME` | `charts/dpn-redis` / `dpn-redis` |
| `VALUES_FILE` | `values/<cloud>/<environment>-<cluster>.yaml` (relative to each chart directory) |

Every key in the config JSON (`AWS_REGION`, `AWS_ACCOUNT_ID`, `EKS_CLUSTER`, `NAMESPACE`, `IMAGE_REGISTRY`, and so on) is exported as an environment variable, and the shared `cloud-login` action uses `AWS_REGION`/`AWS_ACCOUNT_ID`/`EKS_CLUSTER` to log in and fetch the EKS kubeconfig. Both releases are installed into `NAMESPACE`.

The workflow runs two jobs in order, each independently re-runnable: **deploy-redis** (the cache this chart owns) → **deploy-rest-federator** (the gateway, `needs: deploy-redis`). There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before either job runs.

One-time repository setup (from the repository's `.github/workflows/README.md`): a GitHub Environment named `<environment>-<cluster>` for each target, a self-hosted runner registered with the `[self-hosted, vmss]` labels the jobs target, and — on AWS — the OIDC trust from the shared hub role (`oidc_github_runner_hub`) into the target account's `oidc_github_runner_admin` role, which the `cloud-login` action chains through. No AWS secret is needed.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | The target DPN cluster — `dpn01` or `dpn02` (default `dpn01`) |
| `cloud` | Target cloud provider — `azure`, `aws` or `gcp` (default `aws`). Resolves `.github/config/<cloud>/<environment>-<cluster>.json` |
| `imageTag` | Tag of the REST Federator Server image to deploy (required) |
| `imageRepository` | Optional. Image path after `ghcr.io/energy-dsi/` (e.g. `dpn-rest-federator-server`) — leave blank to use `<IMAGE_REGISTRY>/dpn-rest-federator-server`, where `IMAGE_REGISTRY` comes from the config JSON |

On AWS, the **deploy-rest-federator** job runs three additional steps ahead of the Helm lint/deploy:

1. **Provision AWS IRSA Role + Secrets** — creates/updates the `dpn-rest-federator-secrets-role` IAM role (idempotent) and seeds `BACKEND_API_KEY`/`VAULT_TRUSTSTORE_PASSWORD` placeholders in Secrets Manager if they don't already exist — see [Step3d](#step3d-configure-aws-serviceaccount-irsa).
2. **Fetch Vault Truststore Password (AWS)** — reads `VAULT_TRUSTSTORE_PASSWORD` from Secrets Manager and passes it as `restFederatorServer.vault.truststorePassword`.
3. **Fetch Vault AppRole Role ID (AWS)** — reads `VAULT_APPROLE_ROLE_ID` (published by the `DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)` workflow — see [Step3b](#step3b-configure-vault-authentication)) and passes it as `restFederatorServer.vault.appRole.roleId`, so the checked-in values file placeholder never needs manual editing.

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

See the `dpn-rest-federator-gateway` source repository's `demo/demo-runner-client` for a complete worked example, including the expected `403` behaviour when a path falls outside a product's allowed-path configuration. The demo runner can also be deployed to the cluster from the same repository: its charts are `charts/dpn-demo-runner-server` and `charts/dpn-demo-runner-client` (each with `values/aws/<environment>-<cluster>.yaml`), deployed by the **`DPN CD - Demo Runner`** workflow (`.github/workflows/dpn-gha-demo-runner-cd.yaml`) as the `dpn-demo-runner-server` and `dpn-demo-runner-client` releases. Its `deployServer`/`runClient` inputs select which job runs; the client runs as a one-shot Kubernetes Job (named with the run ID) driven by the `mpan`, `postcode`, `assetId` and `fspId` inputs. On AWS both reuse the REST Federator's AppRole `role_id` (`dpn/<environment>-<cluster>/rest-federator/VAULT_APPROLE_ROLE_ID`), so run the Role ID Creation workflow first, and both seed their own `VAULT_TRUSTSTORE_PASSWORD` entries (`dpn/<environment>-<cluster>/demo-runner-server/` and `.../demo-runner-client/`) from the `DPN_TLS_TRUSTSTORE_PASSWORD` repository secret if missing.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
