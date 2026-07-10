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
  - [Custom Image (GHCR)](#custom-image-ghcr)
  - [Third-Party / Build-Base Image (Not Mirrored to GHCR)](#third-party--build-base-image-not-mirrored-to-ghcr)
  - [Image Pull Configuration](#image-pull-configuration)

- [DPN File Scanning Service Configuration](#dpn-file-scanning-service-configuration)
  - [Introduction and Purpose](#introduction-and-purpose)
  - [Data Flow](#data-flow)
  - [Helm Configuration](#helm-configuration)
    - [Required Azure Resources](#required-azure-resources)
    - [Managed Identity / RBAC Configuration](#managed-identity--rbac-configuration)
    - [Service Configuration Parameters](#service-configuration-parameters)
  - [Horizontal Pod Autoscaler (HPA) Configuration](#horizontal-pod-autoscaler-hpa-configuration)
  - [Trigger Configuration](#trigger-configuration)
  - [Secrets Configuration](#secrets-configuration)

- [DPN File Scan Data Store Configuration](#dpn-file-scan-data-store-configuration)
  - [Storage Configuration](#storage-configuration)
  - [DPN Eventing Configuration (Event Grid / Service Bus)](#dpn-eventing-configuration-event-grid--service-bus)

- [Cloud Portability Notes](#cloud-portability-notes)
- [Review Notes](#review-notes)

---

# Overview

The DPN File Scanning Service adds a malware-scanning and verification gate into the DPN consumer data pipeline, between the Federator Client's landing zone and the existing Consumer Extractor — see [DPN File Scanning Service Configuration](#dpn-file-scanning-service-configuration) for the full data flow, per ADR-42.

DPN components on Azure are deployed using **Azure DevOps (ADO) pipelines**, as defined in the DPN repositories provided by DSI. These pipelines are organised into two stages:

- **Continuous Integration (CI)**
- **Continuous Deployment (CD)**

Deployment is **containerised**: the service itself runs as a single custom image pulled from **GHCR**. Unlike the DPN Data Pipeline, this service has no separate third-party runtime containers to source — its dependencies (Microsoft Defender for Storage, Event Grid, Service Bus) are Azure PaaS services, not containers, and its only third-party image is a build-time base that is **not** mirrored to GHCR — see [Container Image Configuration](#container-image-configuration).

The configuration covers the following areas:

- Azure DevOps configuration, including environment-specific approval gates
- Container image sourcing and versioning
- Required Azure resources and Managed Identity / RBAC configuration
- Helm chart configuration, including autoscaling
- Secrets configuration
- Network and ports configuration

---

## Continuous Integration (CI)

The **Continuous Integration (CI)** pipeline is optional, partipants can either use it to build container components from the provided DPN Source code. Or it can be replaced in full by obtaining pre-build DPN containers directly from the DSI provided **GitHub Container Registry (GHCR)**.

Once built, the CI pipeline is expected to:

1. Build the application source code (Python, per the confirmed build base — see [Third-Party / Build-Base Image](#third-party--build-base-image-not-mirrored-to-ghcr)).
2. Produce a container image artefact.
3. Tag the image with a fixed semantic version (e.g. `1.0.0`) — date-based CI tags are **retired** in favour of fixed semantic versions, consistent with every other DPN custom image.
4. Push the image to `ghcr.io/energy-dsi/dpn-file-scan-service:1.0.0`.

The build-time base image (`python:3.12.11-slim-bookworm`) is pulled directly from Docker Hub by the CI pipeline at build time and is **not** separately mirrored to or pulled from GHCR — see [Container Image Configuration](#container-image-configuration) for the reasoning.

---

## Continuous Deployment (CD)

Once built, the CD pipeline is expected to deploy the container image to **Azure Kubernetes Service (AKS)** using Helm, following the same pattern as the other DPN components:

1. Authenticate with Azure using the configured service connection.
2. Retrieve credentials for the target AKS cluster.
3. Validate the Helm chart using `helm lint`.
4. Perform a Helm **dry-run** validation.
5. **Wait for environment approval**, where configured — see [Environment-Specific Approval Gates](#environment-specific-approval-gates). Pipeline execution pauses here until an authorised approver signs off for that specific environment.
6. Deploy the service using Helm, pulling the image from `ghcr.io/energy-dsi/dpn-file-scan-service:1.0.0`.
7. Verify deployment status using Kubernetes rollout checks, including confirming the Horizontal Pod Autoscaler is healthy — see [Horizontal Pod Autoscaler (HPA) Configuration](#horizontal-pod-autoscaler-hpa-configuration).

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
| NAMESPACE | Kubernetes namespace for the service | `ns-dpn-01` |
| IMAGE_REGISTRY | Container registry the custom image is pulled from | `ghcr.io/energy-dsi` |
| ENV_NAME | Deployment environment abbreviation | `dev` / `sit` / `ppd` / `prd` |
| VALUES_FILE | Helm values file name for use in the pipeline | `values-prd-dpn01.yaml` |
| AZURE_ENVIRONMENT_NAME | The Azure DevOps **Environment** resource (Pipelines → Environments) this config file's approval gate is attached to | `dpn-file-scan-service-prd` |

### Environment-Specific Approval Gates

Each environment-specific config file corresponds to an **Azure DevOps Environment**, gated the same way as the DPN Data Pipeline's CD pipeline:

| Environment | Approval Required | Approvers | Notes |
|-------------|---------------------|-----------|-------|
| Development | None (auto-deploy) | — | Fast iteration; no gate |
| Test | Single approver | Test/QA lead | Confirms the build under test is ready to promote |
| Pre-Production | Two approvers | Platform lead + Security representative | Both must approve |
| Production | Two approvers, plus a defined deployment window | Release manager / Change Advisory Board | This service sits directly in the inbound file security path — treat approval as least as strict as the Data Pipeline's |

Configure via **Pipelines → Environments → [environment] → Approvals and checks → Add check → Approvals**, disabling self-approval for Pre-Production and Production.

---

## Secrets Configuration (Global)

Per the ADR's Azure design, this service uses **Managed Identity for every Azure integration**. No static secrets are expected for Event Grid, Service Bus, or storage access. The only credential that may be required is authentication to the OTEL log aggregator, if it is not reachable anonymously.
---

## Network and Ports Configuration

This section describes DPN connectivity requirements for ports and protocols, including agent pool requirements for building DPN code.

![DPN Ports & Protocols](/Docs/04-dpn-architecture/images/DPN_ports_and_protocols.png)

The following firewall rules must be applied by the organisation before installing DPN:

| Source IP Address | Source VNET | Source Subnet | Destination IP / Zone / URL | Destination VNET | Destination Subnet | Protocol | Port(s) | Traffic Flow |
|-------------------|-------------|---------------|-----------------------------|------------------|--------------------|----------|---------|--------------|
| Node pool agent VM IP | Node Pool VM VNET | Node Pool VM subnet | `packages.confluent.io/*` | N/A | N/A | TLS | 443 | Outbound |
| Node pool agent VM IP | Node Pool VM VNET | Node Pool VM subnet | `registry-1.docker.io/*`<br>`auth.docker.io/*`<br>`production.cloudflare.docker.com`<br>`index.docker.io/*` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | `auth-mtls.dsm01.dsi(xxx).neso.energy` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | `management.dsm01.dsi(xxx).neso.energy` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | Organisation-specific URL for DPN-to-DPN data sharing | N/A | N/A | TLS | 443 | Bi-directional |

> **Note:** The organisation-specific URL in the final row defines the target organisation with which data sharing will occur. These firewall rules must be opened from both organisations' network perspectives. The `dsi(xxx)` notation refers to the `dsidev`, `dsitest`, `dsipre`, and `dsi` (production) environments.

> **Note:** DPN uses HTTP/2 traffic over gRPC on port **443**. HTTP/2 traffic requires TCP passthrough to a Layer 4 load balancer; Layer 7 load balancing is not supported for this traffic.

---

# Container Image Configuration

## Custom Image (GHCR)

| Image | GHCR Reference |
|-------|------------------|
| DPN File Scanning Service | `ghcr.io/energy-dsi/dpn-file-scan-service:1.0.0` |

This is a fixed semantic version tag, replacing an earlier date-based CI tag. Set `imageName`/`imageTag` (or `image.repository`/`image.tag`, depending on the eventual chart) to this reference.

## Third-Party / Build-Base Image (Not Mirrored to GHCR)

| Component | Upstream Image | Sourced From |
|-----------|------------------|---------------|
| Python build base | `python:3.12.11-slim-bookworm` | Pulled **directly from Docker Hub** by the CI pipeline at build time |

**This service's policy differs from the DPN Data Pipeline's.** The Data Pipeline mirrors every third-party runtime dependency (Airflow, Postgres, Redis, Alpine) into GHCR alongside its custom images. This service does **not** do that: `python:3.12.11-slim-bookworm` is a **build-stage-only** base — it's baked into the final custom image during `docker build` and is never itself deployed, pulled by AKS, or referenced in a Helm chart. There is nothing to mirror at runtime, and DSI has confirmed the intent here is to pull it straight from Docker Hub at build time with its version pinned, rather than adding a GHCR mirroring step for an image that never reaches the cluster.

If this service later grows a genuine third-party **runtime** dependency (e.g. a sidecar or a separate supporting container), confirm at that point whether it should follow the Data Pipeline's GHCR-mirroring convention or this service's direct-from-source convention — see [Open Questions](#open-questions).

## Image Pull Configuration

| Parameter | Purpose | Example |
|-----------|---------|---------|
| image.registry | GHCR namespace the custom image is pulled from | `ghcr.io/energy-dsi` |
| image.repository | Image name | `dpn-file-scan-service` |
| image.tag | Fixed semantic version tag | `1.0.0` |
| imagePullSecrets | Kubernetes secret referencing a GHCR PAT, if the `energy-dsi` GHCR package is private | `ghcr-pull-secret` |
| imagePullPolicy | Whether to always re-check the registry for the tag | `IfNotPresent` (safe given the image is pinned to a fixed version) |

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username-or-bot-account> \
  --docker-password=<GitHub PAT with read:packages scope> \
  -n <namespace>
```

# DPN File Scanning Service Configuration

The DPN File Scanning Service ensures inbound data product files are verified free of malware before they reach the existing DPN Data Pipeline Consumer. It applies cloud-native scanning and event-driven verification, ensuring no file reaches `dp-consumer-stage` — and therefore the Consumer Extractor — without a clean scan result.

## Data Flow

| Step | Component | Action |
|------|-----------|--------|
| 1 | Federator Client | Writes the inbound data product file into `dp-consumer-raw` (new quarantine container) |
| 2 | Azure Storage Account (`dp-consumer-raw`) | Emits a webhook event on blob created |
| 3 | Microsoft Defender for Storage | Scans the new blob for malware |
| 4a | Defender for Storage | If malicious → deletes the file from `dp-consumer-raw` |
| 4b | Defender for Storage | Emits the scan result (file name, location, verdict) |
| 5 | Azure Event Grid (Event Orchestrator) | Receives the scan result event, publishes it onto the Service Bus Topic |
| 6 | Azure Service Bus Topic (Event Publisher) | Holds the scan-result message for the Verification Service to consume |
| 7 | DPN File Scanning Service | Polls/subscribes to the Service Bus Topic at an interval |
| 8a | DPN File Scanning Service | If the scan report is **not** malicious/infected → pulls the file from `dp-consumer-raw` and pushes it into `dp-consumer-stage` |
| 8b | DPN File Scanning Service | Logs what it processed to the OTEL log aggregator |
| 9 | Consumer Extractor (existing, unchanged) | Reads from `dp-consumer-stage` as it already does today |

## Helm Configuration

### Required Azure Resources

| Resource | Purpose |
|----------|---------|
| Storage Account — `dp-consumer-raw` container | New quarantine landing zone for inbound files, written to by the Federator Client |
| Storage Account — `dp-consumer-stage` container | Existing container the Consumer Extractor already reads from; this service writes the verified file here |
| Microsoft Defender for Storage (enabled on the account hosting `dp-consumer-raw`) | Malware scanning |
| Event Grid System Topic (on the `dp-consumer-raw` storage account) | Captures the blob-created / scan-result event |
| Azure Service Bus namespace + Topic + Subscription | Downstream event publisher this service polls/subscribes to |
| OTEL-compatible log aggregator endpoint | Receives processing logs from this service |

### Managed Identity / RBAC Configuration

The ADR shows four Managed Identity / RBAC assignments on the Azure design. Their exact attachment points are inferred from their position on the diagram relative to the arrows they sit beside — flagged individually below.

| Identity (whose identity) | RBAC Role | Scope | Confidence |
|----------------------------|-----------|-------|------------|
| Event Grid → Service Bus delivery identity | **Azure Service Bus Data Sender** | Service Bus Topic | High — sits directly on that edge |
| DPN File Scanning Service | **Azure Service Bus Data Receiver** ("Data Reader" per diagram label) | Service Bus Subscription | High — sits directly on that edge |
| DPN File Scanning Service | **Storage Blob Data Reader** | `dp-consumer-raw` container | Inferred from diagram position — confirm |
| DPN File Scanning Service | **Storage Blob Data Contributor** | `dp-consumer-stage` container | High — sits directly on the "push" edge |

### Service Configuration Parameters

Following the parameter style used by the DPN Data Pipeline's `values.yaml` files:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Kubernetes namespace | `ns-dpn-01` |
| image.registry / image.repository / image.tag | GHCR image reference (see [Custom Image (GHCR)](#custom-image-ghcr)) | `ghcr.io/energy-dsi` / `dpn-file-scan-service` / `1.0.0` |
| srcContainerName | Quarantine container the service pulls verified files from | `dp-consumer-raw` |
| targetContainerName | Existing container the service pushes verified files into | `dp-consumer-stage` |
| serviceBusNamespace | Azure Service Bus namespace hostname | `<namespace>.servicebus.windows.net` |
| serviceBusTopicName | Topic the scan-result events are published to | `dpn-file-scan-results` |
| serviceBusSubscriptionName | This service's subscription on that topic | `dpn-file-verification-service` |
| pollIntervalSeconds | Interval between polls | `30` |
| OTEL_EXPORTER_OTLP_ENDPOINT | OTEL collector endpoint | `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4317` |
| OTEL_EXPORTER_OTLP_PROTOCOL | Protocol for the OTEL exporter | `grpc` |
| OTEL_EXPORTER_OTLP_INSECURE | Whether the OTEL collector requires TLS | `true` |

> **These are proposals, not confirmed values** — there is no `values.yaml`, chart, or application code in the repository to validate them against yet.

## Horizontal Pod Autoscaler (HPA) Configuration

Unlike the Data Pipeline (one Deployment per product), this service is a single always-on Deployment, so HPA applies to just the one workload. Requires the Kubernetes **metrics-server** running in the AKS cluster (standard on AKS by default).

| Parameter | Purpose | Example |
|-----------|---------|---------|
| hpa.enabled | Enables the Horizontal Pod Autoscaler | `true` |
| hpa.minReplicas | Minimum pod count, including at idle | `1` |
| hpa.maxReplicas | Maximum pod count under peak scan-result volume | `3` |
| hpa.targetCPUUtilizationPercentage | Average CPU utilisation that triggers scale-out | `70` |
| hpa.targetMemoryUtilizationPercentage | Average memory utilisation that triggers scale-out | `80` |

> **Note:** when `hpa.enabled: true`, `replicaCount` is only the initial replica count at first deploy — the HPA controller owns replica count from that point on. If multiple replicas run concurrently, confirm the Service Bus subscription's message-locking behaviour prevents two replicas from processing the same scan-result message twice (competing-consumer pattern) — see [Open Questions](#open-questions).

## Trigger Configuration

Unlike the DPN Data Pipeline, which supports two interchangeable scheduling backends (`kafka-trigger` and `airflow`), the ADR describes a single trigger pattern for this service:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| pollIntervalSeconds | The service polls its Service Bus subscription for new scan-result messages at this interval | `30` |

> **Placeholder:** Prabir's input

## Secrets Configuration

No Kubernetes secrets are expected to be required for this service's Azure integrations, since Managed Identity is used throughout (see [Secrets Configuration (Global)](#secrets-configuration-global)). If the OTEL log aggregator requires authentication, that credential would be the only secret needed, provisioned as a standard Kubernetes secret consistent with other DPN components.

---

# DPN File Scan Data Store Configuration

## Storage Configuration

| Container | Purpose |
|-----------|---------|
| `dp-consumer-raw` | New quarantine container the Federator Client writes inbound files into; scanned by Defender for Storage |
| `dp-consumer-stage` | Existing container the Consumer Extractor reads from; this service writes the verified file here |

> **Note:** these are the same two containers referenced in the DPN Data Pipeline Configuration Guide's [Storage Blob / S3 Configuration](../dpn-data-pipelines/config.md#storage-blob--s3-configuration) — `dp-consumer-raw` is new, introduced by this service; `dp-consumer-stage` already exists and its naming/ownership doesn't change.

## DPN Eventing Configuration (Event Grid / Service Bus)

Unlike the DPN Data Pipeline, which uses Kafka for eventing, this service uses Azure Event Grid and Service Bus per the ADR's Azure design:

| Component | Purpose |
|-----------|---------|
| Event Grid System Topic | Subscribed to blob-created / scan-result events on the storage account hosting `dp-consumer-raw` |
| Service Bus Topic | Receives the forwarded event from Event Grid |
| Service Bus Subscription | Read by the DPN File Scanning Service |

These must be pre-created before the service's CD pipeline is executed, consistent with how Kafka topics must be pre-created before the DPN Data Pipeline's CD tasks run.

---

# Cloud Portability Notes

The ADR's "Cloud Agnostic Design" page names an equivalent for AWS and marks GCP as **TBC**:

| Role | Azure | AWS | GCP |
|------|-------|-----|-----|
| Cloud-native scanning | Microsoft Defender for Storage/SaaS | GuardDuty Malware Protection | **TBC** |
| Event orchestrator | Event Grid | EventBridge | EventArc |
| Event publisher | Service Bus Topic | SNS Topic | Pub/Sub Topic |

If DSI needs to support AWS or GCP deployments of this service, the GCP scanning capability in particular needs a decision before configuration can be written for that pathway.

---

# Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
