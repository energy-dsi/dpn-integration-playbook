# DPN Monitoring Service Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Steps](#installation-steps)
  - [Step1: Run `dpn-gha-health-monitoring-cd-install.yml`](#step1-run-dpn-health-monitoring-cd-installyml)
    - [Step1a: Configure GHCR Image Access](#step1a-configure-ghcr-image-access)
    - [Step1b: Trigger the Workflow](#step1b-trigger-the-workflow)
  - [Step2: Post Deployment Verification](#step2-post-deployment-verification)
- [Step3: Troubleshooting](#step3-troubleshooting)
  - [Config File Not Found for Specific Environment](#config-file-not-found-for-specific-environment)
  - [Deployed Resources Show the Wrong Environment Label](#deployed-resources-show-the-wrong-environment-label)
  - [Kafka/Zookeeper Image Pull Fails](#kafkazookeeper-image-pull-fails)
- [Reference: Container Images Used](#reference-container-images-used)
- [Review Notes](#review-notes)

---

## Overview

This describes installation using the GitHub Actions orchestrator workflow `dpn-gha-health-monitoring-cd-install.yml` (display name **DPN Health Monitoring**, in `.github/workflows/` of the central `dpn-containerised-deployment-service` repository) (`environment`+`cluster`+`cloud` inputs, a dependency chain — Kafka → OpenSearch → Prometheus → Thanos, with Data Prepper/Jaeger off Kafka+OpenSearch and Perses off Prometheus+Thanos, then OTel → **DPN Portal** → **OAuth2 Proxy** (OpenSearch → Jaeger → Perses → Portal) → Validate — plus the OTEL Collector HPA) against your AWS environments — `dev`/`test`, each with up to two DPN clusters (`dpn01`/`dpn02`).

> The Nginx Observability Proxy job has been retired; DPN Portal (tile landing page) and one `oauth2-proxy` Keycloak-gateway release per remaining UI (OpenSearch, Jaeger, Perses, Portal) replace it. Prometheus and Thanos publish directly on an internal AWS NLB with no gateway at all — see [Configuration, Continuous Deployment (CD)](../02-configuration/03-configure-dpn-health-monitoring-service.md#continuous-deployment-cd).

## Prerequisites

- An EKS cluster matching the target environment's config, with `ns-dpn-health-01` already created.
- Completed [GitHub Actions Configuration](../02-configuration/00-common-dpn-configuration.md#step2-github-actions-configuration) for the target environment.
- The Kubernetes Secret backing Thanos' long-term object storage (`dpn-mon-storage-connection-string`, key `objstore.yml`) created in `ns-dpn-health-01` — no workflow creates it; see [Configure DPN Health Monitoring Service, Step 1](../02-configuration/03-configure-dpn-health-monitoring-service.md#step-1-prepare-environment-configuration-file) for the caveat on what mechanism (static keys vs. IRSA) it should actually encode.
- The `dpn-health-tls` Secret (`kubernetes.io/tls`, with `tls.crt`/`tls.key`/`ca.crt`) already present in `ns-dpn-health-01` — consumed by every `oauth2-proxy` release and the OTel Collector's TLS OTLP receivers.
- The Keycloak `dpn-service-client` credential already present in AWS Secrets Manager at `dpn/<environment>-<cluster>/keycloak/KC_SERVICE_CLIENT_SECRET` (created by `dpn-gha-keycloak-cd.yml`'s AWS deploy path) — `dpn-gha-cd-oauth2-proxy.yml` provisions its own IRSA role and its own private copy of this secret automatically, but the underlying Keycloak-side secret has to exist first.
- A DPN Portal container image already built and pushed to GHCR, with its tag (a short git-SHA) ready to supply as the workflow's `portalImageTag` input.
- Access to the environment-specific container registry for Kafka/Zookeeper images, and to Docker Hub/Quay.io for everything else.
- A required-reviewer rule on the GitHub Environment (`<environment>-<cluster>`) if you want a manual approval gate before deployment — there is no ADO-style environment approval built into the workflow itself.
- SMTP relay details and an alert recipient address.
- The metrics-server running in the cluster (install the `metrics-server` EKS add-on) — required for the OTEL Collector's HPA.

---

## Installation Steps

### Step1: Run `dpn-gha-health-monitoring-cd-install.yml`

#### Step1a: Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`. Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably — unauthenticated pulls are subject to strict rate limits and may fail in automated environments.

Create a GitHub Personal Access Token with `read:packages` scope, then create a Kubernetes secret from it (used during image pull):

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

See [Reference: Container Images Used](#reference-container-images-used) below for the full image list, and use `kubectl run ... --image=ghcr.io/energy-dsi/<image>:<version>` to verify pull capability if needed.

#### Step1b: Trigger the Workflow

Go to **Actions → DPN Health Monitoring → Run workflow** , on the branch you want to deploy, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02`, default `dpn01` (DSI provides two dpn configurations per environment — organisations may keep only one, e.g. `dpn01`, to run a single DPN cluster) |
| `cloud` | `aws` (default; the input also lists other clouds, which are out of scope for this guide) |
| `imageTag` | OTel Collector image tag — default `0.95.0` |
| `otelImageRepository` | OTel Collector image path after `ghcr.io/energy-dsi/` — optional, leave blank to use the environment's configured repository |
| `portalImageTag` | DPN Portal container image tag — **required**, no default (the short git-SHA the DPN Portal application's own CI build printed) |
| `portalImageRepository` | DPN Portal GHCR path after `ghcr.io/energy-dsi/` — optional, defaults to `1.0.1/dpn-portal` |

The workflow's `init` job (**Resolve Deployment Config**) reads `.github/config/aws/<environment>-<cluster>.json`, then every component job (Kafka, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, OTel, DPN Portal, OAuth2 Proxy ×4, Validate) runs in dependency order automatically — there's a single workflow to trigger, not a separate one per component. Before running it, confirm:

- The container image repository referred to in each chart's values (`dpn-health-monitoring/charts/<chart>/values/aws/<environment>-<cluster>.yaml`) is correct, unless the organisation plans to use a different image repository
- The config JSON's environment fields point to the correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required firewall rules are applied

---

### Step2: Post Deployment Verification

1. Confirm all pods `Running`.
2. Confirm the init pods completed the job
2. Confirm resource labels reflect the correct environment name 

**Note:** the `oauth2-proxy-portal` release depends on the DPN Portal Deployment being ready, which in turn depends on the backend UIs (OpenSearch, Jaeger, Perses) it links to. If it comes up before the Kafka UI federator-side services are ready, its tile health probes may briefly report an unhealthy tile — this resolves on its own once those backends are up; investigate only if it persists.

To roll back or remove this service, use `dpn-rollback-health-monitoring.yml` (**DPN Rollback - Health Monitoring**) or `dpn-uninstall-health-monitoring.yml` (**DPN Uninstall - Health Monitoring**) — see [Rollback Procedures](../04-rollback/04-rollback-procedures.md) and [Uninstall and Decommissioning](../05-uninstall/05-uninstall-decommissioning.md).

---

## Step3: Troubleshooting

Every troubleshooting entry (Kafka naming-regression checks in `dpn-gha-cd-kafka.yml`, the OTel→Kafka dependency check, CrashLoop from a missing `health_check` extension, HPA `<unknown>` targets) applies unchanged, since it's chart-level logic. Additional entries specific to this reconciliation:

### Config File Not Found for Specific Environment

Confirm `.github/config/aws/<environment>-<cluster>.json` actually exists under this exact naming — populate it before running the workflow (see [GitHub Actions Configuration](../02-configuration/00-common-dpn-configuration.md#step22-aws-environment-configuration)).

### Deployed Resources Show the Wrong Environment Label

Confirm the config JSON used the **corrected** environment values for this run.

### Kafka/Zookeeper Image Pull Fails

Confirm the `kafka.image.repository` / `zookeeper.image.repository` entries in `dpn-health-monitoring/charts/kafka-stack/values/aws/<environment>-<cluster>.yaml` use a fully-resolved registry path like `ghcr.io/energy-dsi/1.0.1/dpn-kafka` (or your own ECR repository URL), not a bare placeholder. `dpn-gha-cd-kafka.yml` takes the image from this values file — the `IMAGE_REGISTRY` key in `.github/config/aws/<environment>-<cluster>.json` is not passed to the health monitoring workflows.

### OTel Collector Metrics Never Show Up in Prometheus

The OTel Collector's `prometheusremotewrite/metrics` exporter posts to Prometheus' `dpn-prometheus-health-ui` Service on port `9081` (the externally-published port, not Prometheus' own `9090`). If Prometheus was deployed without `enableRemoteWriteReceiver: true` in its values, every remote-write POST 404s; if the Service/port in the collector's config drifts from the one Prometheus actually publishes on for a given environment, every write instead times out. Confirm both match for the environment you deployed.

### DPN Portal Pod Fails to Pull Image

`dpn-health-monitoring/charts/dpn-portal/values.yaml` ships no default `image.repository`/`image.tag` — the chart deliberately fails to render rather than guessing a registry path. Confirm `portalImageTag` (and, if overridden, `portalImageRepository`) were actually supplied when the workflow was triggered.

---

## Reference: Container Images Used

This section lists the **custom and 3rd party open source container images** published by DSI to `ghcr.io/energy-dsi` that the workflow deploys. Organisations may point the Helm values at a different image repository instead if they build their own.

The Health Monitoring service 3rd party platform images are found in GHCR with following names. **On this AWS path, this service's own chart images are referenced under a version-prefixed GHCR path, `ghcr.io/energy-dsi/1.0.1/<component>`** (rather than the unversioned `ghcr.io/energy-dsi/<component>` path used elsewhere) — confirm the `1.0.1` segment is still current before relying on it for a new environment.

| Purpose | GHCR Path |
|---|---|
| OTel Collector | `ghcr.io/energy-dsi/1.0.1/opentelemetry-collector-contrib:<latest or DSI provided stable version>` |
| Kafka (health) | `ghcr.io/energy-dsi/1.0.1/dpn-kafka:<latest or DSI provided stable version>` |
| Zookeeper (health) | `ghcr.io/energy-dsi/1.0.1/dpn-zookeeper:<latest or DSI provided stable version>` |
| Data Prepper | `ghcr.io/energy-dsi/1.0.1/data-prepper:<latest or DSI provided stable version>` |
| OpenSearch | `ghcr.io/energy-dsi/1.0.1/opensearch:<latest or DSI provided stable version>` |
| Jaeger Collector | `ghcr.io/energy-dsi/1.0.1/jaeger-collector:<latest or DSI provided stable version>` |
| Jaeger Ingester | `ghcr.io/energy-dsi/1.0.1/jaeger-ingester:<latest or DSI provided stable version>` |
| Jaeger Query | `ghcr.io/energy-dsi/1.0.1/jaeger-query:<latest or DSI provided stable version>` |
| Prometheus | `ghcr.io/energy-dsi/1.0.1/prometheus:<latest or DSI provided stable version>` |
| Grafana | `ghcr.io/energy-dsi/grafana:<latest or DSI provided stable version>` |
| StatsD Exporter | `ghcr.io/energy-dsi/statsd-exporter:<latest or DSI provided stable version>` |
| Perses | `ghcr.io/energy-dsi/1.0.1/perses:<latest or DSI provided stable version>` |
| Thanos | `ghcr.io/energy-dsi/1.0.1/thanos:<latest or DSI provided stable version>` |
| DPN Portal | `ghcr.io/energy-dsi/1.0.1/dpn-portal:<tag supplied via portalImageTag>` |

> **Nginx (dashboard proxy) has been removed** from this service — replaced by the DPN Portal + `oauth2-proxy` releases above.

 **Note:** The health monitoring stack deploys its own dedicated Kafka and Zookeeper instances within `ns-dpn-health-01`. These are separate from the DPN data Kafka in `ns-dpn-01` and run on different ports. Image access, pull verification, and the workflow trigger are all covered above in [Step1](#step1-run-dpn-health-monitoring-cd-installyml) — there is no separate GHCR-specific workflow to run, the one workflow already deploys from these GHCR images by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
