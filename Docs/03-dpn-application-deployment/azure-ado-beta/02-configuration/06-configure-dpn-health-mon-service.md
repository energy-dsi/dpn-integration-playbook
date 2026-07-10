# DPN Deployment Configuration Guide

---

## Table of Contents

- [Overview](#overview)
  - [Continuous Integration (CI)](#continuous-integration-ci)
  - [Continuous Deployment (CD)](#continuous-deployment-cd)

- [Global / Generic Configuration](#global--generic-configuration)
  - [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration)
  - [Azure DevOps Configuration](#azure-devops-configuration)
    - [Node Pool Set Up](#node-pool-set-up)
    - [Azure Environment Configuration](#azure-environment-configuration)
    - [Environment-Specific Approval Gates](#environment-specific-approval-gates)
  - [Secrets Configuration (Global)](#secrets-configuration-global)
  - [Network and Ports Configuration](#network-and-ports-configuration)

- [Container Image Configuration](#container-image-configuration)
  - [Ingestion](#ingestion)
  - [Metrics Stack](#metrics-stack)
  - [Log Stack](#log-stack)
  - [Trace Stack](#trace-stack)
  - [Dashboard Access](#dashboard-access)
  - [Build-Time / Init Containers](#build-time--init-containers)
  - [Image Pull Configuration](#image-pull-configuration)
  - [Known Issues](#known-issues)

- [DPN Health Monitoring Service Configuration](#dpn-health-monitoring-service-configuration)
  - [Introduction and Purpose](#introduction-and-purpose)
  - [Data Flow](#data-flow)
  - [Helm Configuration](#helm-configuration)
    - [Required Components](#required-components)
  - [Horizontal Pod Autoscaler (HPA) Configuration](#horizontal-pod-autoscaler-hpa-configuration)
  - [Alerting Configuration](#alerting-configuration)
  - [Secrets Configuration](#secrets-configuration)

- [Sentinel Integration (WIP)](#sentinel-integration-wip)
- [Review Notes](#review-notes)

---

# Overview

The DPN Health Monitoring Service hosts the observability platform for DPN — an OTEL Collector plus three independent storage/dashboard stacks (metrics, logs, traces) — deployed into a dedicated `ns-dpn-health-01` namespace.

DPN components on Azure are deployed using **Azure DevOps (ADO) pipelines**. These pipelines are organised into two stages:

- **Continuous Integration (CI)**
- **Continuous Deployment (CD)**

Deployment is **fully containerised**, and unusually for a DPN repository, **entirely third-party** — there is no custom application code to build; every component is an existing open-source or Azure-native product, each mirrored into GHCR with its own pinned upstream version tag (see [Container Image Configuration](#container-image-configuration)).

---

## Continuous Integration (CI)

No custom application code is implied by the architecture diagram. A CI pipeline for this repository, if one exists at all, is expected to perform **image mirroring** rather than a source build:

1. Pull each third-party image from its origin registry (Docker Hub, Quay.io, `registry.k8s.io`, etc.) at the pinned version.
2. Re-tag and push it to `ghcr.io/energy-dsi/<name>:<version>`.
3. Keep the **version tag identical** to the upstream source — DSI's own `1.0.0`-style semantic versioning is not applied here, since these aren't DSI-authored artefacts.

---

## Continuous Deployment (CD)

Once built, the CD pipeline is expected to deploy each stack to **Azure Kubernetes Service (AKS)** using Helm:

1. Authenticate with Azure using the configured service connection.
2. Retrieve credentials for the target AKS cluster.
3. Validate each Helm chart using `helm lint`.
4. Perform a Helm **dry-run** validation.
5. **Wait for environment approval**, where configured — see [Environment-Specific Approval Gates](#environment-specific-approval-gates).
6. Deploy the observability stack using Helm, pulling every image from GHCR per [Container Image Configuration](#container-image-configuration).
7. Verify deployment status using Kubernetes rollout checks, including any configured Horizontal Pod Autoscalers — see [Horizontal Pod Autoscaler (HPA) Configuration](#horizontal-pod-autoscaler-hpa-configuration).

---

# Global / Generic Configuration

## DSI DSM Endpoint Configuration

DSI provides predefined endpoints to support the following environments:

- Development
- Integration Testing
- Pre-Production
- Production

These endpoints are publicly accessible to simplify integration and testing. Organisations must configure their pipelines to use the **appropriate endpoint for the corresponding deployment environment** as provided by DSI.

| Environment | Component | URL |
|-------------|-----------|-----|
| Pre Production-Dev | Authentication | https://auth-mtls.dsm01.dsipreprod1.neso.energy |
| Pre Production-Dev | Management Node | https://management.dsm01.dsipreprod1.neso.energy |
| Pre Production-Dev | DSI DPN Producer | https://producer.dpn01.dsipreprod1.neso.energy |
| Pre Production-Test | Authentication | https://auth-mtls.dsm01.dsipreprod2.neso.energy |
| Pre Production-Test | Management Node | https://management.dsm01.dsipreprod2.neso.energy |
| Pre Production-Test | DSI DPN Producer | https://producer.dpn01.dsipreprod2.neso.energy |
| Pre-Production-Uat | Authentication | https://auth-mtls.dsm01.dsipreprod3.neso.energy |
| Pre-Production-Uat | Management Node | https://management.dsm01.dsipreprod3.neso.energy |
| Pre-Production-Uat | DSI DPN Producer | https://producer.dpn01.dsipreprod3.neso.energy |

---

## Azure DevOps Configuration

The provided pipelines require the following configuration to perform **CI and CD operations**.

### Node Pool Set Up

The provided pipelines are configured with the default Microsoft-hosted agent pool `ubuntu-latest` for pipeline execution.

However, DSI **recommends using a dedicated self-hosted agent pool**, which provides better control over:

- Security
- Network access
- Deployment environment management

Refer to the official Microsoft documentation for Linux node pool agent setup:
https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent

If a self-hosted agent pool is configured, update the pipeline definition as follows.

#### Existing Configuration

```yaml
pool:
  vmImage: 'ubuntu-latest'
```

#### Updated Configuration

```yaml
pool:
  name: '[agent-pool-name]'
```

---

### Azure Environment Configuration

For the pipelines to run, the following parameters must be updated in the environment-specific JSON configuration file located under the Azure Pipelines folder.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── config/
            ├── dev-dpn01.json
            ├── test-dpn01.json
            ├── preprod-dpn01.json
            └── prd-dpn02.json
```

| Parameter | Description | Example Value |
|-----------|-------------|---------------|
| AZURE_SUBSCRIPTION | Azure subscription ID where the infrastructure is deployed | `<valid Azure subscription ID>` |
| SERVICE_CONNECTION | Azure DevOps service connection name for deployment | `<valid Azure service connection name>` |
| RESOURCE_GROUP | Azure resource group containing the AKS cluster | `rg-prd-uks-dpn-01` |
| AKS_CLUSTER | Name of the Azure Kubernetes Service cluster | `aks-prd-uks-dpn-01` |
| NAMESPACE | Kubernetes namespace for the observability stack | `ns-dpn-health-01` |
| IMAGE_REGISTRY | Container registry every stack's images are pulled from | `ghcr.io/energy-dsi` |
| ENV_NAME | Deployment environment abbreviation | `dev` / `sit` / `ppd` / `prd` |
| VALUES_FILE | Helm values file name for use in the pipeline | `values-ppd-dpn01.yaml` |
| AZURE_ENVIRONMENT_NAME | The Azure DevOps **Environment** resource this config file's approval gate is attached to | `dpn-health-monitoring-ppd` |

### Environment-Specific Approval Gates

| Environment | Approval Required | Approvers | Notes |
|-------------|---------------------|-----------|-------|
| Development | None (auto-deploy) | — | Fast iteration; no gate |
| Test | Single approver | Platform/Observability lead | Confirms stack changes are ready to promote |
| Pre-Production | Two approvers | Platform lead + Security representative | Both must approve |
| Production | Two approvers, plus a defined deployment window | Release manager / Change Advisory Board | This is the platform's audit/observability trail — treat approval seriously, and schedule changes to avoid gaps in monitoring coverage |

Configure via **Pipelines → Environments → [environment] → Approvals and checks → Add check → Approvals**, disabling self-approval for Pre-Production and Production.

---

## Secrets Configuration (Global)

Sensitive credentials must **not be stored in source code repositories**. They must be stored securely in one of the following vaults:

- **HashiCorp Vault** — provided with the DSI DPN package
- **Azure Key Vault** — cloud-specific option for organisations using Azure

| Category | Purpose |
|----------|---------|
| nginx-auth-proxy credentials/OIDC client config | Authenticates DPN Admin access to the dashboards |
| Prometheus/OpenSearch Alert Management webhook & email credentials | Used to send alert notifications |
| Azure Application Insight / Log Analytics / Sentinel credentials | Only required once the WIP Sentinel integration is implemented |

---

## Network and Ports Configuration

This section describes DPN connectivity requirements for ports and protocols, including agent pool requirements for building DPN code.

| Source | Destination | Protocol | Port(s) | Traffic Flow |
|--------|-------------|----------|---------|---------------|
| CI/mirroring agent | Docker Hub, Quay.io, `registry.k8s.io`, GitHub Container Registry, and other origin registries per [Container Image Configuration](#container-image-configuration) | TLS | 443 | Outbound (mirroring only, not a runtime AKS dependency) |
| AKS node pool | `ghcr.io` (pull every stack image) | TLS | 443 | Outbound |
| Every DPN component | OTEL Collector (`ns-dpn-health-01`) | OTLP/gRPC | 4317 | Inbound to this service |
| OTEL Collector | Kafka (`otel-metrics` topic) | Kafka protocol | 9092 | Outbound (metrics) |
| DPN Admin | nginx-auth-proxy | HTTPS | 443 | Inbound (dashboard access) |

> Unlike a mixed repository, **AKS nodes never need to reach any origin third-party registry directly** for this service — GHCR is the single runtime pull source, matching the current inventory's mirror-everything approach.

---

# Container Image Configuration

Every image below is Third-Party, mirrored into GHCR **with its original upstream version tag preserved** — DSI's own semantic versioning scheme does not apply, since none of these are DSI-authored. There are no custom images in this repository.

## Ingestion

| Component | Upstream Image | GHCR Reference |
|-----------|------------------|------------------|
| OTEL Collector | `otel/opentelemetry-collector-contrib:0.95.0` | `ghcr.io/energy-dsi/opentelemetry-collector-contrib:0.95.0` |

## Metrics Stack

| Component | Upstream Image | GHCR Reference |
|-----------|------------------|------------------|
| Kafka (`otel-metrics` buffer) | `confluentinc/cp-kafka:7.5.3` | `ghcr.io/energy-dsi/dpn-kafka:7.5.3` |
| Zookeeper (Kafka coordination) | `confluentinc/cp-zookeeper:7.5.3` | `ghcr.io/energy-dsi/dpn-zookeeper:7.5.3` |
| Kafka UI (health) | `provectuslabs/kafka-ui:latest` | `ghcr.io/energy-dsi/kafka-ui:v0.7.2` |
| Prometheus | `quay.io/prometheus/prometheus` (via `kube-prometheus-stack` chart, unpinned) | `ghcr.io/energy-dsi/prometheus:v3.6.0` |
| Alertmanager | `quay.io/prometheus/alertmanager` (via `kube-prometheus-stack`, unpinned) | `ghcr.io/energy-dsi/alertmanager:v0.28.1` |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics` (via `kube-prometheus-stack`, unpinned) | `ghcr.io/energy-dsi/kube-state-metrics:v2.17.0` |
| Thanos (sidecar/query) | `thanosio/thanos:v0.34.0` / `quay.io/thanos/thanos:v0.34.0` (two sources, same version) | `ghcr.io/energy-dsi/thanos:v0.34.0` |
| Perses | `persesdev/perses:v0.53.1` | `ghcr.io/energy-dsi/perses:v0.53.1` |

## Log Stack

| Component | Upstream Image | GHCR Reference |
|-----------|------------------|------------------|
| OpenSearch | `opensearchproject/opensearch:2.11.0` | `ghcr.io/energy-dsi/opensearch:2.11.0` |
| OpenSearch Dashboards | `opensearchproject/opensearch-dashboards:2.11.0` | `ghcr.io/energy-dsi/opensearch-dashboards:2.11.0` |
| OpenSearch Data Prepper | `opensearchproject/data-prepper:2.6.0` | `ghcr.io/energy-dsi/data-prepper:2.6.0` |

## Trace Stack

| Component | Upstream Image | GHCR Reference |
|-----------|------------------|------------------|
| Jaeger Query | `jaegertracing/jaeger-query:1.57.0` | `ghcr.io/energy-dsi/jaeger-query:1.57.0` |
| Jaeger Ingester | `jaegertracing/jaeger-ingester:1.57.0` | `ghcr.io/energy-dsi/jaeger-ingester:1.57.0` |
| Jaeger Collector *(currently disabled)* | `jaegertracing/jaeger-collector:1.57.0` | `ghcr.io/energy-dsi/jaeger-collector:1.57.0` |

## Dashboard Access

| Component | Upstream Image | GHCR Reference |
|-----------|------------------|------------------|
| Nginx (reverse proxy / auth) | `nginx:1.25-alpine` | `ghcr.io/energy-dsi/nginx:1.25-alpine` |

## Build-Time / Init Containers

| Component | Upstream Image | GHCR Reference |
|-----------|------------------|------------------|
| curl (dashboard/alerting init containers) | `curlimages/curl:8.6.0` / `8.8.0` (inconsistent across files) | `ghcr.io/energy-dsi/curl:8.8.0` |

## Image Pull Configuration

| Parameter | Purpose | Example |
|-----------|---------|---------|
| image.registry | GHCR namespace every chart pulls from | `ghcr.io/energy-dsi` |
| imagePullSecrets | Kubernetes secret referencing a GHCR PAT, if the `energy-dsi` packages are private | `ghcr-pull-secret` |
| imagePullPolicy | Whether to always re-check the registry for the tag | `IfNotPresent` for pinned tags; see [Known Issues](#known-issues) for the ones that aren't yet |

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username-or-bot-account> \
  --docker-password=<GitHub PAT with read:packages scope> \
  -n ns-dpn-health-01
```

## Known Issues

The inventory flags several pinning/consistency problems to resolve **before or during** the GHCR migration, not after:

- **Kafka UI pinned to `latest` upstream** — currently mirrored as `v0.7.2`, but the source is `provectuslabs/kafka-ui:latest`, an unpinned tag. Confirm `v0.7.2` is actually the version in use before relying on the mirror being reproducible.
- **`kube-prometheus-stack` chart version is unpinned** — `prometheus-cd.yaml` runs `helm pull ... kube-prometheus-stack` with no `--version`, so the exact Prometheus/Alertmanager/kube-state-metrics image tags resolved by the chart aren't fixed yet. The dev docker-compose reference for Prometheus is `v2.49.0`, inconsistent with the `v3.6.0` mirrored tag above. **Pin the chart version first**, then mirror whatever tag that resolves to.
- **Thanos has two upstream sources for the same version** — the sidecar uses `quay.io/thanos/thanos:v0.34.0`, the query component's chart default uses `thanosio/thanos:v0.34.0`. Both are intended to mirror to the same GHCR tag; confirm both usages are actually repointed once mirrored, not just one.
- **curl init container version inconsistency** — two versions (`8.6.0` in dashboard-init/alerting Dockerfiles, `8.8.0` elsewhere) exist across the repo's files. Standardise on `8.8.0` (the version already chosen for the GHCR mirror) before mirroring, rather than after.
- **Jaeger Collector is currently disabled** (`enabled: false` in `values.yaml`) but is mirrored for completeness — don't assume its presence in GHCR means it's actually deployed.

---

# DPN Health Monitoring Service Configuration

## Introduction and Purpose

The DPN Health Monitoring Service provides the single point of telemetry ingestion for all DPN components, and the storage/dashboarding/alerting needed to operate the platform.

## Data Flow

| Step | Component | Action |
|------|-----------|--------|
| 1 | Data Pipeline Connectors/Executors, Federator GRPC Gateway Server/Client, Federator Certificate Manager, File Scanning Service | Export OTLP telemetry to the OTEL Collector |
| 2 | OTEL Collector | Collects, redacts sensitive data, optimises throughput, routes by signal type |
| 3a | Kafka (`otel-metrics`) → Prometheus Kafka Adapter → Prometheus + Thanos → Perses | Metrics path |
| 3b | OpenSearch Data Prepper → OpenSearch → OpenSearch Dashboards | Log path |
| 3c | Jaeger Collector → Jaeger Dashboards | Trace path |
| 4 | Prometheus + Thanos, OpenSearch | Feed their respective Alert Management systems (email, webhook) |
| 5 | DPN Admin | Views Perses, OpenSearch Dashboards, and Jaeger Dashboards via nginx-auth-proxy |

## Helm Configuration

### Required Components

See [Container Image Configuration](#container-image-configuration) for the full image list per stack.

## Horizontal Pod Autoscaler (HPA) Configuration

HPA is only appropriate for the **stateless** components in this stack — query/dashboard/collector-type workloads that don't own persistent local state. It is **not** appropriate for the stateful storage components, which should instead be scaled (if at all) via their own StatefulSet replica management and storage-aware operators.

| Component | HPA Candidate? | Reasoning |
|-----------|------------------|-----------|
| OTEL Collector | Yes | Stateless ingestion; scales with inbound telemetry volume |
| Jaeger Query / Ingester | Yes | Stateless read/write path |
| OpenSearch Dashboards | Yes | Stateless UI layer |
| Perses | Yes | Stateless UI layer |
| nginx-auth-proxy | Yes | Stateless reverse proxy |
| Prometheus / Thanos | No | Stateful storage; scale via retention/sharding strategy instead |
| OpenSearch (data nodes) | No | Stateful storage; scale via OpenSearch's own cluster sizing |
| Kafka / Zookeeper | No | Stateful; broker count is a capacity-planning decision, not an autoscaling one |

| Parameter | Purpose | Example |
|-----------|---------|---------|
| hpa.enabled | Enables HPA for a stateless component | `true` |
| hpa.minReplicas | Minimum pod count | `1` |
| hpa.maxReplicas | Maximum pod count | `3` |
| hpa.targetCPUUtilizationPercentage | CPU target for scaling | `70` |
| hpa.targetMemoryUtilizationPercentage | Memory target for scaling | `80` |

> Requires the Kubernetes **metrics-server** running in the cluster (standard on AKS by default).

## Alerting Configuration

| Parameter | Purpose | Example |
|-----------|---------|---------|
| prometheusAlertManager.receivers | Email/webhook targets for metrics alerts | TBC |
| openSearchAlerting.receivers | Email/webhook targets for log alerts | TBC |

## Secrets Configuration

See [Secrets Configuration (Global)](#secrets-configuration-global) — nginx-auth-proxy credentials, alert-notification webhook/email credentials, and (once implemented) Azure Sentinel integration credentials.

---

# Sentinel Integration (WIP)

The diagram marks this path explicitly as work-in-progress: **Application Insight → Azure Log Analytics Workspace → Azure Sentinel**. Not proposed here since it is not yet part of the confirmed architecture.

---

# Open Questions

1. **Should this repo's "mirror everything to GHCR" approach be reconciled with `dpn-file-scan-service`'s "third-party stays off GHCR" approach?** The two repos currently follow opposite policies for third-party images — confirm whether this is intentional (infra/observability components get supply-chain mirroring; application build bases don't) or whether one should change to match the other.
2. **Chart version pinning for `kube-prometheus-stack`** — must be resolved before the Prometheus/Alertmanager/kube-state-metrics mirror tags can be considered final.
3. **Exact OTEL Collector redaction rules, retention policies, and identity provider for nginx-auth-proxy** — as previously noted, none of these are specified in the architecture yet.
4. **CI pipeline necessity** — since every component here is a third-party mirror rather than custom-built code, confirm whether a CI pipeline is needed at all, or whether a scheduled image-mirroring job plus CD-only deployment is sufficient.

---

# Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
