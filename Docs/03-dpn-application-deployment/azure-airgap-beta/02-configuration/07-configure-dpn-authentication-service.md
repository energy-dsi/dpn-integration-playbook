# DPN Authentication Service (Keycloak) Configuration

This section describes how to configure and deploy the **DPN Authentication Service** — the platform's OAuth2/OIDC identity provider, **Keycloak** — into a single target environment and DPN cluster on Azure Kubernetes Service (AKS).

> **Deploy this before components that authenticate against it.** The Federator Gateway's Kafka brokers (`kafka.authMode: sasl_ssl`) and the DPN observability UIs authenticate against this Keycloak realm. Deploy the Authentication Service, and create the realm/clients it expects, before enabling Keycloak-based auth on those components.

> **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`, e.g. `dpn01`). Substitute your own values throughout.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
- [Step3: Configure TLS](#step3-configure-tls)
- [Step4: Environment Configuration](#step4-environment-configuration)
- [Step5: Configure Deployment Parameters](#step5-configure-deployment-parameters)
- [Review Notes](#review-notes)

---

## Overview

Keycloak is deployed into `ns-dpn-01` over **standard one-way HTTPS** (`KC_HTTPS_CLIENT_AUTH=none`, `KC_HTTP_ENABLED=false` — there is no plaintext listener), reachable in-cluster and through an internal Azure Load Balancer only. It is bundled with its own PostgreSQL instance on a persistent volume.

| | |
|---|---|
| In-cluster URL | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443` |
| External access | Internal Azure Load Balancer (`dpn-keycloak-service-lb`), VNet only |
| Database | Bundled PostgreSQL (`dpn-keycloak-postgres`) — can be pointed at a managed database instead (see [Step4](#step4-environment-configuration)) |
| Secrets | Azure Key Vault via the Secrets Store CSI driver |

Consuming components resolve tokens against a realm on this Keycloak instance, for example the Federator Gateway's Kafka brokers when `kafka.authMode: sasl_ssl` (see [Configure DPN Federator Gateway, Step3d](04-configure-dpn-federator-gateway.md#step3d-configure-kafka-security)).

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **AKS cluster**, a **user-assigned managed identity**, and the **Secrets Store CSI driver** | The managed identity needs *get* access to the four Key Vault secrets below |
| 2 | **`dpn-tls` Kubernetes secret present in the namespace** | An `Opaque` secret holding `keystore.jks`/`truststore.jks` (Java keystores, **not** a `kubernetes.io/tls` secret) — created before Keycloak is deployed. See [Step3: Configure TLS](#step3-configure-tls) |
| 3 | **Four Key Vault secrets populated** | See [Step2: Configure Secrets](#step2-configure-secrets) |
| 4 | **Container image tag available** | Stock upstream Keycloak pulled via ACR (or GHCR); pinned in the environment values file — the CD workflow does not take an `imageTag` input for this component |
| 5 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step4: Environment Configuration](#step4-environment-configuration) |

> **One-time setup:** create the target namespace (`kubectl create namespace <namespace>`) and complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) before running the CD workflow — it does not create the namespace for you.

---

## Step2: Configure Secrets

The deploy pipeline reads the required secret names out of the rendered `SecretProviderClass` and fails fast if any is missing, rather than letting the pod fail with an opaque CSI mount error. Create these four secrets in the environment's Key Vault before the first deploy:

| Key Vault secret | Becomes | Used by |
|-------------------|---------|---------|
| `KC-DB-PASSWORD` | `KC_DB_PASSWORD` | Keycloak, and PostgreSQL via `POSTGRES_PASSWORD_FILE` |
| `KEYCLOAK-ADMIN-PASSWORD` | `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin account |
| `KC-HTTPS-KEY-STORE-PASSWORD` | `KC_HTTPS_KEY_STORE_PASSWORD` | Opens `keystore.jks` |
| `KC-HTTPS-TRUST-STORE-PASSWORD` | `KC_HTTPS_TRUST_STORE_PASSWORD` | Opens `truststore.jks` |

> **PostgreSQL first-install ordering.** The superuser password is read from the CSI-mounted file (`POSTGRES_PASSWORD_FILE`) rather than the synced Kubernetes secret directly, because the CSI driver only creates that secret once a pod has actually mounted the `SecretProviderClass` — reading the file avoids a chicken-and-egg failure on the very first deploy.

---

## Step3: Configure TLS

Keycloak reads its certificate from the pre-existing `dpn-tls` secret (mounted read-only at `/cert`) rather than from Vault or the Certificate Manager — this is a platform/ingress-style certificate, not the DPN's DSM-signed federation certificate.

1. Create `dpn-tls` in the target namespace as an `Opaque` secret with two keys, `keystore.jks` and `truststore.jks`.
2. Find the alias of the server key inside `keystore.jks`:

   ```sh
   kubectl get secret dpn-tls -n <namespace> \
     -o jsonpath='{.data.keystore\.jks}' | base64 -d > keystore.jks

   keytool -list -keystore keystore.jks \
     -storepass "$(az keyvault secret show --vault-name <KEY_VAULT_NAME> \
       --name KC-HTTPS-KEY-STORE-PASSWORD --query value -o tsv)"
   ```

3. Set `config.KC_HTTPS_KEY_ALIAS` to that alias in the environment values file — Keycloak aborts at startup if the alias does not exist.
4. Set `config.KC_HOSTNAME` to a DNS name the certificate's SANs actually cover. It defaults to the in-cluster FQDN (`https://dpn-keycloak.<namespace>.svc.cluster.local:8443`); a shared platform certificate often covers a public DNS name instead — the deploy workflow prints the certificate's SANs so you can check.

---

## Step4: Environment Configuration

Set the parameters below in your environment/cluster's values file.

```text
dpn-authentication-service/
  └── charts/
        └── keycloak/
              ├── values.yaml                              <- Reference file; do not edit directly
              └── values/azure/<environment>-<cluster>.yaml <- Your environment + cluster overrides
```

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `config.KC_HOSTNAME` | Hostname Keycloak advertises — must match the certificate SANs | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443` |
| `config.KC_HOSTNAME_STRICT` | Whether Keycloak rejects requests whose `Host` header doesn't match `KC_HOSTNAME`. Leave `"false"` while `KC_HOSTNAME` itself is left empty | `"false"` |
| `config.KC_HTTPS_KEY_ALIAS` | Alias of the server key inside `keystore.jks` | *(from Step3)* |
| `service.loadBalancer.loadBalancerIP` | Static IP for Keycloak's LoadBalancer Service. Leave empty on first deploy — Azure auto-assigns one — then pin the assigned IP here so it survives a Service recreation | `""`, then the assigned IP after first deploy |
| `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | AKV name, managed-identity client ID, tenant ID | `kv-dpn-<env>-<region>-<seq>` / `<managed-identity-client-id>` / `<tenant-id>` |
| `image.repository` | ACR path for the Keycloak image | `<ACR_NAME>.azurecr.io/keycloak` |

**Using a managed database instead of the bundled PostgreSQL:**

```yaml
postgres:
  enabled: false
config:
  KC_DB_URL: jdbc:postgresql://<server>.postgres.database.azure.com:5432/keycloak_db
  KC_DB_USERNAME: keycloak_db_user
```

**Environments provided:** `dev`/`devtest`/`test` (both `dpn01` and `dpn02`); `pdev`/`ptest`/`puat` (single-DPN, `dpn01` only — both pipelines fail fast if `dpn02` is selected for these).

---

## Step5: Configure Deployment Parameters

Deployed with the `dpn-keycloak-cd.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`:

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        └── dpn-keycloak-cd.yml
```

The workflow runs `helm lint` + dry run, then `helm upgrade --install` (rolling out both `dpn-keycloak-postgres` and `dpn-keycloak` deployments), and records the deployed image digest as a workflow artifact. There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.

`workflow_dispatch` inputs: `environment`, `cluster`, `cloud` — there is no `imageTag` input for this component; pin the image tag in the environment values file instead (see [Step4](#step4-environment-configuration)).

There is no dedicated uninstall workflow for this component yet — to remove it, run `helm uninstall dpn-keycloak -n <namespace>` directly (this retains the PostgreSQL PVC by default, so realm data survives a reinstall; delete the PVC separately if you want a clean wipe).

> **Realm and client configuration is out of scope for this chart.** This workflow deploys the Keycloak server only; creating the `dpn-realm` realm and the OAuth clients that Kafka, the observability UIs, and other components authenticate as is a manual, per-environment configuration step performed against the running Keycloak admin console.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| — | — | Draft — pending DSI Assurance review | V0.1.0 |
