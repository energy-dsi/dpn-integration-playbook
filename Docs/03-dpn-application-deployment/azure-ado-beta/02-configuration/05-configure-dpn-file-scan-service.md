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
      - [Existing Configuration](#existing-configuration)
      - [Updated Configuration](#updated-configuration)
    - [Azure Environment Configuration](#azure-environment-configuration)
  - [Secrets Configuration (Global)](#secrets-configuration-global)
    - [Certificate Handling Note](#certificate-handling-note)
  - [Network and Ports Configuration](#network-and-ports-configuration)

- [DPN File Scanning Service Configuration](#dpn-file-scanning-service-configuration)
  - [Introduction and Purpose](#introduction-and-purpose)
  - [Data Flow](#data-flow)
  - [Helm Configuration](#helm-configuration)
    - [Required Azure Resources](#required-azure-resources)
    - [Managed Identity / RBAC Configuration](#managed-identity--rbac-configuration)
    - [Service Configuration Parameters](#service-configuration-parameters)
  - [Trigger Configuration](#trigger-configuration)
  - [Secrets Configuration](#secrets-configuration)

- [DPN File Scan Data Store Configuration](#dpn-file-scan-data-store-configuration)
  - [Storage Configuration](#storage-configuration)
  - [DPN Eventing Configuration (Event Grid / Service Bus)](#dpn-eventing-configuration-event-grid--service-bus)

- [Cloud Portability Notes](#cloud-portability-notes)
- [Review Notes](#review-notes)

---

# Overview

Data Preparation Node (DPN) consists of the following components in the DSI package:

![DPN Architecture Blocks](/Docs/04-dpn-architecture/images/dpn_components.png)

- **DPN Security Service**
  - Vault Service — Certificate regeneration for DSM communication and storage.
  - Digital Certificate Manager — Manages recycling of certificates at a predefined interval from the DSI Management Node.
  - Shared File Service — SMB-based shared file storage between the Federator Certificate Manager and Federator Gateway for storing certificate P12 files.
- **DPN Data Pipelines** — Responsible for producing and consuming data products of an organisation.
- **DPN Data Store Service**
  - Storage — Contains storage accounts or S3 buckets to store files produced by DPN data pipelines, certificate P12 files, and Redis caching data.
  - Streaming Service — DPN uses Kafka as a streaming service for managing events and topics during data transmission.
- **DPN Federator Gateway** — Responsible for DSM and DPN authentication, and data transfer between DPN nodes.

DPN components on Azure are deployed using **Azure DevOps (ADO) pipelines**, as defined in the DPN repositories provided by DSI. These pipelines are organised into two stages:

- **Continuous Integration (CI)**
- **Continuous Deployment (CD)**

The CI pipeline builds the application artefacts, while the CD pipeline deploys them to the target infrastructure.

This document describes the configuration parameters required for deploying **DPN nodes on Azure Kubernetes Service (AKS)**. These parameters must be configured before running the deployment pipelines.

The configuration covers the following areas:

- DSI DSM endpoint configuration
- Azure DevOps configuration
- Secret configuration
- Helm chart configuration
- Network and ports configuration

---

## Continuous Integration (CI)

The **Continuous Integration (CI)** pipeline is optional, partipants can either use it to build container components from the provided DPN Source code. Or it can be replaced in full by obtaining pre-build DPN containers directly from the DSI provided **GitHub Container Registry (GHCR)**.

The **Continuous Integration (CI)** pipeline performs the following activities:

1. Build the application source code.
2. Produce container image artefacts.
3. Tag the generated container images.
4. Push the images to a container registry.

DSI recommends using **Azure Container Registry (ACR)** for storing container images in Azure due to its seamless integration with Azure services and built-in security capabilities.

Organisations may use alternative container registries if permitted by their internal network and security policies.

---

## Continuous Deployment (CD)

The **Continuous Deployment (CD)** pipeline deploys the container images to the **Azure Kubernetes Service (AKS)** cluster using Helm.

During deployment, the pipeline performs the following steps:

1. Authenticate with Azure using the configured service connection.
2. Retrieve credentials for the target AKS cluster.
3. Validate Helm charts using `helm lint`.
4. Perform a Helm **dry-run** validation.
5. Deploy the DPN platform using Helm.
6. Verify deployment status using Kubernetes rollout checks.

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
| NAMESPACE | Kubernetes namespace for container deployment | `ns-dpn-01` |
| KEY_VAULT_NAME | Azure Key Vault used to store secrets and certificates | `akv-prd-uks-dpn-01` |
| BASE_REGISTRY | Base registry path used by deployment images | `<image-registry-url>` |
| ENV_NAME | Deployment environment abbreviation | `dev` / `sit` / `ppd` / `prd` |
| VALUES_FILE | Helm values file name for use in the pipeline | `values-prd-dpn01.yaml` |

---

## Secrets Configuration (Global)

Sensitive credentials must **not be stored in source code repositories**. They must be stored securely in one of the following vaults:

- **HashiCorp Vault** — provided with the DSI DPN package
- **Azure Key Vault** — cloud-specific option for organisations using Azure

The table below lists all secrets required across the DPN package. Refer to the component-specific secrets configuration sections for details on where each secret must be provisioned.

| Variable | Description |
|----------|-------------|
| CLIENT_P12_PASSWORD | Password for the federator client certificate keystore |
| CLIENT_TRUSTSTORE_PASSWORD | Password for the federator client truststore |
| SERVER_P12_PASSWORD | Password for the federator server certificate keystore |
| SERVER_TRUSTSTORE_PASSWORD | Password for the federator server truststore |
| IDP_CLIENT_SECRET | Client secret used for DSI DSM Identity Provider authentication |
| IDP_KEYSTORE_PASSWORD | Password for the IDP keystore |
| IDP_TRUSTSTORE_PASSWORD | Password for the IDP truststore |
| SRC_CONNECTION_STRING | SAS token for connecting to the source Blob Storage account |
| MAPPER_CONNECTION_STRING | SAS token for connecting to the mapper Blob Storage account |
| TARGET_CONNECTION_STRING | SAS token for connecting to the target Blob Storage account |
| VAULT-TOKEN | Root token of the DPN HashiCorp Vault |
| OAUTH2-CLIENT-SECRET | OAuth2 client secret for the DPN's client ID received from DSI DSM (equivalent to `IDP_CLIENT_SECRET`) |
| AZURE-STORAGE-ACCOUNT-NAME | Storage account name for the Azure File Share used for common DPN certificate storage |
| AZURE-STORAGE-ACCOUNT-KEY | Storage account key for the Azure File Share used for common DPN certificate storage |

---

### Certificate Handling Note

During the organisation's onboarding process, an initial certificate package is provided containing the certificate and CA Chain files. Organisations must securely store these certificates in a vault or equivalent secret store. The following certificate artefacts are included in the DPN package:

- The **P12/PFX certificate** issued by the DSI DSM Certificate Authority (keystore)
- The **DSI certificate chain** (truststore)

Refer to the [Federator Certificate Manager Configuration](#federator-certificate-manager-configuration) section for detailed instructions on certificate lifecycle management.

The same certificate files are used across all DPN components that require integration with the Data Sharing Mechanism (DSM), specifically the Federator Gateway and Certificate Lifecycle Manager.

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
| imageName | Container image name | `dpn-file-scan-service` |
| srcContainerName | Quarantine container the service pulls verified files from | `dp-consumer-raw` |
| targetContainerName | Existing container the service pushes verified files into | `dp-consumer-stage` |
| serviceBusNamespace | Azure Service Bus namespace hostname | `<namespace>.servicebus.windows.net` |
| serviceBusTopicName | Topic the scan-result events are published to | `dpn-file-scan-results` |
| serviceBusSubscriptionName | This service's subscription on that topic | `dpn-file-verification-service` |
| pollIntervalSeconds | Interval between polls | `30` |
| OTEL_EXPORTER_OTLP_ENDPOINT | OTEL collector endpoint | `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4317` |
| OTEL_EXPORTER_OTLP_PROTOCOL | Protocol for the OTEL exporter | `grpc` |
| OTEL_EXPORTER_OTLP_INSECURE | Whether the OTEL collector requires TLS | `true` |

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
