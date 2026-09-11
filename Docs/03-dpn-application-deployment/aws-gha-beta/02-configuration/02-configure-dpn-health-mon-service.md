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

The DPN Health Monitoring Service hosts the observability platform for DPN — Kafka, OpenSearch, an OpenTelemetry Collector, Prometheus+Thanos, Data Prepper, Jaeger, Perses, and an Nginx observability proxy. It is deployed in a separate namespace, `ns-dpn-health-01`, on Amazon EKS.

---

## Continuous Deployment (CD)

Deployment is orchestrated by the `dpn-health-monitoring-cd-install.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`, which chains each sub-component's own CD workflow as a dependent job in this order: Kafka → OpenSearch → Prometheus → Thanos (with Data Prepper and Jaeger branching off Kafka+OpenSearch, Perses off Prometheus+Thanos) → OTel Collector → Nginx Observability Proxy → Validate.

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        ├── dpn-health-monitoring-cd-install.yml   # orchestrator — trigger this one
        └── dpn-cd-{kafka,opensearch,prometheus,thanos,data-prepper,jaeger,perses,otel,nginx-observability,validate}.yml
```

Trigger it via **Actions → DPN Health Monitoring → Run workflow**, supplying `environment` (dev/test), `cluster` (dpn01/dpn02), `cloud` (`aws`), and `imageTag` (OTel Collector image tag, default `0.95.0`) — the orchestrator reads the rest of the component config from `.github/config/aws/<environment>-<cluster>.json` itself and passes it to every job.

**What the pipeline does *not* automate:** the Thanos IRSA IAM role and the Nginx Basic-Auth secret are still one-time manual AWS/Kubernetes setup — no workflow provisions AWS IAM roles or generates that secret. See the [installation guide](../03-installation/02-dpn-monitoring-service-installation-process.md) for the exact commands.

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

Refer to [Step2.2: AWS Environment Configuration](00-common-dpn-configuration.md#step22-aws-environment-configuration) for the per-environment configurations.

In addition to the common keys, this config file requires:

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `THANOS_IRSA_ROLE_ARN` | IAM role ARN for Thanos' S3 access (IRSA) — printed by the Thanos IRSA setup script | `arn:aws:iam::<account-id>:role/dpn-thanos-irsa` |
| `THANOS_S3_BUCKET` | S3 bucket Thanos uses for long-term metrics storage | `<your-bucket>` |

> **Why `THANOS_IRSA_ROLE_ARN`/`THANOS_S3_BUCKET` are required.** Unlike Azure (where Thanos authenticates via the AKS-native identity), the AWS chart values need an explicit IRSA role ARN and S3 bucket name — there's no equivalent auto-discovery. Leaving either unset causes the Thanos sidecar/Query pods to fail on start-up.

---

## Step 2: Prepare Secrets Configuration

DPN Health Monitoring requires the following Kubernetes secrets to be created for deployment.

| secret-name | Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
| dpn-nginx-basic-auth | A 16 char length complex password with special characters | Kubernetes Secret using volume mount i.e. kubectl create secret generic <secret-name> --from-file=`<path-to-file>` |

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
