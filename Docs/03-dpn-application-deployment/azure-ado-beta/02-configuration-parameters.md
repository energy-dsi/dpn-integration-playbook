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
  - [Secrets Configuration (Global)](#secrets-configuration-global)
    - [Certificate Handling Note](#certificate-handling-note)
  - [Network and Ports Configuration](#network-and-ports-configuration)
- [Component-Specific Configuration](#component-specific-configuration)
  - [DPN Federator Gateway Configuration](#dpn-federator-gateway)
    - [Helm Configuration](#helm-configuration)
    - [Secrets Configuration](#secrets-configuration-1)
  - [DPN Data Pipelines Configuration](#dpn-data-pipelines)
    - [Helm Configuration](#helm-configuration-1)
    - [Secrets Configuration](#secrets-configuration-2)
    - [Storage Configuration](#storage-configuration)
  - [DPN Security Services Configuration](#dpn-security-services)
    - [Federator Certificate Manager](#federator-certificate-manager)
    - [HashiCorp Vault](#hashicorp-vault)
  - [DPN P12 Shared Storage Service Configuration](#dpn-p12-shared-storage-service)
    - [Certificate P12 Storage as File Share](#certificate-p12-storage-as-file-share)
    - [Data Pipeline Storage](#data-pipeline-storage)
    - [Redis Cache Service](#redis-cache-service)
  - [DPN Streaming Service (Kafka)](#dpn-streaming-service-kafka)
- [Review Notes](#review-notes)

---

# Overview

Data Preparation Node (DPN) consists of the following components in the DSI package:

![DPN Components](/Docs/04-dpn-architecture/images/dpn_components.png)

- **DPN Data Pipelines** — Responsible for producing and consuming data products.
- **DPN Security Service**
  - Vault Service — Certificate regeneration for DSM communication and storage.
  - Digital Certificate Manager — Manages recycling of certificates at a predefined interval from the DSI Management Node.
  - Shared File Service — SMB-based shared file storage between the Federator Certificate Manager and Federator Gateway for storing certificate P12 files.
- **DPN Data Store Service**
  - Storage — Contains storage accounts or S3 buckets to store files produced by DPN data pipelines, certificate P12 files, and Redis caching data.
  - Streaming Service — DPN uses Kafka as a streaming service for managing events and topics during data transmission.
- **DPN Federator Gateway** — Responsible for DSM and DPN authentication, and data transfer between DPN nodes.

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
- Network and ports configuration

---

## Continuous Integration (CI)

The **Continuous Integration (CI)** pipeline performs the following activities:

1. Build the application source code.
2. Produce container image artifacts.
3. Tag the generated container images.
4. Push the images to a container registry.

DSI recommends using **Azure Container Registry (ACR)** for storing container images in Azure due to its seamless integration with Azure services and built-in security capabilities.

However, organisations may use alternative container registries if permitted by their internal network and security policies.

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

These endpoints are going to be publicly accessible to simplify integration and testing. Organisations must configure their pipelines to use the **appropriate endpoint for the corresponding deployment environment** provided by DSI.

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

The provided pipelines are configured with the default Microsoft-hosted agent pool `ubuntu-latest` for pipeline execution.

However, DSI **recommends using a dedicated self-hosted agent pool**.  
This provides better control over:

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

For the pipelines to run, the following parameters must be updated in the **`Environment wise config.json`** file located under the Azure Pipelines folder:

Environment examples are dev, sit, uat, preprod, prod etc.

```text
Root-Repository/
└── .pipelines/
     └── azure-pipelines/
          └── config/
                └── <env>-dpn01.json
```

| Parameter | Description | Example Value |
|-----------|-------------|---------------|
| AZURE_SUBSCRIPTION | Azure subscription ID where the infrastructure is deployed | `<A valid Azure subscription ID>` |
| SERVICE_CONNECTION | Service connection name for deployment | `<A valid Azure service connection name>` |
| RESOURCE_GROUP | Azure resource group containing the AKS cluster | `<e.g. rg-prd-uks-dpn-01>` |
| AKS_CLUSTER | Name of the Azure Kubernetes Service cluster | `<e.g. aks-prd-uks-dpn-01>` |
| NAMESPACE | Kubernetes cluster namespace for container deployment | `<e.g. ns-dpn-01>` |
| KEY_VAULT_NAME | Azure Key Vault used to store secrets and certificates | `<e.g. akv-prd-uks-dpn-01>` |
| BASE_REGISTRY | Base registry path used by deployment images | `<image-registry-url>` |
| ENV_NAME | Deployment environment abbreviation | `<e.g. dev, sit, ppd, prd>` |
| VALUES_FILE | Helm values file name for use in the pipeline | `<e.g. values.yaml>` |

---

## Secrets Configuration (Global)

Sensitive credentials must **not be stored in source code repositories**.  
They must be stored securely in one of the following vaults:

- HashiCorp Vault — provided with the DSI DPN package
- Azure Key Vault — cloud-specific option for organisations using Azure

The secret variables required by this DPN package are:

| Variable | Description |
|----------|-------------|
| CLIENT_P12_PASSWORD | Password for the federator client certificate keystore |
| CLIENT_TRUSTSTORE_PASSWORD | Password for the federator client truststore |
| SERVER_P12_PASSWORD | Password for the federator server certificate keystore |
| SERVER_TRUSTSTORE_PASSWORD | Password for the federator server truststore |
| IDP_CLIENT_SECRET | Client secret used for DSI DSM Identity Provider authentication |
| IDP_KEYSTORE_PASSWORD | Password for the IDP keystore |
| IDP_TRUSTSTORE_PASSWORD | Password for the IDP truststore |
| SRC_CONNECTION_STRING | A SAS token for connecting to the source Blob Storage account |
| MAPPER_CONNECTION_STRING | A SAS token for connecting to the mapper Blob Storage account |
| TARGET_CONNECTION_STRING | A SAS token for connecting to the target Blob Storage account |

---

### Certificate Handling Note

Organisations must securely store:

- The **P12/PFX certificate** issued by the DSI DSM Certificate Authority (keystore)
- The **DSI certificate chain** (truststore)

Refer to the installation guide for detailed instructions on **keystore and truststore generation**.

The same certificate file is currently expected to be used across all keystores unless specifically required to segregate multiple certificates in the future.

---

## Network and Ports Configuration

DPN connectivity requirements for ports and protocols. This also covers the agent pool requirements for building the DPN code.

![DPN Ports & Protocols](/Docs/04-dpn-architecture/images/dpn_ports_and_protocols.png)

The following firewall rules must be applied by the organisation before installing DPN:

| Source IP Address | Source VNET | Source Subnet | Destination IP Address / Zone / URL | Destination VNET | Destination Subnet | Protocol | Port(s) | Traffic Flow |
|-------------------|-------------|---------------|--------------------------------------|------------------|-------------------|----------|---------|--------------|
| Node pool agent VM IP | Node Pool VM VNET name | Node Pool VM subnet name | packages.confluent.io/* | N/A | N/A | TLS | 443 | Outbound |
| Node pool agent VM IP | Node Pool VM VNET name | Node Pool VM subnet name | registry-1.docker.io/*<br>auth.docker.io/*<br>production.cloudflare.docker.com<br>index.docker.io/* | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes Subnet IP range | DPN Kubernetes VNET name | DPN Kubernetes Subnet name | auth-mtls.dsm01.dsi(xxx).neso.energy | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes Subnet IP range | DPN Kubernetes VNET name | DPN Kubernetes Subnet name | management.dsm01.dsi(xxx).neso.energy | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes Subnet IP range | DPN Kubernetes VNET name | DPN Kubernetes Subnet name | Organisation-specific URL for DPN-to-DPN data sharing | N/A | N/A | TLS | 50051 | Bi-directional |

> **Note:** The organisation-specific URL defines the target organisation with which data sharing will occur. These firewall rules require opening from both organisations' perspectives. The `dsi(xxx)` notation refers to `dsidev`, `dsitest`, `dsipre`, and `dsi` (production) environments.<br><br> DPN uses HTTP/2 traffic over gRPC on port **50051**. HTTP/2 traffic requires TCP passthrough to a Layer 4 load balancer rather than Layer 7 load balancing.

---

# Component-Specific Configuration

## DPN Federator Gateway Configuration

The DPN Federator Gateway handles all secure communication between your DPN node and other DPN nodes or the DSI DSM platform. It ensures data is sent and received safely, only to and from trusted parties.

The gateway does not operate in isolation. It depends on a set of supporting services that are all deployed together in a single Helm release into the same Kubernetes cluster. The following components are deployed and their relationships are described below:

| Component | Purpose |
|-----------|---------|
| Zookeeper Source | Coordination service for the Source Kafka cluster. Must be running before Kafka Source starts. |
| Zookeeper Target | Coordination service for the Target Kafka cluster. Must be running before Kafka Target starts. |
| Kafka Source | Message queue where the DPN's outgoing data is staged. The Federator Server reads from here to send data out. |
| Kafka Target | Message queue where incoming data from other DPNs is delivered. The Federator Client writes received data here. |
| Kafka UI | A web dashboard to monitor and inspect messages in both Kafka clusters. Useful during testing. |
| Redis | A fast in-memory store used by both the Federator Server and Client for caching and tracking data offsets. |
| Federator Server | Listens on port 50051 for incoming data connections from other DPN nodes and reads from Kafka Source. |
| Federator Client | Connects outward to a remote Federator Server and writes received data into Kafka Target. |

All of the above are deployed together in a single pipeline run using one Helm release (`dpn-platform`).

### Helm Configuration

The `dpn-federator-gateway` repository includes a Helm chart values file for customising the deployment per organisation requirements. The Helm chart uses **environment-specific values files** to configure the DPN deployment. The values files are located as follows:

```text
Root-Repository
  └── charts
    └── dpn-platform/
            ├── values.yaml             ← default settings for all components (do not edit directly)
            └── values-<env>-dpn01.yaml ← environment-specific overrides for all components
```

> **Note:** The `values.yaml` file can be replicated for multiple environments or DPN deployments (e.g. `values-dev-dpn01.yaml`, `values-sit-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section above.<br><br>
Only a single pipeline run is required. It applies `values-dev-dpn01.yaml` on top of the base `values.yaml` and deploys all components together in a single Helm release named `dpn-platform`.<br><br>
DSI proposes only selective changes to the values file unless required by the organisation, but provides the provision to customise other parameters if needed.

Open `values-<env>-dpn01.yaml` and update the following parameters:

**Note:** There are multiple configurations which can be editable. However, DSI recommends to modify the following ones as bare minimum.

|         Parameter       |              Purpose         |         Example Value        |
|-------------------------|------------------------------|------------------------------|
| redis.image.repository | Container registry address where the Redis image is stored | `<DSI public image registry>/redis` |
| redis.image.tag | Redis image tag | `7.2` |
| zookeeper.image.repository | Container registry address where the Zookeeper image is stored | `<DSI public image registry>/cp-zookeeper` |
| zookeeper.image.tag | Zookeeper image tag | `7.5.3` |
| kafka.image.repository | Container registry address where the Kafka image is stored | `<DSI public image registry>/cp-kafka` |
| kafka.image.tag | Kafka image tag | `7.5.3` |
| kafkaUI.image.repository | Container registry address where the Kafka UI image is stored | `<DSI public image registry>/kafka-ui` |
| federatorServer.image.repository | Container registry address where the Federator Server image is stored | `<DSI public image registry>/dpn-federator-server` |
| federatorServer.image.tag | Federator Server image tag | `<latest image version published>` |
| federatorServer.service.loadBalancerIP | Fixed internal IP assigned to the Server. Obtain from the Kubernetes service external IP after first deployment. | `<A fixed load balancer private IP in your network>` |
| federatorServer.config.management_node_base_url | DSI DSM Management Node URL for your environment | See [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration) i.e. https://management.dsm01.dsiXXX.neso.energy |
| federatorServer.idp.clientId | Client ID provided by DSI to identify this DPN node | `i.e.7af382c4-1759-4938-b596-c4c5c572304e` |
| federatorServer.idp.jwksUrl | DSI identity system address used to verify identity tokens | See [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration) i.e.  https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/certs |
| federatorServer.idp.tokenUrl | DSI identity system address used to request access tokens | See [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration) i.e. https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token|
| federatorClient.image.repository | Container registry address where the Federator Client image is stored | `<DSI Image Repository>/dpn-federator-client` |
| federatorClient.image.tag | Federator Client image tag | `<latest image version publishes by DSI>` |
| federatorClient.service.loadBalancerIP | Fixed internal IP assigned to the Client. Obtain from the Kubernetes service external IP after first deployment. | `<A fixed load balaner private IP in your network>` |
| federatorClient.config.management_node_base_url | DSI DSM Management Node URL for your environment | See [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration) i.e. https://management.dsm01.dsiXXX.neso.energy |
| federatorClient.idp.clientId | Client ID provided by DSI to identify this DPN node | `i.e. 9c4f2e8a-6b21-4d73-9a5e-1f6b8c7a4d92` |
| federatorClient.idp.jwksUrl | DSI identity system address used to verify identity tokens | See [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration) i.e.  https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/certs |
| federatorClient.idp.tokenUrl | DSI identity system address used to request access tokens | See [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration) i.e. https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token |

**Shared Key Vault parameters** 

DPN Federator uses Key Vault to store the secret for both Federator Server and Client in the values.yaml file.However, Organizations may opt to use Kubernetes secret or other secret stores to refer the secret credentials. 
 
| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| keyvault.name | Azure Key Vault name where all secrets are stored | `kv-dpn-<env>-<region>-<seq no>` |
| keyvault.clientID | Managed Identity client ID that allows the cluster to read from Key Vault | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| keyvault.tenantId | Organisation's Azure Active Directory tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |

### Secrets Configuration

Secrets must never be written into the values file or the code repository. Organizations need to  store the secrets securely using Hashicorp Vault or Azure Key Vault or any other choice of secret management procedure but allow the secret to be pulled in automatically when the pods start up.

DSI package provides a reference implementation using Azure Key Vault. The secret templates are located here for reference in the dpn-federator-gateway repository:

```text
dpn-federator-gateway/
└── charts/
      └── dpn-platform/
            └── templates/
                  ├── federator-server-secretproviderclass.yaml
                  └── federator-client-secretproviderclass.yaml
                  └── federator-idp-secretproviderclass.yaml
```

**Federator Server Secrets** (provision in: Azure Key Vault)

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| SERVER-P12-PASSWORD | Password that unlocks the server's certificate file. Used to prove the server's identity to any connecting client. | `changeit` |
| SERVER-TRUSTSTORE-PASSWORD | Password for the server's trust list file. Used to verify the identity of connecting clients. | `changeit` |

**Federator Client Secrets** (provision in: Azure Key Vault)

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| CLIENT-P12-PASSWORD | Password that unlocks the client's certificate file. Used to prove the client's identity when connecting to the Federator Server. | `changeit` |
| CLIENT-TRUSTSTORE-PASSWORD | Password for the client's trust list file. Used to verify it is connecting to the correct server. | `changeit` |

**Federator IDP Secrets** (provision in: Azure Key Vault)

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| IDP-KEYSTORE-PASSWORD | Password that unlocks the IDP keystore certificate file. Used to prove the client's identity when connecting to the IDP Service. | `changeit` |
| IDP-TRUSTSTORE-PASSWORD | Password for the IDP's trust list file. Used to verify it is connecting to the correct server. | `changeit` |
| IDP-CLIENT-SECRET | The secret to be used to authenticate Federator client to DSI Authentication service and provided in DSI package. | `xxxxxxxxXXXXX` |

---

## DPN Data Pipelines Configuration

### Introduction and Purpose

The DPN Data Pipeline ensures secure and governed data exchange by validating and transforming datasets before and after transmission. It applies schema assurance, security labelling, and controlled processing across producer and consumer stages. This ensures all shared data conforms to required schemas, security classifications, and governance standards, enabling reliable and compliant data sharing.

### Helm Configuration

The Helm configuration for the DPN deployment is segregated between the Producer and Consumer domains. 
<br>
- On the producer side, Helm values are defined for each schema type to configure the Adaptor and Schema Mapper, ensuring source-specific validation, governance, and transmission rules.
<br> 
- On the consumer side, separate Helm values files are used for Extractor and Schema Mapper to validate and deliver data according to target requirements. This separation ensures that each pipeline stage operates with file-type-specific schemas and policies while maintaining clear isolation between producer and consumer configurations.

**Data Pipeline Blueprints**

DSI Package provides different schema type blueprints using which Organizations may prepare the data products. Organizations should not modify the values.yaml in the blueprints. The blueprints folder is used as a class of integration pathway e.g. file/topic/api etc and the different schema types in it. If an Organizations publishes a data product in file based integration pathway then they should follow the below steps to configure producer and consumer.

```text
Root-Repository
  └── blueprints
    └── consumer
      └── file
        └── extractor
          └── charts
            └── values.yaml
        └── schema_mapper
          └── charts
            └── values.yaml
    └── producer
      └── file
        └── dl
          └── adaptor
            └── charts
              └── values.yaml
          └── schema_mapper
            └── charts
              └── values.yaml
        └── eq
          └── adaptor
            └── charts
              └── values.yaml
          └── schema_mapper
            └── charts
              └── values.yaml
        └── eqbd
          └── adaptor
            └── charts
              └── values.yaml
          └── schema_mapper
            └── charts
              └── values.yaml
        └── ssh
          └── adaptor
            └── charts
              └── values.yaml
          └── schema_mapper
            └── charts
              └── values.yaml
```

**Producer Configuration** 

The following steps are required when an Organization produces a data product.

- Copy the respective schema folder from  e.g. eq/eqbd/dl/ssh from the path **Root-Repository/blueprints/producer/file/{schema_type}** to **Root-Repository/producer/file/{schema_type}**
- Rename {schema_type} to {product_type} i.q. rename eq to a valid data product name. Only hyphen is allowed in name and no other special characters. e.g. eq-dp-01 or eqproduct1. 
- The {product_type} needs to be passed during the CI pipeline. Hence Organization must ensure the product_type matches the parameter value during the CI run

```text
Root-Repository
  └── producer
    └── file
        └── {data-product-name}  <- Replace {schema type eq/eqbd} to data product name eq-sample-1
            └── adaptor
              └── charts
                └── values.yaml
            └── schema_mapper
              └── charts
                └── values.yaml
```
**Consumer Configuration**

The followng step is required when Organization is consuming data products.

- copy the consumer folder from the path **Root-Repository/blueprints/consumer** to **Root-Repository/consumer** as is without any change.

```text
Root-Repository
  └── consumer
    └── file
      └── extractor
        └── charts
          └── values.yaml
      └── schema_mapper
        └── charts
          └── values.yaml
```

> **Note:** The `values.yaml` file can be replicated for multiple environments or DPN deployments (e.g. `values-<env>-dpn01.yaml`, `values-<env>-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section above.

DSI proposes only selective changes to the values file unless required by the organisation, but provides the provision to customise other parameters if needed.

#### Producer Configuration — dl, eq, eqbd, and ssh (adaptor & schema_mapper)

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| cloudProviderType | Defines the cloud provider to run on (`azure`, `aws`, or `gcp`) | `azure` |
| imageName | Image name in the DSI registry | `{image name of adaptor and schema mapper}` |
| productType | Product type name — alphanumeric characters and hyphens only (no other special characters) | `eq-sample-1` |
| srcContainerName | Source container name | `eq-sample-1-stage` |
| mapperTopicName | Kafka topic for the mapper stage | `dpn-producer-eq-sample-1-raw` |
| mapperContainerName | Storage container for the mapper stage | `eq-sample-1-raw` |
| targetTopicName | Kafka topic for the target stage | `dpn-producer-eq-sample-1-target` |
| targetContainerName | Storage container for the target stage | `eq-sample-1-target` |
| orgName | Organisation name | `orga` |
| schemaType | Schema type | `eq` / `eqbd` / `dl` / `ssh` |

> **Note:** 

- Storage container name, Kafka topic name and product type name should not have any special character other than (-) if required. Any other special character may impact the pipeline execution later
- Organization Name can be abbreviated without any space between it
- Schema type should match the blueprint schema type exactly i.e. eq/eqbd/dl/ssh
- The AWS configurations should be left empty, DSI Data Pipeline has validator based on Cloud Provider Type parameter value either azure, aws or gcp. Any configuration mismatch will be detected for cloud provider type against the connection parameters

#### Consumer Configuration — extractor & schema_mapper

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| cloudProviderType | Defines the cloud provider to run on (`azure`, `aws`, or `gcp`) | `azure` |
| imageName | Image name in the DSI registry | `{image name of extractor or consumer mapper}` |
| srcContainerName | Source container name | `dp-consumer-stage` |
| mapperTopicName | Kafka topic for the mapper stage | `dpn-consumer-trfm` |
| mapperContainerName | Storage container for the mapper stage | `dp-consumer-trfm` |
| targetTopicName | Kafka topic for the target stage | `dpn-consumer-target` |
| targetContainerName | Storage container for the target stage | `dp-consumer-target` |

### Secrets Configuration

DSI Data pipeline uses Kubernetes secret purposefully as it is left over as BYO component by design. There are two secret objects created one for Producer and one for Consumer as below:

> - Producer secret name: `producer-<processType>-dp-secret`
> - Consumer secret name: `consumer-<processType>-dp-secret`
> - `<processType>` is `file` for file based federator in MVP. In future it may be `file`, `rest`, `topic`, etc.

**Producer Secrets**
The producer secrets are primarily the different storage account connection string along with SAS token.

```text
Example: https://<storage-account>.blob.core.windows.net/?<sas-token>
```
The secret object `producer-<processType>-dp-secret` contains the following secrets applicable to producer configuration. Organization may choose to use the same storage account or differnet storage accounts for the adaptor and mapper process. The same value can be copied in all the three secrets if the same storage account is used. 

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Contains the Blob Storage connection strings for source storage account |
| MAPPER_CONNECTION_STRING | Contains the Blob Storage connection strings for mapper storage account |
| TARGET_CONNECTION_STRING | Contains the Blob Storage connection strings for target storage account |

Create the producer secret using the following command:

```bash
kubectl create secret generic producer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=MAPPER_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob mapper connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```
**Consumer Secrets**

The secret object `consumer-<processType>-dp-secret` contains the following secrets applicable to consumer configuration. Organization may choose to use the same storage account or differnet storage accounts for the extractor and mapper process. The same value can be copied in all the three secrets if the same storage account is used. 

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Contains the Blob Storage connection strings for source storage account |
| MAPPER_CONNECTION_STRING | Contains the Blob Storage connection strings for mapper storage account |
| TARGET_CONNECTION_STRING | Contains the Blob Storage connection strings for target storage account |

Create the consumer secret using the following command:

```bash
kubectl create secret generic consumer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=MAPPER_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob mapper connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```

**AWS Secrets**
AWS uses the following secrets but during Azure deployment those secrets are not used. Organizations may keep the values as space in values.yaml file while deployment to Azure platform. 

```bash
kubectl create secret generic aws-access-secret --from-literal=AWS_ACCESS_KEY_ID="$(echo -n '<your aws access key id>' | base64)" --from-literal=AWS_SECRET_ACCESS_KEY="$(echo -n '<your aws secret access key>' | base64)" -n <your namespace name>
```

### Storage Configuration

The data pipeline file-based integration pathway requires a number of storage account containers (buckets) to be defined upfront, based on the data product template being used to produce data files. The following naming convention is suggested when provisioning containers:

| Process | Source Container Name | Target Container Name |
|---------|-----------------------|-----------------------|
| adaptor | `{dataproducttype}-stage` | `{dataproducttype}-raw` |
| producer-mapper | `{dataproducttype}-raw` | `{dataproducttype}-target` |
| extractor | `dp-consumer-stage` | `dp-consumer-trfm` |
| consumer-mapper | `dp-consumer-trfm` | `dp-consumer-target` |

> **Note:** `dataproducttype` is defined by the DPN organisation based on a specific schema type (e.g. EQ, EQBD, DL) and can be generic.

```text
Example container names following this convention:

- eq-sample-1-stage
- eq-sample-1-raw
- eq-sample-1-target
- dp-consumer-stage
- dp-consumer-trfm
- dp-consumer-target
```
Each storage container is mapped to a single data product type on the producer side. It is also expected that one data product type carries a single version of the file published as a data product (e.g. the `eq-sample-1-raw` container should contain `sample_1_v1.xml` only, until a version revision changes it to `sample_1_v2.xml`).

---

## DPN Security Services

The DPN Security Services consist of the Federator Certificate Manager, HashiCorp Vault, Azure Key Vault, and Common File Share.

### Federator Certificate Manager Configuration

The Federator Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for federator components within the **DSI DPN**. It operates as a headless daemon — no HTTP endpoints are exposed — running two scheduled jobs that handle certificate renewal and filesystem synchronisation.

The service integrates with **HashiCorp Vault** (KV v2) for secret persistence, an external **Management Node** API for PKI operations (intermediate CA retrieval and CSR signing), and an **OAuth2 Identity Provider** for token-based authentication. All external HTTP communication is secured via mutual TLS (mTLS).

#### Helm Configuration

The `dpn-federator-certificate-manager` repository includes a Helm chart values file for customising the deployment per organisation requirements. The Helm chart uses **environment-specific values files** to configure the DPN deployment. The `values.yaml` file is located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
                └── values.yaml
```

> **Note:** The `values.yaml` file can be replicated for multiple environments or DPN deployments (e.g. `dpn01-values.yaml`, `dpn02-values.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section above.

DSI proposes only selective changes to the values file unless required by the organisation, but provides the provision to customise other parameters if needed.

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| image.repository | Complete URL of the image registry | `acrdpndevuks01.azurecr.io/dpn-federator-certificate-manager` |
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| managementNode.baseUrl | Complete URL of the DSI DSM Management Node | `https://management.dsm01.dsidev.neso.energy` |
| oauth2.clientId | Client ID received from DSM to establish DPN connection | `ZTF_CLIENT` |
| oauth2.tokenUri | IDP token URL received from DSM to establish DPN connection | `https://auth-mtls.dsm01.dsidev.neso.energy/realms/management-node/protocol/openid-connect/token` |
| replicaCount | Number of replicas for the container | `1` |
| vault.uri | Complete URL of the DPN Vault | `http://vault.ns-dpn-01.svc.cluster.local:8200` |
| vault.pkiMount | Mount point in the Vault where client certificates, keys, and CA chain will be stored | `pki-client` |
| vault.secretPath | Complete path in the Vault where client certificates, keys, and CA chain will be stored | `pki-client/node-net/client` |
| vault.authentication | Mode of authentication with Vault (default: root token) | `TOKEN` |
| mtls.keystorePath | KeyStore file name with absolute path | `/tls/keystore.p12` |
| mtls.truststorePath | TrustStore file name with absolute path | `/tls/truststore.p12` |
| mtls.keystoreType | Keystore type | `PKCS12` |
| certDest.path | Absolute path of keystore/truststore files | `/tls` |
| cert.renewalRateMs | Frequency in milliseconds at which certificate renewal is attempted (default: 1 hour) | `3600000` |
| cert.syncRateMs | Frequency in milliseconds at which filesystem sync is attempted (default: 1 minute) | `60000` |
| cert.renewalThresholdPercent | Percentage of days remaining before expiry at which certificate renewal is triggered (default: 10%) | `10` |
| cert.keySize | Key size to use when creating new key pairs | `2048` |
| cert.intermediateMinValidDays | Minimum validity in days for generated intermediate CAs (default: 14 days) | `14` |
| existingSecret.name | Secret bundle name for the Federator Certificate Manager secrets | `certificate-manager-secrets` |
| fileShare.shareName | Azure File Share name for common DPN certificate storage | `fs<env_name>dpn01<region_abbreviation>01` |
| fileShare.secretName | Secret bundle name for the Azure File Share used by common DPN certificate storage | `azure-fileshare-secret` |
| fileShare.namespace | Kubernetes namespace for the file share | `ns-dpn-01` |
| fileShare.pvName | Persistent Volume name for the file share | `pv-dpn-certs-fileshare` |
| fileShare.pvcName | Persistent Volume Claim name for the file share | `pvc-dpn-certs-fileshare` |

#### Secrets Configuration

The `dpn-federator-certificate-manager` repository includes a Helm chart secrets and `secretproviderclass` file for retrieving and bundling secrets from Azure Key Vault, per organisation requirements. The `secret.yaml` and `secretproviderclass.yaml` files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              └── templates
                    └── secret.yaml
                    └── secretproviderclass.yaml
```

| Secret Parameter | Purpose | Example Value |
|------------------|---------|---------------|
| certificate-manager-secrets.VAULT-TOKEN | Root token of the DPN HashiCorp Vault | `hsv.FYTUGGKNJXXXXXXXXXXX` |
| certificate-manager-secrets.OAUTH2-CLIENT-SECRET | OAuth2 Client Secret of the DPN's Client ID received from DSI DSM | — |
| azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-NAME | Storage account name of the Azure File Share used for common DPN certificate storage | `fs<env_name>dpn01<region_abbreviation>01` |
| azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-KEY | Storage account key of the Azure File Share used for common DPN certificate storage | — |

---

### HashiCorp Vault Configuration

HashiCorp Vault is used in the DPN to store the Intermediate CA, CA Chain, and KeyPair files, which are used to create the Keystore and Truststore files for Federator components to communicate with the DSI DSM Management Node and the IDP Keycloak.

#### Helm Configuration

The `dpn-federator-certificate-manager` repository includes a Helm chart values file for customising the HashiCorp Vault deployment per organisation requirements. The Helm chart uses **environment-specific values files** to configure the DPN deployment. The `values.yaml` file is located as follows:

```text
Root-Repository
  └── charts
        └── vault
                └── values.yaml
```

> **Note:** The `values.yaml` file can be replicated for multiple environments or DPN deployments (e.g. `dpn01-values.yaml`, `dpn02-values.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section above.

DSI proposes only selective changes to the values file unless required by the organisation, but provides the provision to customise other parameters if needed.

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| image.repository | Complete URL of the image registry | `acrdpndevuks01.azurecr.io/hashicorp/vault` |
| image.tag | Image version tag | `1.16` |
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| replicaCount | Number of replicas for the container | `1` |
| vault.storagePath | Path inside the persistent storage volume | `/vault/file` |

#### Secrets Configuration

N/A

#### Vault Configuration

Once the HashiCorp Vault pod is running on port **8200** in the Kubernetes environment, issue the following commands from your local machine to initialise the Vault. The examples below assume the pod instance ID is `vault-x` and the namespace is `ns-dpn-01`.

Verify that the Vault is running:

```bash
kubectl -n ns-dpn-01 exec vault-x -- vault status -format=json
```

Initialise the Vault and generate unseal keys and root token:

```bash
kubectl -n ns-dpn-01 exec vault-x -- vault operator init -key-shares=1 -key-threshold=1 -format=json
```

> **Note:** A single key share is used here for convenience. In production, use multiple key shares (e.g. `-key-shares=5 -key-threshold=3`) to distribute unseal keys across different operators via [Shamir's secret sharing](https://developer.hashicorp.com/vault/docs/concepts/seal).

Unseal the Vault using the `<unseal_key>` received in the step above:

```bash
kubectl -n ns-dpn-01 exec vault-x -- vault operator unseal <unseal_key>
```

Enable the Vault KV v2 engine using the `<RootToken>` received in the initialisation step:

```bash
kubectl -n ns-dpn-01 exec vault-x -- env VAULT_TOKEN=<RootToken> vault secrets enable -path=pki-client kv-v2
```

---

#### Certificate Load Steps in Vault

The following commands load the key pair and certificate bundle received from DSI DSM into the Vault. The examples assume the pod instance ID is `vault-x`, the root token is `<RootToken>`, and the namespace is `ns-dpn-01`. The signing key is named `dpn-dev-01.key`, and the bundle contains `ca-chain.pem` and `certificate.pem`.

Load the key pair to Vault:

```bash
kubectl -n ns-dpn-01 exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/keypair \
  privateKey="$(cat dpn-dev-01.key)" \
  publicKey="$(openssl rsa -in dpn-dev-01.key -pubout 2>/dev/null)"
```

Load the CA chain to Vault:

```bash
kubectl -n ns-dpn-01 exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/ca-chain \
  chain="$(cat ca-chain.pem)"
```

Load the certificate to Vault:

```bash
kubectl -n ns-dpn-01 exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/certificate \
  certificate="$(cat certificate.pem)"
```

---

## DPN P12 Shared Storage Service

> **Note:** This section is currently under development and will be completed in a forthcoming revision.

### Certificate P12 Storage as File Share

> **Note:** This section is currently under development and will be completed in a forthcoming revision.

#### Helm Configuration

> **Note:** In progress.

#### Secrets Configuration

> **Note:** In progress.

---

### Data Pipeline Storage

[Go to Storage Configuration for DPN Data Pipeline](#storage-configuration)

---

### Redis Cache Service

> **Note:** This section is currently under development and will be completed in a forthcoming revision.

---

## DPN Streaming Service (Kafka)

The DPN data pipeline processes files by pushing streaming messages on predefined Kafka topics as source and destination. The proposed topic names are listed below, but organisations may customise the naming convention if required. Any change to a topic name must be reflected in the CD pipeline configuration.

| Process | Source Topic Name | Target Topic Name | Bootstrap Server |
|---------|-------------------|-------------------|-----------------|
| adaptor | N/A | `dpn-producer-{dataproducttype}-raw` | `kafka-src:9092` |
| producer-mapper | `dpn-producer-{dataproducttype}-raw` | `dpn-producer-{dataproducttype}-target` | `kafka-src:9092` |
| extractor | N/A | `dpn-consumer-trfm` | `kafka-target:9092` |
| consumer-mapper | `dpn-consumer-trfm` | `dpn-consumer-target` | `kafka-target:9092` |

where **`dataproducttype`** is an example value such as `eq-sample-1`.

These topics must be pre-created via the Kafka UI as mentioned above, before execution of the `dpn-data-pipeline` CI and CD tasks.

The structure of the message pushed by the DSI Data Pipeline follows the convention below. This enables the Federator Server to locate and retrieve the file from the specified location during file transfer.

```json
{
  "sourceType": "{cloud type}",
  "storageContainer": "{Name of the Storage Container where file is placed}",
  "path": "folder name/file name"
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

> **Note:** Valid cloud types are `AZURE`, `GCP`, and `S3`. AWS support is not yet implemented.

---

# Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
