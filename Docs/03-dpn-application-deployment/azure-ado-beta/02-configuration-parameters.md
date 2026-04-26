# DPN Deployment Configuration Guide

# Table of Contents

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
- [Component-Specific Configuration](#component-specific-configuration)  
  - [DPN Federator Gateway](#dpn-federator-gateway)  
    - [Helm Configuration](#helm-configuration)  
    - [Secrets Configuration](#secrets-configuration-1)  
  - [DPN Data Pipelines](#dpn-data-pipelines)  
    - [Helm Configuration](#helm-configuration-1)  
    - [Secrets Configuration](#secrets-configuration-2)  
    - [Storage Configuration](#storage-configuration)  
      - [Storage Connection String Secret](#storage-connection-string-secret)  
  - [DPN Security Services](#dpn-security-services)  
    - [Certificate Manager](#certificate-manager)  
      - [Helm Configuration](#helm-configuration-2)  
      - [Secrets Configuration](#secrets-configuration-3)  
    - [HashiCorp Vault](#hashicorp-vault)  
      - [Helm Configuration](#helm-configuration-3)  
      - [Secrets Configuration](#secrets-configuration-4)  
  - [DPN Storage Services](#dpn-storage-services)  
    - [Certificate P12 Storage](#certificate-p12-storage)  
      - [Helm Configuration](#helm-configuration-4)  
      - [Secrets Configuration](#secrets-configuration-5)  
    - [Data Pipeline Storage](#data-pipeline-storage)  
    - [Redis Cache Service](#redis-cache-service)  
  - [DPN Streaming Service (Kafka)](#dpn-streaming-service-kafka)
- [Review Notes](#review-notes) 

---

# Overview

Data Preparation Node (DPN) consists of following components in the DSI package

![DPN Components](/Docs/04-dpn-architecture/images/dpn_components.png)

- DPN Data Pipelines - Responsible for producing and consuming data products
- DPN Security Service 
  - Vault Service - Certificate regenaration for DSM communication and store
  - Digital Certificate Manager - Manages reclying of certificate at a predefined interval from DSI Management node
  - Shared File Service - SMB based Shared file storage between Federator Certificate Manager and Federator Gateway for storing certificate P12 files
- DPN Data Store Service 
  - Storage contains Storage accounts or S3 buckets to store the files produced by DPN data pipelines, certificate P12 files and Redis caching data
  - Streaming Service - DPN uses Kafka as streaming service for managing events and topics during data transmission
- DPN Federator Gateway - Responsible for DSM and DPN authentication, data transfer between DPNs 

DPN components are deployed using **Azure DevOps (ADO) pipelines**, as defined in the DPN repositories provided by DSI.  
These pipelines are organized into two stages:

- **Continuous Integration (CI)**
- **Continuous Deployment (CD)**

The CI pipeline builds the application artifacts, while the CD pipeline deploys them to the target infrastructure.

This document describes the configuration parameters required for deploying **DPN nodes on Azure Kubernetes Service (AKS)**.  
These parameters must be configured before running the deployment pipelines.

The configuration includes the following areas:

- DSI DSM endpoint configuration  
- Azure DevOps configuration  
- Secret configuration  
- Helm chart configuration
- Network and Ports configuration  

---

## Continuous Integration (CI)

The **Continuous Integration (CI)** pipeline performs the following activities:

1. Build the application source code.
2. Produce container image artifacts.
3. Tag the generated container images.
4. Push the images to a container registry.

DSI recommends using **Azure Container Registry (ACR)** for storing container images in Azure due to its seamless integration with Azure services and built-in security capabilities.

However, organizations may use alternative container registries if permitted by their internal network and security policies.

---

## Continuous Deployment (CD)

The **Continuous Deployment (CD)** pipeline deploys the container images to the **Azure Kubernetes Service (AKS)** cluster using Helm.

During deployment, the pipeline performs the following steps:

1. Authenticate with Azure using the configured service connection.
2. Retrieve credentials for the target AKS cluster.
3. Validate Helm charts using helm-lint.
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

These endpoints are publicly accessible to simplify integration and testing. Organizations must configure their pipelines to use the **appropriate endpoint for the corresponding deployment environment**.

| Environment | Component | URL |
|-------------|-----------|-----|
| Dev | Authentication | https://auth-mtls.dsm01.dsidev.neso.energy |
| Dev | Management Node | https://management.dsm01.dsidev.neso.energy |
| Dev | DSI DPN Producer | https://producer.dpn01.dsidev.neso.energy |
| Dev | DSI DPN Consumer | https://consumer.dpn01.dsidev.neso.energy |
| Integration Test | Authentication | https://auth-mtls.dsm01.dsitest.neso.energy |
| Integration Test | Management Node | https://management.dsm01.dsitest.neso.energy |
| Integration Test | DSI DPN Producer | https://producer.dpn01.dsitest.neso.energy |
| Integration Test | DSI DPN Consumer | https://consumer.dpn01.dsitest.neso.energy |
| Pre-Production | Authentication | https://auth-mtls.dsm01.dsipre.neso.energy |
| Pre-Production | Management Node | https://management.dsm01.dsipre.neso.energy |
| Pre-Production | DSI DPN Producer | https://producer.dpn01.dsipre.neso.energy |
| Pre-Production | DSI DPN Consumer | https://consumer.dpn01.dsipre.neso.energy |
| Production | Authentication | https://auth-mtls.dsm01.dsi.neso.energy |
| Production | Management Node | https://management.dsm01.dsi.neso.energy |
| Production | DSI DPN Producer | https://producer.dpn01.dsi.neso.energy |
| Production | DSI DPN Consumer | https://consumer.dpn01.dsi.neso.energy |

---

## Azure DevOps Configuration

The provided pipelines require the following configuration to perform **CI and CD operations**.

### Node Pool Set Up

The provided pipelines has been referred with default Microsoft hosted agent pool 'ubuntu latest' for execution of the pipelines. 

However, DSI **recommends using a dedicated self-hosted agent pool**.  
This provides better control over:

- Security
- Network access
- Deployment environment management

Refer to the official Microsoft documentation for Linux node pool agent setup:

https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent

If a self-hosted agent pool is configured, update the pipeline definition as follows.

#### Existing Configuration

pool:
  
    vmImage: 'ubuntu-latest'

#### Updated Configuration

pool:
  
    name: '[agent-pool-name]'
```

---

### Azure Environment Configuration

For the pipelines to run, the following parameters need to be updated in the **config.json** file under azure pipelines folder. Refer the config.json file as below. 

```text
Root-Repository/
└──.pipelines/ 
     └──azure-pipelines/
          └── config/
                └── config.json
```
| Parameter | Description | Example Value |
|-----------|-------------|---------------|
| AZURE_SUBSCRIPTION | Azure subscription ID where the infrastructure is deployed | `<A valid Azure subscription ID>` |
| SERVICE_CONNECTION | Service connection name for deployment | `<A valid Azure subscription ID>` |
| RESOURCE_GROUP | Azure resource group containing the AKS cluster | `<A valid resource group name e.g. rg-prd-uks-dpn-01>` |
| AKS_CLUSTER | Name of the Azure Kubernetes Service cluster | `<AKS cluster name e.g. aks-prd-uks-dpn-01>` |
| NAMESPACE | Name of the Kubernetes cluster namespace for container deployment | `<A valid namespace name e.g.ns-dpn-01>` |
| KEY_VAULT_NAME | Azure Key Vault used to store secrets and certificates | `<A valid Azure Key Vault name e.g. akv-prd-uks-dpn-01>` |
| BASE_REGISTRY | Base registry path used by deployment images | `<image-registry-url>` |
| ENV_NAME | The deployment environment abbreviation | `<A valid environment qualifier .e.g dev, sit, ppd, prd etc>` |
| VALUES_FILE | Helm values file name for use in pipeline | `<A valid helm values file as present in the Helm chart location. e.g values.yaml>` |

---

## Secrets Configuration (Global)

Sensitive credentials must **not be stored in source code repositories**.  
They should be stored securely in vaults:

- Hashicorp Vault provided with the DSI DPN package
- Azure Key Vault (cloud specific if DPN chooses to use Azure specific product)

The secret variables required by this DPN package includes:

| Variable | Description |
|----------|-------------|
| CLIENT_P12_PASSWORD | Password for the federator client certificate keystore |
| CLIENT_TRUSTSTORE_PASSWORD | Password for the federator client truststore |
| SERVER_P12_PASSWORD | Password for the federator server certificate keystore |
| SERVER_TRUSTSTORE_PASSWORD | Password for the federator server truststore |
| IDP_CLIENT_SECRET | Client secret used for DSI DSM Identity Provider authentication |
| idp.keystore.password | Password for IDP keystore |
| idp.truststore.password | Password for IDP truststore |
| BLOB_CONNECTION_STRING | A SAS Token for connecting to Blob Storage Account |

---

### Certificate Handling Note

Organizations must securely store:

- The **P12/PFX certificate** issued by the DSI DSM Certificate Authority (keystore)
- The **DSI certificate chain** (truststore)

Refer to the installation guide for detailed instructions on **keystore and truststore generation**.

As of now the same certificate file is expected to be kept in all the keystores unless specifically required to segregate multiple certificates in future. 

---

## Network and Ports Configuration

DPN connectivity requirements for ports and protocols. This also covers the agent pool requirements for building the DPN code. 

![DPN Ports & Protocols](/Docs/04-dpn-architecture/images/dpn_ports_and_protocols.png)

The following Firewall rules should be applied from the Organizations before installing DPN.

| Source IP Address | Source VNET | Source Subnet | Destination IP Address / Zone / URL | Destination VNET | Destination Subnet | Protocol | Port(s) | Traffic Flow |
|-------------------|-------------|---------------|--------------------------------------|------------------|-------------------|----------|---------|--------------|
| Node pool agent VM IP | Node Pool VM VNET name | Node Pool VM subnet name | packages.confluent.io/* | N/A | N/A | TLS | 443 | Outbound |
| Node pool agent VM IP | Node Pool VM VNET name | Node Pool VM subnet name | registry-1.docker.io/* <br>auth.docker.io/* ,<br>production.cloudflare.docker.com,<br>index.docker.io/* | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes Subnet IP range | DPN Kubernetes VNET name | DPN Kubernetes Subnet name | auth-mtls.dsm01.dsi(xxx).neso.energy | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes Subnet IP range | DPN Kubernetes VNET name | DPN Kubernetes Subnet name | management.dsm01.dsi(xxx).neso.energy | N/A | N/A | TLS | 443 | Outbound |
|  DPN Kubernetes Subnet IP range | DPN Kubernetes VNET name | DPN Kubernetes Subnet name | Organization specific URL to connect from DPN | N/A | N/A | TLS | 50051 | Bi-directional |

**Note** The Organization specific URL defines the target Organization with which Data sharing to happen. These would require the FW opening from both Organization's perspective. The dsi(xxx) refers to dsidev, dsitest, dsipre and dsi (production) environments.

DSI DPN uses HTTP/2 traffic over GRPC in port 50051. The HTTP/2 traffic would require a TCP passthrough to the Layer 4 Load balancer service instead of any Layer 7 load balancing.

---

# Component-Specific Configuration

## DPN Federator Gateway
Purpose and introduction
<Anik>

### Helm Configuration
<Anik>


The dpn-federator-gateway repository is provided with a helm chart values file for customizing the deployment as per Organization requirement. The Helm chart uses **environment-specific values files** to configure the DPN deployment.The values.yaml file is located in the following section as mentioned below.

```text
Root-Repository
  └── charts
    └── values.yaml
```

**Note** - The helm values.yaml file can be replicated to perform multiple environment or multiple dpn deployment. e.g. dpn01-values.yaml or dpn02-values.yaml. Organization need to specifi the values.yaml file name in the pipeline configuration as mentioned in Azure DevOPS Configuration above.

DSI proposes only selective changes in the values file unless required by Organizations but provides the provision to customize other parameters if required.

| Parameters | Purpose |
|-------------|------------------|
| repository | `<complete url of the image registry>` |
| namespace | `<name of the kubernetes namespace>` |
| management-node | `<complete url of the DSI DSM Management node >` |
| clientId | `<Client ID received from DSM to establish DPN connection>` |
| replica | `<The count of replica in each container>` |
| STORAGE_ACCOUNT_URL | `<The source storage account to read the file>` |
| SOURCE_CONTAINER_NAME | `<The source container name to read the file from>` |
| TARGET_CONTAINER_NAME | `<The target container name to read the file from>` |
| BLOB_NAME | `<The name of the file to process from Storage account>` |

The SOURCE_TOPIC, TARGET_TOPIC for dpn-data-pipeline at each stage is (TBD). 

### Secrets Configuration
<Anik>
In progress

## DPN Data Pipelines
Purpose and introduction
<Tamanna>

### Helm Configuration
<Tamanna>

In progress. 
{schema type}

### Secrets Configuration
<Tamanna>

In progress

### Storage Configuration

The Data pipeline file based integration pathway require a number of storage account containers (buckets) to be defined upfront based on the data product template being followed to produce the data files. The following convention is suggested while provisioning the containers. 

| Process | source container name | target container name |
|------|-------------|----------------------------|
|adaptor|{dataproducttype}-stage|{dataproducttype}-raw|
|producer-mapper|{dataproducttype}-raw|{dataproducttype}-target|
|extractor|dp-consumer-stage|dp-consumer-trfm|
|consumer-mapper|dp-consumer-trfm|dp-consumer-target|

**Note:** <br>dataproducttype is defined by DPN Organization based on specific schema type EQ, EQBD, DL etc and could be generic. 

```text
Example container names following this convenion. 

- eq-sample-1-stage
- eq-sample-1-raw
- eq-sample-1-target
- dp-consumer-stage
- dp-consumer-trfm
- dp-consumer-target
```

Each storage container is mapped to a single data product type at the producer side. It is also expected that one data product type would always carry a single version of the file that is published as data product. e.g. eq-sample-1-raw container to contain sample_1_v1.xml file only until there is a version revision to it to sample_1_v2.xml. 

#### Storage Connection String Secret ####

Ensure the following secrets are defined as part of the configuration document to read the source file and store the destination file when received:

The three different connection strings are provided considering the flexibility of using different storage accounts / buckets in each step if required. Otherwise, the same connection string information can be passed for each of them. 

- **srcConnectionString** - Producer and consumer read files using this connection in adpator and extractor
- **mapperConnectionString** - Producer and consumer write files using this connection in adaptor and extractor and also reads file in next mapper processes.
- **targetConnectionString** - Producer and consumer mappers write files to destination using this connection string

The value must contain a **valid Azure Storage account level SAS token** with container read, write and list permission.The duration should follow Organization security guideline.

Example: https://<storage-account>.blob.core.windows.net/?<sas-token>

---

## DPN Security Services
<Anuran>

### Certificate Manager
Purpose and introduction
<Anuran>

#### Helm Configuration
<Anuran>
In progress

#### Secrets Configuration
<Anuran>
In progress


### HashiCorp Vault Configuration
Purpose and introduction
<Anuran>

#### Certificate Load Steps in Vault
<Anuran>

#### Helm Configuration
<Anuran>
In progress

#### Secrets Configuration
<Anuran>
In progress

---

## DPN P12 Shared Storage Service
Purpose and introduction
<Anuran>

### Certificate P12 Storage as File Share
<Anuran>

#### Helm Configuration
<Anuran>
In progress

#### Secrets Configuration
<Anuran>
In progress

### Data Pipeline Storage

[Go to Storage Configuration for DPN Data Pipeline](02-configuration-parameters.md#storage-configuration)

### Redis Cache Service
Purpose and introduction
<Anuran>
In progress

## DPN Streaming Service (Kafka)

The DPN data pipeline process files by pushing a streaming message on predefined kafka topics as source and destination. The proposed topic names are mentioned here but Organizations can customize to a different naming convention if they wish. However, any change in topic name should be updated in the configuration on the CD pipeline. 

```text
| Process | Source Topic Name | Target Topic Name | Bootstrap Sever |
|------|-------------|----------------------------|-----------------|
| adaptor | NA | dpn-producer-{dataproducttype}-raw | kafka-src:9092 |
| producer-mapper |  dpn-producer-{dataproducttype}-raw | dpn-producer-{dataproducttype}-target | kafka-src:9092 |
| extractor | NA | dpn-consumer-trfm | kafka-target:9092 |
| consumer-mapper | dpn-consumer-trfm | dpn-consumer-target| kafka-target:9092 |

where **dataproducttype** examples like eq-sample-1.
```
These topics must be pre-created from the kafka-ui as mentiond above and before execution of the dpn-data-pipeline CI and CD tasks.

The structure of the message pushed by DSI Data Pipeline follows this convention below. This enables Federator server to pick up the file from the specified location during file transfer. 

{"sourceType": "{cloud type}",<br>
"storageContainer": "{Name of the Storage Container where file is placed}",<br>
"path": "folder name/file name"}

example: 

```text
{"sourceType": "AZURE",
"storageContainer": "eq-sample-1-target",
"path": "eq-orga-sample_v1.xml"}

Valid cloud types are "AZURE, GCP and S3".
```

---

# Review Notes

| Review Date | Last Reviewed By | Status | Version |
|------------|----------------|--------|--------|
| 15-Mar-2026 | DSI Assurance | Draft | V0.1.0 |
