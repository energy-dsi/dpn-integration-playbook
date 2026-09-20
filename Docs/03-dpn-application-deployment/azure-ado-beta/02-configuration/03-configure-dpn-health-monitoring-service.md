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
| dpn-health-tls | A `kubernetes.io/tls` Secret holding `tls.crt`, `tls.key`, and `ca.crt` — the browser-facing HTTPS certificate for the UIs in this namespace, also used by Kafka UI for its own TLS termination and for OpenSearch/Keycloak TLS trust | Pre-existing in `ns-dpn-health-01`; not created by any chart in this repository |

> **`KC-SERVICE-CLIENT-SECRET` (Azure Key Vault, not a `kubectl` secret).** The `dpn-service-client` Keycloak client's secret must exist as this object in the environment's Key Vault before deployment — each `oauth2-proxy` release and Kafka UI's own `SecretProviderClass` sync it independently via the Secrets Store CSI driver. A fresh environment's deploy pipeline fails at its Validate stage until this object exists and the required redirect URIs/callbacks are registered on the Keycloak client.

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
