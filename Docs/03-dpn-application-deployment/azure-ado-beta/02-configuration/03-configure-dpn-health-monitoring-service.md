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

It comprises the following components: Kafka, OpenSearch (with Dashboards), Data Prepper, Jaeger, OpenTelemetry (OTel) Collector, Prometheus, Thanos, Perses, oauth2-proxy (Keycloak gateway) and the DPN Portal.

Access to the UIs is role-based. Two Keycloak realm roles are used: `dpnadmin` (view and edit) and `dpnreader` (view only). Users must be created with the relevant role to access the UI components.

---

## Continuous Deployment (CD)

DPN Health Monitoring Service is provided in repository `dpn-health-monitoring-service` 

Every health monitoring component is a third-party Helm chart/image compliant with Apache 2.0, with one exception: the DPN Portal (`app/dpn-portal`) is built from source. Deployment is orchestrated by `monitoring-master-cd.yaml`, calling each component's own CD template as a dependent stage.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        ├── ci-pipelines/
        │   └── dpn-portal-ci.yaml
        └── cd-pipelines/
            ├── monitoring-master-cd.yaml
            ├── validate-required-secrets-cd.yaml
            ├── oauth2-proxy-cd.yaml
            ├── dpn-portal-image-cd.yaml
            ├── dpn-health-monitoring-rollback-cd.yaml
            └── dpn-health-monitoring-uninstall-cd.yaml
