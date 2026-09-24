# DPN Health Monitoring Service Configuration Guide

---

## Table of Contents

- [Overview](#overview)
- [Continuous Deployment (CD)](#continuous-deployment-cd)
- [Step 1: Prepare Environment Configuration File](#step-1-prepare-environment-configuration-file)
- [Step 2: Prepare Secrets Configuration](#step-2-prepare-secrets-configuration)
- [Review Notes](#review-notes)

---

## Overview

The DPN Health Monitoring Service hosts the observability platform for DPN. It provides health metrics and detailed logs reported by each DPN component. The Health Monitoring service is deployed in a separate namespace, `ns-dpn-health-01`.

---

## Continuous Deployment (CD)

DPN Health Monitoring Service is provided in repository `dpn-health-monitoring-service` 

Every health monitoring component is a third-party Helm chart/image compliant with Apache 2.0. There is no CI pipeline for this component. Deployment is orchestrated by `monitoring-master-cd.yaml`, calling each component's own CD template as a dependent stage.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── monitoring-master-cd.yaml
```
---

## Step 1: Prepare Environment Configuration File

Organisations should prepare a config file per environment (and DPN cluster) where the health monitoring service is deployed, named `<env>-<cluster>.json` (e.g. `dev-dpn01.json`), and keep it in the following location. This file will be referenced by the CD pipeline during deployment.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── config/
            └── <env>-<cluster>.json
```

Refer to [Step2.2: Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration) for the per-environment configurations.

In addition to the common keys, this repository's `config/<env>-<cluster>.json` requires:

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `OBSERVABILITY_LB_IP` | Fixed internal load-balancer IP for this environment's Prometheus and Thanos Query services | `10.XXX.XXX.10` |

> **Why this is required per environment.** Prometheus's and Thanos Query's own chart values hardcode the same `loadBalancerIP` as a placeholder default. The CD pipeline overrides both from `OBSERVABILITY_LB_IP` at deploy time — leaving it unset in a given environment's config risks that environment colliding with another on the same fixed IP, or the deployment hanging on `helm --wait` if the requested IP is already claimed elsewhere on the network.

---

## Step 2: Prepare Secrets Configuration

Every UI in DPN Health Monitoring authenticates against the DPN Authentication Service (Keycloak) — either fronted by its own `oauth2-proxy` release, or via the UI's own native OIDC login. There is no basic-auth gateway: the previous nginx basic-auth proxy (`charts/nginx-observability`) has been fully removed from this repository and replaced by this Keycloak-based model.

DPN Health Monitoring requires the following Kubernetes secrets to be created for deployment.

|secret-name| Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
| dpn-mon-storage-connection-string | An `objstore.yml` file containing the Thanos object-storage config (storage account name, container, and a SAS-token-based connection string) for the storage account used by Thanos | Kubernetes Secret using volume mount i.e. kubectl create secret generic <secret-name> --from-file=`<path-to-file>` |
| dpn-health-tls | A `kubernetes.io/tls` Secret holding `tls.crt`, `tls.key`, and `ca.crt` — the browser-facing HTTPS certificate for the UIs in this namespace, also used by Kafka UI for its own TLS termination and for OpenSearch/Keycloak TLS trust | Created automatically in `ns-dpn-health-01` by the `dpn-tls-cd` pipeline (`dpn-federator-certificate-manager` repository, not this repository) — see [Configure DPN Vault Service, Step 3A](01-configure-dpn-vault-service.md#step-3a-configure-dpn-universal-tls-dpn-tls-cd) |

**Azure Key Vault secrets (not `kubectl` secrets).** Populate these before running `monitoring-master-cd.yaml` — its Validate Required Secrets stage checks all four and fails a fresh environment without them.

| Key Vault secret | Used by | How to create |
|-------------------|---------|----------------|
| `KC-SERVICE-CLIENT-SECRET` | Every `oauth2-proxy` release, Kafka UI's native OIDC login | Must match the `dpn-service-client` client secret — see [Configure DPN Authentication Service, Step2](02-configure-dpn-authentication-service.md#step2-configure-secrets) |
| `KC-OPENSEARCH-ADMIN-PASSWORD` | OpenSearch `admin` internal user (superuser) | See below |
| `KC-OPENSEARCH-KIBANASERVER-PASSWORD` | OpenSearch `kibanaserver` internal user (Dashboards backend account) | See below |
| `KC-OPENSEARCH-DATAWRITER-PASSWORD` | OpenSearch `datawriter` internal user (Data Prepper, init jobs) | See below |

**Creating the three `KC-OPENSEARCH-*` secrets.** Each plaintext value must match a bcrypt hash already committed in `charts/opensearch/opensearch-community-values.yaml` — the CD pipeline always uses this one file, with no per-environment override, so the same three passwords apply to every environment until the hashes below are changed.

1. Generate a bcrypt hash for a chosen password (repeat per user — `admin`, `kibanaserver`, `datawriter`):

   ```bash
   docker run --rm opensearchproject/opensearch:2.11.0 ./plugins/opensearch-security/tools/hash.sh -p "<plaintext-password>"
   ```

   (one line, works unchanged in bash, PowerShell, or cmd)

2. Replace that user's `hash:` value in `charts/opensearch/opensearch-community-values.yaml` (under `internal_users.yml` → `admin` / `kibanaserver` / `datawriter`).
3. Store the same plaintext in Key Vault:

   ```bash
   az keyvault secret set --vault-name <KEY_VAULT_NAME> --name KC-OPENSEARCH-ADMIN-PASSWORD --value '<plaintext-password>'
   az keyvault secret set --vault-name <KEY_VAULT_NAME> --name KC-OPENSEARCH-KIBANASERVER-PASSWORD --value '<plaintext-password>'
   az keyvault secret set --vault-name <KEY_VAULT_NAME> --name KC-OPENSEARCH-DATAWRITER-PASSWORD --value '<plaintext-password>'
   ```

**Access model, by UI:**

- **OpenSearch Dashboards, Jaeger, Perses, and the DPN Portal** are each fronted by their own `oauth2-proxy` release, terminating OIDC login against the DPN Authentication Service (Keycloak). See [DPN Portal Operations](../../../05-dpn-user-interfaces/08-dpn-portal-ui-operations.md) and [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md).
- **Kafka UI** authenticates natively, not through `oauth2-proxy` — it runs its own OIDC login directly against the `dpn-realm` realm, with `dpnadmin`/`dpnreader` realm roles mapped to Kafka UI's own RBAC (full access vs. view-only), and terminates its own TLS using the `dpn-health-tls` Secret above. See [Kafka Health UI Operations](../../../05-dpn-user-interfaces/07-kafka-health-ui-operations.md#3-accessing-the-kafka-ui).
- **Apache Airflow** also authenticates natively against Keycloak, not through an `oauth2-proxy` sidecar. See [Configure DPN Data Pipelines](07-configure-dpn-data-pipelines.md).
- **Prometheus and Thanos** have no login gateway of any kind — neither needs direct browser access; both are consumed through the Perses dashboards instead.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 | 
