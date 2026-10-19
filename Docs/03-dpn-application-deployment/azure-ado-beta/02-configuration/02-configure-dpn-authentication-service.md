# DPN Authentication Service (Keycloak) Configuration

This section describes how to configure and deploy the **DPN Authentication Service** — the platform's OAuth2/OIDC identity provider, **Keycloak** — into a single target environment and DPN cluster on Azure Kubernetes Service (AKS).

> **Deploy this immediately after Vault service deployed.** Deploy the Authentication Service, and create the realm/clients it expects, before enabling Keycloak-based auth on those components.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
- [Step3: Configure TLS](#step3-configure-tls)
- [Step4: Environment Configuration](#step4-environment-configuration)
  - [Step4a: Environment JSON (`config/<env>-<cluster>.json`)](#step4a-environment-json-configenv-clusterjson)
  - [Step4b: Helm Values Overlay (`values-<env>-<cluster>.yaml`)](#step4b-helm-values-overlay-values-env-clusteryaml)
- [Step5: Configure Deployment Parameters](#step5-configure-deployment-parameters)
- [Review Notes](#review-notes)

---

## Overview

Keycloak is deployed into `ns-dpn-01` over **standard one-way HTTPS** (`KC_HTTPS_CLIENT_AUTH=none`, `KC_HTTP_ENABLED=false`), reachable in-cluster and through an internal Azure Load Balancer only. It is bundled with its own PostgreSQL instance on a persistent volume.

| | |
|---|---|
| In-cluster URL | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443` |
| External access | Internal Azure Load Balancer (`dpn-keycloak-service-lb`), VNet only |
| Database | Bundled PostgreSQL on container (`dpn-keycloak-postgres`) used for keycloak configuration (see [Step4](#step4-environment-configuration)) |
| Secrets | Azure Key Vault via the Secrets Store CSI driver |

Consuming components resolve tokens against a realm on this Keycloak instance, for example the Federator Gateway's Kafka brokers when `kafka.authMode: sasl_ssl` (see [Configure DPN Federator Gateway, Step3d](05-configure-dpn-federator-gateway.md#step3d-configure-kafka-security)).

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **AKS cluster**, a **user-assigned managed identity**, and the **Secrets Store CSI driver** | The managed identity needs *get* access to the three CSI-mounted Key Vault secrets below (`KC-DB-PASSWORD`, `KEYCLOAK-ADMIN-PASSWORD`, `KC-SERVICE-CLIENT-SECRET`). The pipeline also reads `KC-SERVICE-CLIENT-SECRET` directly with `az keyvault secret show` for its preflight check and for the realm-configuration step |
| 2 | **`dpn-tls` and `tls-auth-secret` present in the namespace** | Created automatically by the `dpn-tls-cd` pipeline (`dpn-federator-certificate-manager` repository) — run it before deploying Keycloak. See [Step3: Configure TLS](#step3-configure-tls) |
| 3 | **Three Key Vault secrets populated** | See [Step2: Configure Secrets](#step2-configure-secrets) |
| 4 | **No image tag input needed** | The pipeline hardcodes upstream `quay.io/keycloak/keycloak:26.3.2` (and `postgres:16-alpine`) and imports both into ACR itself during Deploy — there is no `imageTag` parameter to supply |
| 5 | **`config/<env>-<cluster>.json` and `values-<env>-<cluster>.yaml` populated** | See [Step4: Environment Configuration](#step4-environment-configuration) |

> **Azure DevOps pipeline setup (one-time):** create the target namespace (`kubectl create namespace <namespace>`) and the Azure service connection before running the CD pipeline — it does not create either for you.

---

## Step2: Configure Secrets

The deploy pipeline reads the required secret names out of the rendered `SecretProviderClass` and fails fast if any is missing, rather than letting the pod fail with an opaque CSI mount error. Create these three secrets in the environment's Key Vault before the first deploy:

| Key Vault secret | Becomes | Used by |
|-------------------|---------|---------|
| `KC-DB-PASSWORD` | `KC_DB_PASSWORD` | Keycloak, and PostgreSQL via `POSTGRES_PASSWORD_FILE` |
| `KEYCLOAK-ADMIN-PASSWORD` | `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin account - This password would be required for DPN Admin to login keycloak and set up new users as admin or reader or operator |
| `KC-SERVICE-CLIENT-SECRET` | `KC_SERVICE_CLIENT_SECRET` | Sets the secret on the `dpn-service-client` UI client; must match the same Key Vault object already synced by `dpn-health-monitoring-service`'s oauth2-proxy releases (OpenSearch Dashboards, Jaeger, Perses, Portal) and by Kafka UI's own `SecretProviderClass` for its native OIDC login |

> **Keystore/truststore passwords are not a separate Key Vault secret.** `KC_HTTPS_KEY_STORE_PASSWORD`/`KC_HTTPS_TRUST_STORE_PASSWORD` are read directly from the shared `tls-auth-secret` (`KEYSTORE_PASSWORD`/`TRUSTSTORE_PASSWORD`), created by `dpn-tls-cd`.

> **PostgreSQL first-install ordering.** The superuser password is read from the CSI-mounted file (`POSTGRES_PASSWORD_FILE`) rather than the synced Kubernetes secret directly, because the CSI driver only creates that secret once a pod has actually mounted the `SecretProviderClass` — reading the file avoids a chicken-and-egg failure on the very first deploy.

---

## Step3: Configure TLS

Keycloak reads its certificate from the pre-existing `dpn-tls` secret (mounted read-only at `/cert`) rather than from Vault or the Certificate Manager — this is a platform/ingress-style certificate, not the DPN's DSM-signed federation certificate. `dpn-tls` is created automatically by the `dpn-tls-cd` pipeline — see [Configure DPN Vault Service, Step 3A](01-configure-dpn-vault-service.md#step-3a-configure-dpn-universal-tls-dpn-tls-cd). Run it before deploying Keycloak.

1. Find the alias of the server key inside `keystore.jks`:

   ```sh
   kubectl get secret dpn-tls -n <namespace> \
     -o jsonpath='{.data.keystore\.jks}' | base64 -d > keystore.jks

   KEYSTORE_PASSWORD=$(kubectl get secret tls-auth-secret -n <namespace> \
     -o jsonpath='{.data.KEYSTORE_PASSWORD}' | base64 -d)

   keytool -list -keystore keystore.jks -storepass "$KEYSTORE_PASSWORD"
   ```

2. Set `config.KC_HTTPS_KEY_ALIAS` to that alias in the environment values file — Keycloak aborts at startup if the alias does not exist.
3. Set `config.KC_HOSTNAME` to a DNS name the certificate's SANs actually cover. It defaults to the in-cluster FQDN (`https://dpn-keycloak.<namespace>.svc.cluster.local:8443`); a shared platform certificate often covers a public DNS name instead — the deploy pipeline prints the certificate's SANs so you can check.

---

## Step4: Environment Configuration

Two per-environment files must be populated: the pipeline's environment JSON (`config/<env>-<cluster>.json`) and the Helm values overlay (`values-<env>-<cluster>.yaml`).

### Step4a: Environment JSON (`config/<env>-<cluster>.json`)

The CD pipeline loads its Azure targeting and the Keycloak admin/realm details from `.pipelines/azure-pipelines/config/<env>-<cluster>.json`. Every key below is read by the pipeline (via `jq`) and must be present:

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `ENV_NAME` | Deployment environment abbreviation | `<env>` |
| `CONTAINER_REGISTRY` | ACR name | `acrdpn<env>uks01` |
| `CONTAINER_REGISTRY_URL` | ACR URL | `acrdpn<env>uks01.azurecr.io` |
| `BASE_REGISTRY` | Base container registry URL | `acrdpn<env>uks01.azurecr.io` |
| `AZURE_SUBSCRIPTION_ID` | Subscription where the infrastructure is deployed | `<subscription-id>` |
| `RESOURCE_GROUP` | Resource group containing the AKS cluster | `rg-aks-dpn-<env>-uks-08` |
| `AKS_CLUSTER` | AKS cluster name | `aks-dpn-<env>-uks-08` |
| `NAMESPACE` | Kubernetes namespace for the deployment | `ns-dpn-01` |
| `KEY_VAULT_NAME` | Key Vault holding the secrets from [Step2](#step2-configure-secrets) | `kv-dpn-<env>-<region>-<seq>` |
| `KEYCLOAK_BASE_URL` | Local URL the pipeline port-forwards to when running `configure-keycloak.sh` (the local port is taken from here) | `https://127.0.0.1:18443` |
| `KEYCLOAK_ADMIN_USER` | Master-realm bootstrap admin username (password comes from `KEYCLOAK-ADMIN-PASSWORD` in Key Vault) | `admin` |
| `KEYCLOAK_REALM` | Realm the configuration script creates/updates | `dpn-realm` |
| `KEYCLOAK_CLIENT_ID` | Machine-to-machine client the script creates | `DPN-Client` |

> **Note:** `ServiceConnection`, `environment`, and `dpnCluster` are supplied as pipeline **runtime parameters** at trigger time — they are **not** keys in this JSON file (see [Step5](#step5-configure-deployment-parameters)).

### Step4b: Helm Values Overlay (`values-<env>-<cluster>.yaml`)

Copy `values.yaml` (reference — do not edit directly) to `values-<env>-<cluster>.yaml`.

```text
Root-Repository
  └── charts
        └── keycloak
              ├── values.yaml                  <- Reference file; do not edit directly
              └── values-<env>-<cluster>.yaml  <- Your environment + cluster overrides
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
---

## Step5: Configure Deployment Parameters

Deployed with the CD pipeline `dpn-keycloak-cd.yaml` in the `dpn-authentication-service` repository:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            ├── dpn-keycloak-cd.yaml
            └── dpn-keycloak-uninstall-cd.yaml
```

The deploy pipeline runs **Validate** (confirms the Key Vault secrets exist, verifies the TLS certificate and its alias/SANs, `helm lint` + dry run) → **Deploy** (`helm upgrade --install`, records the deployed image digest, then configures the realm/clients — see below) → **Verify** (confirms the load balancer is internal, checks the HTTPS endpoint from inside the cluster, and asserts plaintext HTTP is refused). The Deploy stage is gated on the environment's approver group.

Runtime parameters: `ServiceConnection`, `environment`, `dpnCluster`.

The uninstall pipeline (`dpn-keycloak-uninstall-cd.yaml`) retains the PostgreSQL PVC by default so realm data survives a reinstall — pass `deletePvc: true` to destroy it.

> **Realm and client configuration is automatic, not manual.** After `helm upgrade --install` completes, the Deploy stage runs a step named **"Configure Realm, Client, Roles and Audit Logging"**, which port-forwards to the Keycloak service and runs `charts/keycloak/scripts/configure-keycloak.sh` against the Admin REST API. This script is idempotent (create on first run, update on later ones) and creates/updates the `dpn-realm` realm, the `DPN-Client` machine-to-machine client, the `dpn-service-client` UI client (secret sourced from `KC-SERVICE-CLIENT-SECRET`), realm roles, groups, protocol mappers, and audit/event logging settings on every deploy. No manual admin-console step is required for this baseline configuration.

---

## Review Notes

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 | 
