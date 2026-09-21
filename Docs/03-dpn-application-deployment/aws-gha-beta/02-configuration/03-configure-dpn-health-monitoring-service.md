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

The DPN Health Monitoring Service hosts the observability platform for DPN — Kafka, OpenSearch, an OpenTelemetry Collector, Prometheus+Thanos, Data Prepper, Jaeger, Perses, and the **DPN Portal** tile landing page. It is deployed in a separate namespace, `ns-dpn-health-01`, on Amazon EKS.

> **The Nginx observability proxy has been retired.** `dpn-nginx-observability` (basic-auth reverse proxy in front of OpenSearch/Jaeger/Perses/Kafka UI/Thanos) and its chart/CD workflow have been removed. Its role is now split between the **DPN Portal** (tile landing page, `charts/dpn-portal`) and one **`oauth2-proxy`** Keycloak-gateway release per UI — see [Step 2](#step-2-prepare-secrets-configuration) below.

---

## Continuous Deployment (CD)

Deployment is orchestrated by the `dpn-health-monitoring-cd-install.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`, which chains each sub-component's own CD workflow as a dependent job in this order: Kafka → OpenSearch → Prometheus → Thanos (with Data Prepper and Jaeger branching off Kafka+OpenSearch, Perses off Prometheus+Thanos) → OTel Collector → **DPN Portal** → **OAuth2 Proxy** (OpenSearch → Jaeger → Perses → Portal, chained sequentially) → Validate.

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        ├── dpn-health-monitoring-cd-install.yml   # orchestrator — trigger this one
        └── dpn-cd-{kafka,opensearch,prometheus,thanos,data-prepper,jaeger,perses,otel,portal,oauth2-proxy,validate}.yml
```

Trigger it via **Actions → DPN Health Monitoring → Run workflow**, supplying `environment` (dev/test), `cluster` (dpn01/dpn02), `cloud` (`aws`), `imageTag` (OTel Collector image tag, default `0.95.0`), and **`portalImageTag`** (the DPN Portal container image tag — required, no default; a short git-SHA printed by the DPN Portal application's own CI build) — the orchestrator reads the rest of the component config from `.github/config/aws/<environment>-<cluster>.json` itself and passes it to every job. `otelImageRepository` (the OTel Collector image path after `ghcr.io/energy-dsi/`) is optional — leave it blank to use the environment's configured repository. `portalImageRepository` (the GHCR path after `ghcr.io/energy-dsi/`) defaults to `1.0.1/dpn-portal` if left blank.

> **Prometheus and Thanos no longer sit behind an `oauth2-proxy` gateway.** Neither UI is meant for direct browser access — both are consumed through Perses instead. Their own component jobs still deploy the Prometheus/Thanos Query Services directly onto an internal AWS Network Load Balancer (no login of any kind in front), at the same ports (`9081`/`9091`) their retired `oauth2-proxy` gateways used to publish on. Restrict network access to these ports at the VPC/security-group level accordingly.

**What the pipeline does automate:** `dpn-cd-oauth2-proxy.yml` provisions its own AWS IAM role (IRSA, `dpn-oauth2-proxy-secrets-role`) and its own Secrets Manager copy of the Keycloak client secret on every run — this is idempotent and requires no manual AWS IAM setup.

**What the pipeline does *not* automate:**
- The Keycloak `dpn-service-client` credential must already exist in AWS Secrets Manager, at `dpn/<environment>-<cluster>/keycloak/KC_SERVICE_CLIENT_SECRET` — created by `dpn-keycloak-cd.yml`'s own AWS deploy path, run that first if it hasn't been.
- The `dpn-health-tls` Secret (a `kubernetes.io/tls` Secret holding `tls.crt`, `tls.key` and `ca.crt`) must already exist in `ns-dpn-health-01` — every `oauth2-proxy` release and the OTel Collector's TLS-enabled OTLP receivers consume it, and none of them create it.
- The Kubernetes Secret backing Thanos' long-term object storage (see [Step 1](#step-1-prepare-environment-configuration-file)) — no workflow creates it.
- A DPN Portal container image already built and pushed to GHCR, with its tag known ahead of triggering the workflow — this repository's pipeline deploys that image, it does not build it.

See the [installation guide](../03-installation/03-dpn-health-monitoring-service-installation-process.md) for the exact commands.

---

## Step 1: Prepare Environment Configuration File

Organisations should prepare a config file per environment/cluster where the health monitoring service is deployed, and keep it in the following location. This file will be read by the `init` job of the orchestrator workflow during deployment.

```text
dpn-containerised-deployment-service/
└── .github/
    └── config/
        └── aws/
            └── <environment>-<cluster>.json
```

This config file's keys are the same common ones described in [Step2.2: AWS Environment Configuration](00-common-dpn-configuration.md#step22-aws-environment-configuration) — this service has no health-monitoring-specific keys of its own in that JSON file. Two things beyond the JSON file still need preparing per environment/cluster before deploying:

- **Thanos' long-term object storage.** `charts/prometheus/values/aws/<environment>-<cluster>.yaml` points Thanos' sidecar at `objectStorageConfig.name: dpn-mon-storage-connection-string` — a Kubernetes Secret (key `objstore.yml`) that you must create yourself; no workflow creates it. As currently checked in, this chart reuses the **same Secret name and shape as the Azure path** (an `objstore.yml` blob), rather than an IRSA-scoped ServiceAccount + bucket name — confirm with your platform team which S3 authentication method (static keys inside `objstore.yml`, or IRSA) your organisation intends before relying on this, since no IRSA role or ServiceAccount annotation ships in this chart for Thanos itself.
- **The DPN Portal image.** The orchestrator's `portalImageTag` input (and optionally `portalImageRepository`, default `1.0.1/dpn-portal`) is supplied at trigger time, not read from the JSON config file — see [Continuous Deployment (CD)](#continuous-deployment-cd) above.

> **Image path convention.** This service's own charts (OpenSearch, Prometheus/Thanos/Alertmanager, Perses, OTel Collector, DPN Portal, and the Kafka/Zookeeper/Jaeger images used by its Kafka stack) now reference GHCR under a version-prefixed path, `ghcr.io/energy-dsi/1.0.1/<component>`, rather than the unversioned `ghcr.io/energy-dsi/<component>` path used elsewhere in this repository. See [Reference: Container Images Used](../03-installation/03-dpn-health-monitoring-service-installation-process.md#reference-container-images-used) in the installation guide.

---

## Step 2: Prepare Secrets Configuration

DPN Health Monitoring requires the following Kubernetes secrets/external secrets to be created for deployment. The `dpn-nginx-basic-auth` secret previously required here is **no longer needed** — the Nginx observability proxy it authenticated has been retired.

| secret-name | Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
| dpn-mon-storage-connection-string | Thanos long-term object storage config (`objstore.yml` key) | Kubernetes Secret, created manually — see [Step 1](#step-1-prepare-environment-configuration-file) |
| dpn-health-tls | `kubernetes.io/tls` cert/key/CA used by `oauth2-proxy` and the OTel Collector's TLS OTLP receivers | Kubernetes Secret, created manually (not created by this pipeline) |
| dpn/`<environment>-<cluster>`/keycloak/KC_SERVICE_CLIENT_SECRET | The `dpn-service-client` Keycloak client credential | AWS Secrets Manager secret, created by `dpn-keycloak-cd.yml`'s AWS deploy path — must exist before `dpn-cd-oauth2-proxy.yml` runs |

`dpn-cd-oauth2-proxy.yml` additionally provisions its own AWS IAM role (IRSA) and its own private Secrets Manager copy of the Keycloak client secret automatically on every run — no manual action needed for that part.

> **Keycloak SSO is now the only front door for OpenSearch, Jaeger and Perses.** Each is served over **HTTPS** through its own `oauth2-proxy` release, terminating OIDC login against the DPN Authentication Service (Keycloak) — there is no basic-auth fallback any more. The **DPN Portal** tile landing page is itself also fronted by its own `oauth2-proxy` release (`portal`, port `8443`). See [DPN Portal Operations](../../../05-dpn-user-interfaces/08-dpn-portal-ui-operations.md) and [Configure DPN Authentication Service](07-configure-dpn-authentication-service.md).
>
> **Prometheus and Thanos have no login of any kind in front of them.** Their `oauth2-proxy` gateways have been retired — neither UI is meant for direct browser access (both are consumed through Perses), so their Query/UI Services now publish directly on an internal AWS NLB. Restrict network access to these at the VPC/security-group level; do not expose them beyond the internal network.
>
> **Kafka UI authenticates natively, not through `oauth2-proxy`.** Its own oauth2-proxy release has been removed — Kafka UI now runs its own OIDC login directly against the `dpn-realm` realm, with `dpnadmin`/`dpnreader` realm roles mapped to Kafka UI's own RBAC (full access vs. view-only). See [Kafka Health UI Operations](../../../05-dpn-user-interfaces/07-kafka-health-ui-operations.md#3-accessing-the-kafka-ui). `kafka-ui-2` (ns-dpn-01) and Apache Airflow (`dpn-data-pipelines`) also had their `oauth2-proxy` gateways removed with **no replacement added from this service** — securing/exposing either is now that owning domain's own responsibility; see [Configure DPN Data Pipelines](05-configure-dpn-data-pipelines.md).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
