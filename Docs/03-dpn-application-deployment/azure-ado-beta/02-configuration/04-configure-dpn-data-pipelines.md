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

- [DPN Data Pipelines Configuration](#dpn-data-pipelines-configuration)
  - [Introduction and Purpose](#introduction-and-purpose)
  - [Helm Configuration](#helm-configuration-data-pipelines)
    - [Data Pipeline Blueprints](#data-pipeline-blueprints)
    - [Producer Setup](#producer-setup)
    - [Consumer Setup](#consumer-setup)
    - [Producer Parameters — dl, eq, eqbd, and ssh (adaptor & schema_mapper)](#producer-parameters--dl-eq-eqbd-and-ssh-adaptor--schema_mapper)
    - [Consumer Parameters — extractor & schema_mapper](#consumer-parameters--extractor--schema_mapper)
  - [Scheduling Configuration](#scheduling-configuration)
    - [Automated Scheduling](#automated-scheduling)
    - [Manual Scheduling](#manual-scheduling)
    - [Onboarding a New Data Product — Scheduling Setup](#onboarding-a-new-data-product--scheduling-setup)
  - [Secrets Configuration](#secrets-configuration-data-pipelines)

- [DPN Data Store Configuration](#dpn-data-store-configuration)
  - [Storage Blob / S3 Configuration](#storage-blob--s3-configuration)
  - [DPN Streaming Service (Kafka)](#dpn-streaming-service-kafka)

- [Review Notes](#review-notes)

---

# Overview

Data Preparation Node (DPN) consists of the following components in the DSI package:

![DPN Architecture Blocks](/Docs/04-dpn-architecture/images/dpn_components.png)

- **DPN Data Pipelines** — Responsible for producing and consuming data products of an organisation.
- **DPN Data Store Service**
  - Storage — Contains storage accounts or S3 buckets to store files produced by DPN data pipelines, certificate P12 files, and Redis caching data.
  - Streaming Service — DPN uses Kafka as a streaming service for managing events and topics during data transmission.

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

## DPN Data Pipelines Configuration

### Introduction and Purpose

The DPN Data Pipeline ensures secure and governed data exchange by validating and transforming datasets before and after transmission. It applies schema assurance, security labelling, and controlled processing across producer and consumer stages. This ensures all shared data conforms to required schemas, security classifications, and governance standards, enabling reliable and compliant data sharing.

### Helm Configuration

The Helm configuration for the DPN deployment is segregated between the Producer and Consumer domains.

- On the producer side, Helm values are defined for each schema type to configure the Adaptor and Schema Mapper, ensuring source-specific validation, governance, and transmission rules.
- On the consumer side, separate Helm values files are used for the Extractor and Schema Mapper to validate and deliver data according to target requirements.

This separation ensures that each pipeline stage operates with file-type-specific schemas and policies while maintaining clear isolation between producer and consumer configurations.


#### Data Pipeline Blueprints

DSI provided following schema types belonging to energy industry. organisations are supposed to verify and augment any new schema type following the DSM data template definition and bring their own adaptor and mapper components accordingly. 

| Schema | Description |
|------|-------------|
| DL | Diagram Layout |
| EQ | Equipment |
| EQBD | Equipment Boundary |
| SSH | Steady State Hypothesis |

DSI provides the above schema-type blueprints from which organisations prepare their data products. The `values.yaml` files within the blueprints directory must **not** be modified directly. The blueprints folder is organised by integration pathway (e.g. `file`, `topic`, `api`) and by schema type within each pathway.

```text
Root-Repository
  └── blueprints
        └── consumer
              └── file
                    ├── extractor
                    │     └── charts
                    │           └── values.yaml
                    └── schema_mapper
                          └── charts
                                └── values.yaml
        └── producer
              └── file
                    ├── dl
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    ├── eq
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    ├── eqbd
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    └── ssh
                          ├── adaptor
                          │     └── charts
                          │           └── values.yaml
                          └── schema_mapper
                                └── charts
                                      └── values.yaml
```

#### Producer Setup

The following steps are required when an organisation produces a data product:

1. Define the **`product_type`** name — the identifier for the data product being published. Each product type must conform to one of the schema types available in the blueprints.
2. Copy the relevant schema folder (e.g. `eq`, `eqbd`, `dl`, or `ssh`) from `Root-Repository/blueprints/producer/file/{schema_type}` to `Root-Repository/producer/file/{schema_type}`.
3. Rename the copied `{schema_type}` folder to `{product_type}` (e.g. rename `eq` to `eq-dp-01`). Only hyphens are permitted as special characters; all other special characters are disallowed.
4. Ensure the `product_type` value is passed consistently during the CI pipeline run.

```text
Root-Repository
  └── producer
        └── file
              └── {product_type}   <- e.g. eq-sample-1
                    ├── adaptor
                    │     └── charts
                    │           └── values.yaml
                    └── schema_mapper
                          └── charts
                                └── values.yaml
```

#### Consumer Setup

The following step is required when an organisation is consuming data products:

1. Copy the consumer folder from `Root-Repository/blueprints/consumer` to `Root-Repository/consumer` as-is, without modification.

```text
Root-Repository
  └── consumer
        └── file
              ├── extractor
              │     └── charts
              │           └── values.yaml
              └── schema_mapper
                    └── charts
                          └── values.yaml
```

> **Note:** The `values.yaml` file can be replicated for multiple environments or DPN deployments (e.g. `values-<env>-dpn01.yaml`, `values-<env>-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section.

DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

> **Naming conventions to observe:**
> - Storage container names, Kafka topic names, and product type names must use only alphanumeric characters and hyphens (`-`). No other special characters are permitted.
> - Organisation names must be abbreviated without spaces.
> - Schema type must match the blueprint schema type exactly: `eq`, `eqbd`, `dl`, or `ssh`.

#### Producer Parameters — dl, eq, eqbd, and ssh (adaptor & schema_mapper)

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| imageName | Image name in the DSI registry | `{image name of adaptor or schema_mapper}` |
| productType | Product type name — alphanumeric and hyphens only | `eq-sample-1` |
| srcContainerName | Source storage container name | `eq-sample-1-stage` |
| mapperTopicName | Kafka topic name for the mapper stage | `dpn-producer-eq-sample-1-raw` |
| mapperContainerName | Storage container name for the mapper stage | `eq-sample-1-raw` |
| targetTopicName | Kafka topic name for the target stage | `dpn-producer-eq-sample-1-target` |
| targetContainerName | Storage container name for the target stage | `eq-sample-1-target` |
| orgName | Organisation name abbreviation (no spaces) | `orga` |
| schemaType | Schema type | `eq` / `eqbd` / `dl` / `ssh` |

#### Consumer Parameters — extractor & schema_mapper

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| imageName | Image name in the DSI registry | `{image name of extractor or consumer_mapper}` |
| srcContainerName | Source storage container name | `dp-consumer-stage` |
| mapperTopicName | Kafka topic name for the mapper stage | `dpn-consumer-trfm` |
| mapperContainerName | Storage container name for the mapper stage | `dp-consumer-trfm` |
| targetTopicName | Kafka topic name for the target stage | `dpn-consumer-target` |
| targetContainerName | Storage container name for the target stage | `dp-consumer-target` |

### Scheduling Configuration

Each data pipeline stage (adaptor, schema mapper, extractor) is triggered in one of two ways: **Automated Scheduling** or **Manual Scheduling**. Which one applies is controlled by the `SCHEDULER_BACKEND` parameter in that stage's `values.yaml`.

#### Automated Scheduling

Under automated scheduling, the pipeline stage is started by a software trigger rather than by an operator. The trigger mechanism is a pair of shared Kafka topics:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Set to `kafka-trigger` to enable software-triggered scheduling | `kafka-trigger` |
| PIPELINE_CONTROL_TOPIC | Kafka topic the pipeline stage listens on for a start signal | `dpn-pipeline-control` |
| PIPELINE_STATUS_TOPIC | Kafka topic the pipeline stage publishes run status/progress to | `dpn-pipeline-status` |
| EXECUTION_MODE | `automatic` — the stage self-schedules on `scheduleInterval` — or `manual` — the stage only runs when a message arrives on `PIPELINE_CONTROL_TOPIC` | `automatic` / `manual` |
| scheduleInterval | Polling interval in seconds. Only used when `EXECUTION_MODE: automatic` | `60` |

A message published to `PIPELINE_CONTROL_TOPIC` starts a run; the pipeline stage reports progress back on `PIPELINE_STATUS_TOPIC`. No operator action is required once this is configured — this is why it's referred to as automated.

> **Placeholder:** <Hari's input>

#### Manual Scheduling

Manual scheduling uses an orchestrator (Airflow) to start pipeline runs on a fixed schedule or on operator demand, instead of relying on the Kafka control-topic signal above.

```text
Root-Repository
  └── charts
        └── airflow/
              ├── values-<env>-dpn01.yaml   <- Environment-specific Airflow overrides
              └── dags/
                    └── {product_type}.py   <- One DAG per data product
```

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Set to `airflow` to hand scheduling control to Airflow instead of the Kafka control topic | `airflow` |

#### Onboarding a New Data Product — Scheduling Setup

Scheduling configuration is **not created automatically** — it must be set up alongside every new data product, in addition to the steps in [Producer Setup](#producer-setup):

1. Locate the sample/existing DAG closest to your new product's schema type under `charts/airflow/dags/` (this is the same sample-doc-style copy pattern used for Helm values in Producer Setup).
2. Copy that DAG file and rename it to match the new `product_type` (e.g. copying the sample `eq` DAG to create the DAG for a new product `xyz-sample-1`).
3. Update the copied DAG's references (topic names, container names, `product_type`) so they match the values used in that product's `values.yaml`.
4. Set `SCHEDULER_BACKEND` on the product's `values.yaml` to match the chosen approach — `kafka-trigger` for automated scheduling, or `airflow` for manual scheduling.

> **Placeholder:**  <Hari's input>

### Secrets Configuration

DSI Data Pipeline uses Kubernetes secrets by design, as this is a Bring-Your-Own (BYO) component. Two secret objects are created — one for Producer and one for Consumer.

> - Producer secret name: `producer-<processType>-dp-secret`
> - Consumer secret name: `consumer-<processType>-dp-secret`
> - `<processType>` is `file` for the file-based pathway in MVP. Future values may include `rest`, `topic`, etc.

**Producer Secrets**

The producer secrets contain the storage account connection strings and SAS tokens for each stage. The connection string format is:

```text
https://<storage-account>.blob.core.windows.net/?<sas-token>
```

The secret object `producer-<processType>-dp-secret` contains the following. If the same storage account is used for all stages, the same connection string value may be used for all three:

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Blob Storage connection string for the source storage account |
| MAPPER_CONNECTION_STRING | Blob Storage connection string for the mapper storage account |
| TARGET_CONNECTION_STRING | Blob Storage connection string for the target storage account |

Create the producer secret using the following command:

```bash
kubectl create secret generic producer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=MAPPER_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob mapper connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```

**Consumer Secrets**

The secret object `consumer-<processType>-dp-secret` contains the following. If the same storage account is used for all stages, the same connection string value may be used for all three:

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Blob Storage connection string for the consumer source storage account |
| MAPPER_CONNECTION_STRING | Blob Storage connection string for the consumer mapper storage account |
| TARGET_CONNECTION_STRING | Blob Storage connection string for the consumer target storage account |

Create the consumer secret using the following command:

```bash
kubectl create secret generic consumer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=MAPPER_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob mapper connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```


---

## DPN Data Store Configuration

The DPN Data Store consists of two sub-components:

- **Storage Blob / S3** — File storage for pipeline artefacts
- **Kafka Streaming Service** — Event streaming between DPN components

### Storage Blob / S3 Configuration

Storage Blob / S3 is the integration layer between the organisation's internal data source, the Federator Gateway, Data Pipelines, and the data destination.

The file-based integration pathway requires a set of storage containers (buckets) to be defined upfront, based on the data product template in use. The following naming convention is recommended when provisioning containers:

| Process | Source Container Name | Target Container Name |
|---------|-----------------------|-----------------------|
| adaptor | `{product_type}-stage` | `{product_type}-raw` |
| producer-mapper | `{product_type}-raw` | `{product_type}-target` |
| extractor | `dp-consumer-stage` | `dp-consumer-trfm` |
| consumer-mapper | `dp-consumer-trfm` | `dp-consumer-target` |

```text
Example container names (product_type = eq-sample-1):

  eq-sample-1-stage
  eq-sample-1-raw
  eq-sample-1-target
  dp-consumer-stage
  dp-consumer-trfm
  dp-consumer-target
```

> **Note:** Each storage container is mapped to a single data product type on the producer side. One data product type carries a single version of the file at any given time (e.g. the `eq-sample-1-raw` container contains `sample_1_v1.xml` only, until a version revision changes it to `sample_1_v2.xml`).

> **Note:** Storage containers are accessed asynchronously by the Federator Gateway and the organisation's data source and destination to pick up and deposit files.

---

### DPN Streaming Service (Kafka)

The DPN Streaming Service uses Kafka to emit events between DPN components, including the Data Pipeline adaptor, mapper, extractor, Federator Gateway, and organisation data source/destination endpoints.

The DPN data pipeline processes files by pushing streaming messages onto predefined Kafka topics. The proposed topic names are listed below. Organisations may customise the naming convention if required, but any topic name changes must be reflected in the CD pipeline configuration.

| Process | Source Topic Name | Target Topic Name | Bootstrap Server |
|---------|-------------------|-------------------|------------------|
| adaptor | N/A | `dpn-producer-{product_type}-raw` | `dpn-kafka-src:9092` |
| producer-mapper | `dpn-producer-{product_type}-raw` | `dpn-producer-{product_type}-target` | `dpn-kafka-src:9092` |
| extractor | N/A | `dpn-consumer-trfm` | `dpn-kafka-target:9092` |
| consumer-mapper | `dpn-consumer-trfm` | `dpn-consumer-target` | `dpn-kafka-target:9092` |

where **`product_type`** is a value such as `eq-sample-1` as described in previous sections.

These topics must be pre-created via the Kafka UI before the `dpn-data-pipeline` CI and CD tasks are executed.

The Kafka message structure used by the DSI Data Pipeline follows the convention below. This enables the Federator Server to locate and retrieve the file from the specified storage location during file transfer:

```json
{
  "sourceType": "{cloud type}",
  "storageContainer": "{name of the storage container where the file is placed}",
  "path": "folder-name/file-name"
}
```

Example:

```json
{
  "sourceType": "AZURE",
  "storageContainer": "eq-sample-1-target",
  "path": "eq-orga-sample_v1.xml"
}
```

> **Note:** Valid values for `sourceType` are `AZURE`, `GCP`, and `S3`. 

---

# Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
