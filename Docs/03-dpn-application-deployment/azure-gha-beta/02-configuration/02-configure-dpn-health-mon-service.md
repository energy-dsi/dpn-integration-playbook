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

> **The Nginx observability proxy has been retired.** `dpn-nginx-observability` (basic-auth reverse proxy in front of OpenSearch/Jaeger/Perses/Kafka UI/Thanos) and its CD workflow have been removed. Its role is now split between the **DPN Portal** tile landing page (`charts/dpn-portal`) and one **`oauth2-proxy`** Keycloak-gateway release per remaining UI — see [Step 2](#step-2-prepare-secrets-configuration) below.

---

## Continuous Deployment (CD)

DPN Health Monitoring Service is provided in repository `dpn-health-monitoring-service`, with its deployment automation living in `dpn-containerised-deployment-service`.

Every health monitoring component is a third-party Helm chart/image compliant with Apache 2.0, except DPN Portal, which is a DSI-built application deployed from its own image. There is no CI pipeline in this repository for the third-party components. Deployment is orchestrated by the `dpn-health-monitoring-cd-install.yml` GitHub Actions workflow, which chains each component's own CD workflow as a dependent job in this order: Kafka → OpenSearch → Prometheus → Thanos (with Data Prepper and Jaeger branching off Kafka+OpenSearch, Perses off Prometheus+Thanos) → OTel Collector → **DPN Portal** → **OAuth2 Proxy** (OpenSearch → Jaeger → Perses → Portal, chained sequentially) → Validate.

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        ├── dpn-health-monitoring-cd-install.yml   # orchestrator — trigger this one
        └── dpn-cd-{kafka,opensearch,prometheus,thanos,data-prepper,jaeger,perses,otel,dpn-portal,oauth2-proxy,validate}.yml
```

Trigger it via **Actions → DPN Health Monitoring → Run workflow**, supplying `environment` (dev/test), `cluster` (dpn01/dpn02), `cloud` (`azure`), `imageTag` (OTel Collector image tag, default `0.95.0`), and the DPN Portal image coordinates — **`portalImageRepository`** and **`portalImageTag`**, both **required with no default** on this path (this chart has no default image; supply the exact GHCR path after `ghcr.io/energy-dsi/` and the tag) — the orchestrator reads the rest of the component config from `.github/config/azure/<environment>-<cluster>.json` itself and passes it to every job.

> **Prometheus and Thanos no longer sit behind an `oauth2-proxy` gateway.** Neither UI is meant for direct browser access — both are consumed through Perses instead. Their own component jobs still deploy the Prometheus/Thanos Query Services directly onto the namespace's shared internal Azure LoadBalancer (no login of any kind in front), at the same ports (`9081`/`9091`) their retired `oauth2-proxy` gateways used to publish on — pinned via `OBSERVABILITY_LB_IP` (see [Step 1](#step-1-prepare-environment-configuration-file)).

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

DPN Health Monitoring requires the following Kubernetes secrets to be created for deployment. The `dpn-nginx-basic-auth` secret previously required here is **no longer needed** — the Nginx observability proxy it authenticated has been retired.

|secret-name| Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
| dpn-mon-storage-connection-string | SAS Token generated on the storage account for Thanos | i.e. kubectl create secret generic <secret-name> --from-file=`<path-to-file>`|
| dpn-health-tls | `kubernetes.io/tls` cert/key/CA used by `oauth2-proxy` and the OTel Collector's TLS OTLP receivers | Kubernetes Secret, created manually (not created by this pipeline) |

The Keycloak `dpn-service-client` credential itself is sourced from Azure Key Vault (object `KC-SERVICE-CLIENT-SECRET`) via `oauth2-proxy`'s own SecretProviderClass — create it once per environment before the `oauth2-proxy` jobs run; see [Configure DPN Authentication Service](07-configure-dpn-authentication-service.md).

> **Keycloak SSO is now the only front door for OpenSearch, Jaeger and Perses.** Each is served over **HTTPS** through its own `oauth2-proxy` release, terminating OIDC login against the DPN Authentication Service (Keycloak) — there is no basic-auth fallback any more. The **DPN Portal** tile landing page is itself also fronted by its own `oauth2-proxy` release (`portal`, port `8443`). See [DPN Portal Operations](../../../05-dpn-user-interfaces/08-dpn-portal-ui-operations.md) and [Configure DPN Authentication Service](07-configure-dpn-authentication-service.md).
>
> **Prometheus and Thanos have no login of any kind in front of them.** Their `oauth2-proxy` gateways have been retired — neither UI is meant for direct browser access (both are consumed through Perses), so their Query/UI Services now publish directly on the namespace's shared internal Azure LoadBalancer. Restrict network access to these at the network-security-group level; do not expose them beyond the internal network.
>
> **Kafka UI authenticates natively, not through `oauth2-proxy`.** Its own oauth2-proxy release has been removed — Kafka UI now runs its own OIDC login directly against the `dpn-realm` realm, with `dpnadmin`/`dpnreader` realm roles mapped to Kafka UI's own RBAC (full access vs. view-only); as of this writing that native OIDC/RBAC login is only actually enabled on `dev-dpn01` — check `charts/kafka-stack/values/azure/*.yaml` for the current per-cluster state. See [Kafka Health UI Operations](../../../05-dpn-user-interfaces/07-kafka-health-ui-operations.md#3-accessing-the-kafka-ui). `kafka-ui-2` (ns-dpn-01) had its `oauth2-proxy` gateway removed with no replacement added from this service; Apache Airflow now handles its own login directly, the same way it always authenticated users before its gateway existed — see [Configure DPN Data Pipelines](05-configure-dpn-data-pipelines.md).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