```

The approval group is resolved automatically from the environment: `dsi-dev` for `dev`, `dsi-devtest` for `devtest`/`test`, and `dsi-ppd` for `pdev`/`ptest`/`puat`.

### Prerequisite: build the DPN Portal image

The DPN Portal is the only component built from source. Its image is built, scanned, signed and pushed by a separate pipeline, `ci-pipelines/dpn-portal-ci.yaml`, which must be run manually **before** `monitoring-master-cd.yaml`. At the end of its `BuildAndPush` stage it prints the short git SHA of the image. The deployer must supply this short-SHA tag as the `dpnPortalImageTag` parameter of `monitoring-master-cd.yaml`; the parameter has no default.

### Stage order

`monitoring-master-cd.yaml` runs the following stages in order. Each stage depends on those listed against it.

| # | Stage | Depends on |
|---|-------|------------|
| 1 | Init (load environment config) | — |
| 2 | Approval Gate (single approval for the whole run) | Init |
| 3 | Validate Required Secrets | Approval Gate |
| 4 | Kafka | Validate Required Secrets |
| 5 | OpenSearch | Kafka |
| 6 | Prometheus | OpenSearch |
| 7 | Thanos | Prometheus |
| 8 | Data Prepper | Kafka, OpenSearch |
| 9 | Jaeger | Kafka, OpenSearch |
| 10 | Perses | Prometheus, Thanos |
| 11 | OTel Collector | Kafka, OpenSearch, Data Prepper, Jaeger |
| 12 | Deploy dpn-portal image | Kafka, OpenSearch, Jaeger, Prometheus, Thanos, Perses |
| 13 | OAuth2 Proxy (Keycloak) — chained releases: opensearch, jaeger, perses, portal | All stages above |
| 14 | Validate (deployment and gateway checks) | OTel Collector, Perses, Thanos, Data Prepper, Jaeger, OAuth2 Proxy |

> The `Approval Gate` stage is deliberately unbypassable: every later stage is rooted at it, so none can run (including via "run selected stages") without it having succeeded in the same run. The oauth2-proxy releases are deployed one after another rather than in parallel, because they all publish a port on the same static internal load-balancer IP.
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

The pipeline looks for `<env>.json` first and falls back to `<env>-<cluster>.json`. Config files exist for `dev`, `devtest` and `test` (each with `dpn01` and `dpn02`), and for the pre-production environments `pdev-dpn01`, `ptest-dpn01` and `puat-dpn01`. The pre-production environments are single-DPN: the pipeline fails if `dpn02` is selected for them.

Refer to [Step2.2: Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration) for the per-environment configurations.

In addition to the common keys, this repository's `config/<env>-<cluster>.json` requires:

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `OBSERVABILITY_LB_IP` | Fixed internal load-balancer IP shared by this environment's observability services (oauth2-proxy releases, Prometheus, Thanos Query and Kafka UI), each published on its own port | `10.XXX.XXX.10` |

> **Why this is required per environment.** The chart values for the services sharing this IP hardcode the same `loadBalancerIP` as a placeholder default. The CD pipeline overrides it from `OBSERVABILITY_LB_IP` at deploy time — leaving it unset in a given environment's config risks that environment colliding with another on the same fixed IP, or the deployment hanging on `helm --wait` if the requested IP is already claimed elsewhere on the network.

---

## Step 2: Prepare Secrets Configuration

Every UI in DPN Health Monitoring authenticates against the DPN Authentication Service (Keycloak) — either fronted by its own `oauth2-proxy` release, or via the UI's own native OIDC login. The DPN Authentication Service must therefore be deployed first, and the callbacks for each gateway registered on its Keycloak client; otherwise the final Validate stage fails on a fresh environment. The proxies reach Keycloak at `dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local:8443`. There is no basic-auth gateway: the previous nginx basic-auth proxy (`charts/nginx-observability`) has been fully removed from this repository and replaced by this Keycloak-based model.

DPN Health Monitoring requires the following Kubernetes secrets to be created for deployment.

|secret-name| Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
| dpn-mon-storage-connection-string | An `objstore.yml` file containing the Thanos object-storage config (storage account name, container, and a SAS-token-based connection string) for the storage account used by Thanos | Kubernetes Secret using volume mount i.e. kubectl create secret generic <secret-name> --from-file=`<path-to-file>` |
| tls-auth-secret | Holds `KEYSTORE_PASSWORD`, `TRUSTSTORE_PASSWORD` and `DPN_CLIENT_P12_PASSWORD`; read by Kafka UI and Data Prepper | Created automatically in `ns-dpn-health-01` by the `dpn-tls-cd` pipeline, as for `dpn-health-tls` below. It must exist before deployment — the Validate Required Secrets stage fails fast if it is missing |
| dpn-health-tls | A `kubernetes.io/tls` Secret holding `tls.crt`, `tls.key`, and `ca.crt` — the browser-facing HTTPS certificate for the UIs in this namespace, also used by Kafka UI for its own TLS termination and for OpenSearch/Keycloak TLS trust | Created automatically in `ns-dpn-health-01` by the `dpn-tls-cd` pipeline (`dpn-federator-certificate-manager` repository, not this repository) — see [Configure DPN Vault Service, Step 3A](01-configure-dpn-vault-service.md#step-3a-configure-dpn-universal-tls-dpn-tls-cd) |

**Azure Key Vault secrets (not `kubectl` secrets).** Populate these before running `monitoring-master-cd.yaml` — its Validate Required Secrets stage checks that all four exist in the Key Vault (and that `tls-auth-secret` exists in the namespace), and fails a fresh environment without them. Only existence is checked, never the value. `TRUSTSTORE-PASSWORD` is not in this list: it is read from `tls-auth-secret`, not synced from Key Vault by this repository.

| Key Vault secret | Used by | How to create |
|-------------------|---------|----------------|
| `KC-SERVICE-CLIENT-SECRET` | Every `oauth2-proxy` release and Kafka UI's native OIDC login (synced into the shared `dpn-keycloak-shared-akv` Secret) | Must match the `dpn-service-client` client secret — see [Configure DPN Authentication Service, Step2](02-configure-dpn-authentication-service.md#step2-configure-secrets) |
| `KC-OPENSEARCH-ADMIN-PASSWORD` | OpenSearch `admin` internal user (superuser), synced via `opensearch-oidc-kv-secretproviderclass` | See below |
| `KC-OPENSEARCH-KIBANASERVER-PASSWORD` | OpenSearch `kibanaserver` internal user (Dashboards backend account) | See below |
| `KC-OPENSEARCH-DATAWRITER-PASSWORD` | OpenSearch `datawriter` internal user (Data Prepper, init jobs) | See below |

**Creating the three `KC-OPENSEARCH-*` secrets.** Each plaintext value must match a bcrypt hash already committed in `charts/opensearch/opensearch-community-values.yaml` — the CD pipeline always uses this one file, with no per-environment override, so the same three passwords apply to every environment until the hashes below are changed. (The hashes were last rotated for `pdev`.)

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
- **Prometheus and Thanos** have no login gateway of any kind — neither needs direct browser access; both are consumed through the Perses dashboards instead.
- **`kafka-ui-2`** has no gateway in this repository. It fronted a UI in `ns-dpn-01` that this repository does not own; exposing that UI is the responsibility of its own chart.
- **Apache Airflow** is not part of the Health Monitoring service and has no `oauth2-proxy` gateway here. The DPN Portal tile that previously linked to Airflow now links to the Data Product Management self-service portal. See [Configure DPN Data Pipelines](07-configure-dpn-data-pipelines.md) for Airflow itself.

**Ports on the shared load-balancer IP (`OBSERVABILITY_LB_IP`):**

| UI | Port | Authentication |
|----|------|----------------|
| OpenSearch Dashboards | 5601 | `oauth2-proxy` |
| Jaeger | 16686 | `oauth2-proxy` |
| Perses | 8083 | `oauth2-proxy` |
| DPN Portal | 8443 | `oauth2-proxy` |
| Kafka UI | 8082 | Native OIDC + own TLS |
| Prometheus | 9081 | None |
| Thanos Query | 9091 | None |

The final Validate stage confirms that each of the four `oauth2-proxy` gateways (OpenSearch Dashboards, Jaeger, Perses, DPN Portal) has a ready replica and a load-balancer address, and fails the run otherwise.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.1.0 | 
