Release : 2.1.0 - Oct 2026

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

Access to the UIs is role-based. Two Keycloak realm roles are used: `dpnadmin` (view and edit) and `dpnreader` (view only). Users must be created with the relevant role to access the UI components.

> **The Nginx observability proxy has been retired.** `dpn-nginx-observability` (basic-auth reverse proxy in front of OpenSearch/Jaeger/Perses/Kafka UI/Thanos) and its chart/CD workflow have been removed. Its role is now split between the **DPN Portal** (tile landing page, `charts/dpn-portal`) and one **`oauth2-proxy`** Keycloak-gateway release per UI — see [Step 2](#step-2-prepare-secrets-configuration) below.

---

## Continuous Deployment (CD)

Deployment is orchestrated by the `dpn-gha-health-monitoring-cd-install.yml` GitHub Actions workflow, which chains each sub-component's own CD workflow as a dependent job in this order: Kafka → OpenSearch → Prometheus → Thanos (with Data Prepper and Jaeger branching off Kafka+OpenSearch, Perses off Prometheus+Thanos) → OTel Collector → **DPN Portal** → **OAuth2 Proxy** (OpenSearch → Jaeger → Perses → Portal, chained sequentially) → Validate.

```text
root/
└── .pipelines/
    └── github-actions-pipelines/
        └── workflows/
            ├── dpn-gha-health-monitoring-cd-install.yaml
            ├── dpn-gha-kafka-cd.yaml
            ├── dpn-gha-opensearch-cd.yaml
            ├── dpn-gha-prometheus-cd.yaml
            ├── dpn-gha-thanos-cd.yaml
            ├── dpn-gha-data-prepper-cd.yaml
            ├── dpn-gha-jaeger-cd.yaml
            ├── dpn-gha-perses-cd.yaml
            ├── dpn-gha-otel-cd.yaml
            ├── dpn-gha-portal-cd.yaml
            └── dpn-gha-oauth2-proxy-cd.yaml
```

### Stage order

`dpn-gha-health-monitoring-cd-install.yaml` runs the following jobs. Each job depends on those listed against it.

| # | Job | Depends on |
|---|-----|------------|
| 1 | Init (resolve deployment config) | — |
| 2 | Kafka | Init |
| 3 | OpenSearch | Kafka |
| 4 | Prometheus | OpenSearch |
| 5 | Thanos | Prometheus |
| 6 | Data Prepper | Kafka, OpenSearch |
| 7 | Jaeger | Kafka, OpenSearch |
| 8 | Perses | Prometheus, Thanos |
| 9 | OTel Collector | Kafka, OpenSearch, Data Prepper, Jaeger |
| 10 | DPN Portal | Init |
| 11 | OAuth2 Proxy — OpenSearch | OpenSearch |
| 12 | OAuth2 Proxy — Jaeger | Jaeger, OAuth2 Proxy — OpenSearch |
| 13 | OAuth2 Proxy — Perses | Perses, OAuth2 Proxy — Jaeger |
| 14 | OAuth2 Proxy — Portal | DPN Portal, OAuth2 Proxy — Perses |
| 15 | Validate | OTel Collector, Perses, Thanos, Data Prepper, Jaeger, OAuth2 Proxy — Portal |

The oauth2-proxy releases are chained one after another rather than run in parallel. The GitHub Environment bound to each job (e.g. `dev-dpn01`) provides the authorisation.

Trigger it via **Actions → DPN Health Monitoring → Run workflow**, supplying `environment`, `cluster` (dpn01/dpn02), `cloud` (`aws`), `imageTag` (OTel Collector image tag, default `0.95.0`), and **`portalImageTag`** (the DPN Portal container image tag from GHCR repository). `portalImageTag` has no default. Two optional inputs override image paths (relative to `ghcr.io/energy-dsi/`): `otelImageRepository` (blank uses the environment's configured repository) and `portalImageRepository` (default `1.0.1/dpn-portal`).


**What the pipeline does automate:** 

`dpn-gha-oauth2-proxy-cd.yaml` provisions its own AWS IAM role (IRSA, `dpn-oauth2-proxy-secrets-role`) and its own Secrets Manager copy of the Keycloak client secret on every run — this is idempotent and requires no manual AWS IAM setup.

**What the pipeline does *not* automate:**

- The Keycloak `dpn-service-client` credential must already exist in AWS Secrets Manager, at `dpn/<environment>-<cluster>/keycloak/KC_SERVICE_CLIENT_SECRET` — created by `dpn-keycloak-cd.yml`'s own AWS deploy path, run that first if it hasn't been.

- The `dpn-health-tls` Secret (a `kubernetes.io/tls` Secret holding `tls.crt`, `tls.key` and `ca.crt`) must already exist in `ns-dpn-health-01` — every `oauth2-proxy` release and the OTel Collector's TLS-enabled OTLP receivers consume it, and none of them create it.

- The Kubernetes Secret backing Thanos' long-term object storage (see [Step 1](#step-1-prepare-environment-configuration-file)) — no workflow creates it.

- A DPN Portal container image already built and pushed to GHCR, with its tag known ahead of triggering the workflow — this repository's pipeline deploys that image, it does not build it. The DPN Portal (`app/dpn-portal`) is the one component built from source, by the separate `dpn-portal-ci.yaml` pipeline (Checkmarx, FOSSA, unit tests, SonarQube, then build, push, Cosign signing and JFrog X-Ray scan). The deployer must supply the short git SHA that its `BuildAndPush` stage prints as `portalImageTag`.

- The `tls-auth-secret` Secret (holding `KEYSTORE_PASSWORD`, `TRUSTSTORE_PASSWORD` and `DPN_CLIENT_P12_PASSWORD`) must already exist in `ns-dpn-health-01` — the Kafka and Data Prepper charts read it unconditionally, and no workflow here creates it.

- The GHCR image pull secret `ghcr-pull-secret` must already exist in `ns-dpn-health-01` — the AWS values files reference it for the OpenSearch, Kafka stack and DPN Portal images pulled from `ghcr.io/energy-dsi`.

See the [installation guide](../03-installation/03-dpn-health-monitoring-service-installation-process.md) for the exact commands.

---

## Step 1: Prepare Environment Configuration File

Organisations should prepare a config file per environment/cluster where the health monitoring service is deployed, and keep it in the following location. This file will be read by the `init` job of the orchestrator workflow during deployment.

```text
root/
└── .pipelines/
    └── github-actions-pipelines/
        └── config/
            └── aws/
                └── <environment>-<cluster>.json
```

This config file's keys are the same common ones described in [Step2.2: AWS Environment Configuration](00-common-dpn-configuration.md#step22-aws-environment-configuration) — this service has no health-monitoring-specific keys of its own in that JSON file. Two things beyond the JSON file still need preparing per environment/cluster before deploying:

- **Thanos' long-term object storage.** 

    `charts/prometheus/values/aws/<environment>-<cluster>.yaml` points Thanos' sidecar at `objectStorageConfig.name: dpn-mon-storage-connection-string` — a Kubernetes Secret (key `objstore.yml`) that you must create yourself; no workflow creates it.

    As currently checked in, this chart reuses the **same Secret name and shape as the Azure path** (an `objstore.yml` blob), rather than an IRSA-scoped ServiceAccount + bucket name — confirm with your platform team which S3 authentication method (static keys inside `objstore.yml`, or IRSA) your organisation intends before relying on this, since no IRSA role or ServiceAccount annotation ships in this chart for Thanos itself.

- **The DPN Portal image.** 

    The orchestrator's `portalImageTag` input (and optionally `portalImageRepository`) is supplied at trigger time, not read from the JSON config file — see [Continuous Deployment (CD)](#continuous-deployment-cd) above.

    **Image path convention.** 
    
    This service's own charts (OpenSearch, Prometheus/Thanos/Alertmanager, Perses, OTel Collector, DPN Portal, and the Kafka/Zookeeper/Jaeger images used by its Kafka stack) reference `ghcr.io/energy-dsi/<component>` path. See [Reference: Container Images Used](../03-installation/03-dpn-health-monitoring-service-installation-process.md#reference-container-images-used) in the installation guide.

---

## Step 2: Prepare Secrets Configuration

DPN Health Monitoring requires the following Kubernetes secrets/external secrets to be created for deployment. The `dpn-nginx-basic-auth` secret previously required here is **no longer needed** — the Nginx observability proxy it authenticated has been retired.

| secret-name | Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
| dpn-mon-storage-connection-string | Thanos long-term object storage config (`objstore.yml` key) | Kubernetes Secret, created manually — see [Step 1](#step-1-prepare-environment-configuration-file) |
| tls-auth-secret | `KEYSTORE_PASSWORD`, `TRUSTSTORE_PASSWORD` and `DPN_CLIENT_P12_PASSWORD`, read by the Kafka stack and Data Prepper | Kubernetes Secret, must exist in `ns-dpn-health-01` before deployment (not created by this pipeline) |
| dpn-health-tls | `kubernetes.io/tls` cert/key/CA used by `oauth2-proxy`, Kafka UI's own TLS termination and the OTel Collector's TLS OTLP receivers | Kubernetes Secret, created manually (not created by this pipeline) |
| ghcr-pull-secret | Image pull credential for `ghcr.io/energy-dsi` (GitHub username and a Personal Access Token with `read:packages` scope) | Kubernetes `docker-registry` Secret, created manually in `ns-dpn-health-01` |
| dpn/`<environment>-<cluster>`/keycloak/KC_SERVICE_CLIENT_SECRET | The `dpn-service-client` Keycloak client credential | AWS Secrets Manager secret, created by `dpn-keycloak-cd.yml`'s AWS deploy path — must exist before `dpn-cd-oauth2-proxy.yml` runs |

`dpn-cd-oauth2-proxy.yml` additionally provisions its own AWS IAM role (IRSA) and its own private Secrets Manager copy of the Keycloak client secret automatically on every run — no manual action needed for that part.

**Access model, by UI:**

- **OpenSearch Dashboards, Jaeger, Perses, and the DPN Portal** are each fronted by their own `oauth2-proxy` release, terminating OIDC login against the DPN Authentication Service (Keycloak). The Authentication Service must be deployed first and the callbacks for each gateway registered on its Keycloak client, otherwise the final Validate job fails on a fresh environment. The final Validate job confirms each of these four gateways has a ready replica and a load-balancer address.
- **Kafka UI** has no `oauth2-proxy` gateway and terminates its own TLS using the `dpn-health-tls` Secret. On the AWS values files checked in, its native Keycloak OIDC login (`kafkaUi.oidcRbac`) is **not** enabled, so Kafka UI is TLS-terminated but has no login in front of it; confirm with your platform team whether that is acceptable for your environment.
- **`kafka-ui-2`** has no gateway in this repository. It fronted a UI in `ns-dpn-01` that this repository does not own.
- **Apache Airflow** is not part of the Health Monitoring service and has no `oauth2-proxy` gateway here. The DPN Portal tile that previously linked to Airflow now links to the Data Product Management self-service portal.
- **Prometheus and Thanos** have no login gateway of any kind — neither needs direct browser access; both are consumed through the Perses dashboards instead.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
| Oct-2026 | DSI Assurance | Final | V2.1.0 |
