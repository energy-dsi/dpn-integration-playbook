# DPN Monitoring Service Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Steps](#installation-steps)
  - [Step1: Run `dpn-health-monitoring-cd-install.yml`](#step1-run-dpn-health-monitoring-cd-installyml)
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

This describes installation using the GitHub Actions orchestrator workflow `dpn-health-monitoring-cd-install.yml` (`environment`+`cluster`+`cloud` inputs, an 11-job dependency chain — Kafka → OpenSearch → Prometheus → Thanos, with Data Prepper/Jaeger off Kafka+OpenSearch and Perses off Prometheus+Thanos, then OTel → Nginx Observability Proxy → Validate — plus the OTEL Collector HPA) against your airgapped AWS environments — `dev`/`test`, each with up to two DPN clusters (`dpn01`/`dpn02`).

## Prerequisites

- An EKS cluster matching the target environment's config, with `ns-dpn-health-01` already created.
- Completed [GitHub Actions Configuration](../02-configuration/00-common-dpn-configuration.md#step2-github-actions-configuration) for the target environment.
- The Thanos IRSA IAM role created (see [Configure DPN Health Monitoring Service, Step 1](../02-configuration/02-configure-dpn-health-mon-service.md#step-1-prepare-environment-configuration-file)) — no workflow provisions this.
- Access to the environment-specific container registry for Kafka/Zookeeper images, and to Docker Hub/Quay.io for everything else.
- A required-reviewer rule on the GitHub Environment (`<environment>-<cluster>`) if you want a manual approval gate before deployment — there is no ADO-style environment approval built into the workflow itself.
- A **freshly generated** Nginx Basic-Auth secret for the dashboard proxy — do not reuse anything currently committed elsewhere; no workflow generates this either.
- The real Thanos S3 bucket name for the target environment.
- SMTP relay details and an alert recipient address.
- The metrics-server running in the cluster (install the `metrics-server` EKS add-on) — required for the OTEL Collector's HPA.

---

## Installation Steps

### Step1: Run `dpn-health-monitoring-cd-install.yml`

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

Go to **Actions → DPN Health Monitoring → Run workflow** in `dpn-containerised-deployment-service`, on the branch you want to deploy, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` (DSI provides two dpn configurations per environment — organisations may keep only one, e.g. `dpn01`, to run a single DPN cluster) |
| `cloud` | `aws` |
| `imageTag` | OTel Collector image tag — default `0.95.0` |

The workflow's `init` job reads `.github/config/aws/<environment>-<cluster>.json`, then every component job (Kafka, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, OTel, Nginx Observability Proxy, Validate) runs in dependency order automatically — there's a single workflow to trigger, not a separate one per component. Before running it, confirm:

- The container image repository referred to in each chart's values is correct, unless the organisation plans to use a different image repository
- The config JSON's environment fields point to the correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required firewall rules are applied

---

### Step2: Post Deployment Verification

1. Confirm all pods `Running`.
2. Confirm the init pods completed the job
2. Confirm resource labels reflect the correct environment name 

**Note: The nginx pod may appear in error state initially as it also grants access to kafka-ui under federator service. Once federator service is up, the nginx will automatically be in run state. If not then the issue to be investigated.

---

## Step3: Troubleshooting

Every troubleshooting entry (Kafka naming-regression checks in `dpn-cd-kafka.yml`, the OTel→Kafka dependency check, CrashLoop from a missing `health_check` extension, HPA `<unknown>` targets) applies unchanged, since it's chart-level logic. Additional entries specific to this reconciliation:

### Config File Not Found for Specific Environment

Confirm `.github/config/aws/<environment>-<cluster>.json` actually exists under this exact naming — populate it before running the workflow (see [GitHub Actions Configuration](../02-configuration/00-common-dpn-configuration.md#step22-aws-environment-configuration)).

### Deployed Resources Show the Wrong Environment Label

Confirm the config JSON used the **corrected** environment values for this run.

### Kafka/Zookeeper Image Pull Fails

Confirm `IMAGE_REGISTRY` in `.github/config/aws/<environment>-<cluster>.json` uses a fully-resolved hostname like `ghcr.io` (or your own ECR repository URL), not a bare placeholder.

---

## Reference: Container Images Used

This section lists the **custom and 3rd party open source container images** published by DSI to `ghcr.io/energy-dsi` that the workflow deploys. Organisations may point the Helm values at a different image repository instead if they build their own.

The Health Monitoring service 3rd party platform images are found in GHCR with following names

| Purpose | GHCR Path |
|---|---|
| OTel Collector | `ghcr.io/energy-dsi/opentelemetry-collector-contrib:<latest or DSI provided stable version>` |
| Kafka (health) | `ghcr.io/energy-dsi/dpn-kafka:<latest or DSI provided stable version>` |
| Zookeeper (health) | `ghcr.io/energy-dsi/dpn-zookeeper:<latest or DSI provided stable version>` |
| Data Prepper | `ghcr.io/energy-dsi/data-prepper:<latest or DSI provided stable version>` |
| OpenSearch | `ghcr.io/energy-dsi/opensearch:<latest or DSI provided stable version>` |
| Jaeger Collector | `ghcr.io/energy-dsi/jaeger-collector:<latest or DSI provided stable version>` |
| Jaeger Ingester | `ghcr.io/energy-dsi/jaeger-ingester:<latest or DSI provided stable version>` |
| Jaeger Query | `ghcr.io/energy-dsi/jaeger-query:<latest or DSI provided stable version>` |
| Prometheus | `ghcr.io/energy-dsi/prometheus:<latest or DSI provided stable version>` |
| Grafana | `ghcr.io/energy-dsi/grafana:<latest or DSI provided stable version>` |
| StatsD Exporter | `ghcr.io/energy-dsi/statsd-exporter:<latest or DSI provided stable version>` |
| Perses | `ghcr.io/energy-dsi/perses:<latest or DSI provided stable version>` |
| Nginx (dashboard proxy) | `ghcr.io/energy-dsi/nginx:<latest or DSI provided stable version>` |

 **Note:** The health monitoring stack deploys its own dedicated Kafka and Zookeeper instances within `ns-dpn-health-01`. These are separate from the DPN data Kafka in `ns-dpn-01` and run on different ports. Image access, pull verification, and the workflow trigger are all covered above in [Step1](#step1-run-dpn-health-monitoring-cd-installyml) — there is no separate GHCR-specific workflow to run, the one workflow already deploys from these GHCR images by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
