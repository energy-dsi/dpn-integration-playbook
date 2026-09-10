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

DPN Health Monitoring Service is provided in repository `dpn-health-monitoring-service`, with its deployment automation living in `dpn-containerised-deployment-service`.

Every health monitoring component is a third-party Helm chart/image compliant with Apache 2.0. There is no CI pipeline for this component. Deployment is orchestrated by the `dpn-health-monitoring-cd-install.yml` GitHub Actions workflow, which chains each component's own CD workflow as a dependent job in this order: Kafka → OpenSearch → Prometheus → Thanos (with Data Prepper and Jaeger branching off Kafka+OpenSearch, Perses off Prometheus+Thanos) → OTel Collector → Nginx Observability Proxy → Validate.

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        ├── dpn-health-monitoring-cd-install.yml   # orchestrator — trigger this one
        └── dpn-cd-{kafka,opensearch,prometheus,thanos,data-prepper,jaeger,perses,otel,nginx-observability,validate}.yml
```

Trigger it via **Actions → DPN Health Monitoring → Run workflow**, supplying `environment` (dev/test), `cluster` (dpn01/dpn02), `cloud` (`azure`), and `imageTag` (OTel Collector image tag, default `0.95.0`) — the orchestrator reads the rest of the component config from `.github/config/azure/<environment>-<cluster>.json` itself and passes it to every job.

---

## Step 1: Prepare Environment Configuration File

Organisations should prepare a config file per environment/cluster where the health monitoring service is deployed, and keep it in the following location. This file will be read by the `init` job of the orchestrator workflow during deployment.

```text
dpn-containerised-deployment-service/
└── .github/
    └── config/
        └── azure/
            └── <environment>-<cluster>.json
```

Refer to [Step2.2: Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration) for the per-environment configurations.

In addition to the common keys, this config file requires:

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `OBSERVABILITY_LB_IP` | Fixed internal load-balancer IP for this environment's Prometheus and Thanos Query services | `10.226.121.10` |

> **Why this is required per environment.** Prometheus's and Thanos Query's own chart values hardcode the same `loadBalancerIP` as a placeholder default. The CD pipeline overrides both from `OBSERVABILITY_LB_IP` at deploy time — leaving it unset in a given environment's config risks that environment colliding with another on the same fixed IP, or the deployment hanging on `helm --wait` if the requested IP is already claimed elsewhere on the network.

---

## Step 2: Prepare Secrets Configuration

DPN Health Monitoring requires the following Kubernetes secrets to be created for deployment. 

|secret-name| Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
|dpn-nginx-basic-auth| A 16 char length complex password with special characters | Kubernetes Secret using volume mount i.e. kubectl create secret generic <secret-name> --from-file=`<path-to-file>` |
| dpn-mon-storage-connection-string | SAS Token generated on the storage account for Thanos | i.e. kubectl create secret generic <secret-name> --from-file=`<path-to-file>`|

The nginx proxy authentication acts as a basic authentication gateway for the following user interfaces.

- Opensearch
- Jaeger
- Apache Perses
- Kafka-health-UI
- Kafka-UI
- Thanos

> **Keycloak SSO.** OpenSearch, Jaeger, and Perses are additionally served over **HTTPS** through the **DPN Portal**, each fronted by its own `oauth2-proxy` sidecar terminating OIDC login against the DPN Authentication Service (Keycloak). This is now the standard access path for day-to-day use; see [DPN Portal Operations](../../../05-dpn-user-interfaces/08-dpn-portal-ui-operations.md) and [Configure DPN Authentication Service](07-configure-dpn-authentication-service.md).
>
> **Kafka UI authenticates natively, not through `oauth2-proxy`.** Its own oauth2-proxy release has been removed — Kafka UI now runs its own OIDC login directly against the `dpn-realm` realm, with `dpnadmin`/`dpnreader` realm roles mapped to Kafka UI's own RBAC (full access vs. view-only). See [Kafka Health UI Operations](../../../05-dpn-user-interfaces/07-kafka-health-ui-operations.md#3-accessing-the-kafka-ui). Apache Airflow similarly authenticates natively against Keycloak rather than through an `oauth2-proxy` sidecar — see [Configure DPN Data Pipelines](05-configure-dpn-data-pipelines.md).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
