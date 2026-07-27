# 01 - Prerequisites

This section introduces the prerequisites for infrastructure deployment.

- [01 - Prerequisites](#01---prerequisites)
  - [Purpose](#purpose)
  - [1. Overview](#1-overview)
    - [What You'll Deploy](#what-youll-deploy)
    - [Deployment Architecture](#deployment-architecture)
  - [2. Azure Subscription Requirements](#2-azure-subscription-requirements)
  - [3. Entra ID / Identity Requirements](#3-entra-id--identity-requirements)
  - [4. Tooling Requirements](#4-tooling-requirements)
    - [Required](#required-tools)
    - [Optional](#optional)
  - [5. Planning Inputs](#5-planning-inputs)
  - [6. Naming Convention](#6-naming-convention)
  - [7. Pre-Deployment Decisions](#7-pre-deployment-decisions)
  - [8. Service Principal and Pipeline Trust Model](#8-service-principal-and-pipeline-trust-model)
    - [Recommended Model](#recommended-model)
    - [Minimum Identity Requirements](#minimum-identity-requirements)
    - [Why this matters](#why-this-matters)
  - [9. Access and Authentication](#9-access-and-authentication)
  - [10. Self-Hosted Agent Requirements](#10-self-hosted-agent-requirements)
    - [Self-Hosted Agent Setup](#self-hosted-agent-setup)
    - [Agent Pool Configuration](#agent-pool-configuration)
  - [11. Azure File Share Details](#11-azure-file-share-details)
    - [What is created](#what-is-created)
    - [Key configuration values](#key-configuration-values)
    - [Deployment behavior](#deployment-behavior)
    - [Why this matters](#why-this-matters-1)
  - [12. File Scanning Service Components](#12-file-scanning-service-components)
    - [What is created](#what-is-created-1)
    - [Key configuration values](#key-configuration-values-1)
    - [Role Assignments](#role-assignments)
    - [Deployment behavior](#deployment-behavior-1)
    - [Why this matters](#why-this-matters-2)
  - [13. Observability Logging Storage Account](#13-observability-logging-storage-account)
    - [What is created](#what-is-created-2)
    - [Key configuration values](#key-configuration-values-2)
    - [Deployment behavior](#deployment-behavior-2)
    - [Why this matters](#why-this-matters-3)

## Purpose

This document lists the prerequisites and pre-deployment checks for DPN participant infrastructure deployment.

---

## 1. Overview

You will deploy the DPN reference architecture in phases to reduce deployment risk and simplify validation.

### What You'll Deploy

The following core infrastructure components are included in this deployment scope.

- Virtual Network with segmented subnets
- Azure Kubernetes Service (AKS)
- Azure Container Registry (ACR)
- Azure Key Vault
- Azure Storage Accounts 
- Log Analytics Workspace
- Workload Identity
- Windows management VM
- File Scanning Service components (Event Grid topic, Service Bus namespace, dedicated storage account)
- Observability Logging Storage Account (dedicated storage account for centralized log/diagnostic export)
- Supporting controls (NSGs, Private Endpoints, RBAC)


### Deployment Architecture

The following diagram shows the high-level deployment architecture for the target environment.

```text
┌─────────────────────────────────────────────────────┐
│           Your Azure Subscription                   │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  Bootstrap (Phase 1)                         │   │
│  │  • Resource Group                            │   │
│  │  • Storage Account (OpenTofu State)          │   │
│  │  • tfstate Container + Access/RBAC           │   │
│  └──────────────────────────────────────────────┘   │
│                      ↓                              │
│  ┌──────────────────────────────────────────────┐   │
│  │  Core Infrastructure (Phases 2-5)            │   │
│  │  • Virtual Network & Subnets                 │   │
│  │  • Network Security Groups                   │   │
│  │  • AKS Cluster                               │   │
│  │  • Azure Container Registry (ACR)            │   │
│  │  • Key Vault & Secrets                       │   │
│  │  • Log Analytics Workspace                   │   │
│  │  • Application/Developer Storage Accounts    │   │
│  │  • Workload Identity                         │   │
│  │  • Private Endpoints                         │   │
│  │  • Windows Management VM                     │   │
│  │  • Event Grid Topic (file scanning)          │   │
│  │  • Service Bus Namespace (file scanning)     │   │
│  │  • File Scanning Storage Account             │   │
│  │  • Observability Logging Storage Account     │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

---

## 2. Azure Subscription Requirements

Ensure the Azure subscription is ready and validated against the following requirements.

- Active Azure subscription
- Contributor or Owner role on subscription
- Subscription ID captured (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
- Regional quota available:
  - AKS : 16+ vCPUs (Standard_D16lds_v6)
  - VM: 4+ vCPUs (Standard_D2lds_v6)
  - Public IP requirement depends on your organisation network architecture; private deployments may require none
- Region selected: <azure-region>
- No conflicting IP ranges; use customer-safe example CIDR such as `10.x.x.x/27`

## 3. Entra ID / Identity Requirements

Confirm the required identity and access capabilities are available before deployment.

- Microsoft Entra tenant access with permission to read tenant, group, and object identifiers used by deployment
- `Application Administrator` or `Cloud Application Administrator` if your team must create app registrations / service principals
- `User Access Administrator` or `Owner` at the target subscription or resource-group scope if your team must assign Azure RBAC roles
- Entra ID Premium P1 (recommended)

## 4. Tooling Requirements

Use the following tooling guidance to prepare the deployment workstation.

### Required Tools


The following software must be installed before running deployment and application pipelines:

- Java 21  
- Maven 3.9+  
- Docker (latest version)  
- Git v2.48+  
- Python 3.10 or 3.11  
- OpenSSL (latest version)  
- Azure CLI v2.50+ (if deploying to Azure)  
- kubectl (latest version)  
- Helm (latest version)  
- Infrastructure-as-code tool: OpenTofu  
 

### Optional

The following tools are optional but can simplify administration and troubleshooting.

- kubectl
- VS Code with OpenTofu extension
- Azure Storage Explorer

## 5. Planning Inputs

Capture the following planning inputs before deployment begins.

| Parameter                      | Your Value        | Example                                    |
|--------------------------------|-------------------|--------------------------------------------|
| Subscription ID                | _________________ | `00000000-0000-0000-0000-000000000000`     |
| Environment Name               | _________________ | `dev`, `test`, `preprod`, `prod`           |
| Instance Number                | _________________ | `01`, `02`, `03`                           |
| VNET CIDR                      | _________________ | `10.x.x.x/27`                              |
| Connectivity Sub ID (optional) | _________________ | For Private DNS zones                      |

## 6. Naming Convention

Use the following naming patterns to keep deployed resources consistent.

Common pattern used is: `{resource-type-abbreviation}-dpn-{env}-{instance}`. Following table is the example.

| Resource Type   | Pattern                     | Example                |
|-----------------|-----------------------------|------------------------|
| Resource Group  | `rg-dpn-{env}-{instance}`   | `rg-dpn-preprod-01`    |
| Virtual Network | `vnet-dpn-{env}-{instance}` | `vnet-dpn-preprod-01`  |
| AKS Cluster     | `aks-dpn-{env}-{instance}`  | `aks-dpn-preprod-01`   |
| Key Vault       | `kv-dpn-{env}-{instance}`   | `kv-dpn-preprod-01`    |

## 7. Pre-Deployment Decisions

Agree the following deployment choices with stakeholders before proceeding.

- Target Azure region and naming standard for the environment
- organisation network architecture and private DNS ownership model
- Whether service mesh / Istio is required for the platform
- Change approval, deployment window, and rollback ownership

## 8. Service Principal and Pipeline Trust Model

Define how deployment identity and pipeline execution are connected before first run.

### Recommended Model

```text
Self-Hosted Agent
  → Azure DevOps Repo
  → Azure DevOps Pipeline
  → Service Connection (Service Principal)
  → Azure Resource Manager (target subscription)
```

### Minimum Identity Requirements

- One dedicated service principal per environment (or per trust boundary)
- Contributor scope on deployment subscription/resource groups
- `User Access Administrator` only if OpenTofu manages RBAC assignments
- `Storage Blob Data Owner` on the backend state storage account for the service principal used by the Azure DevOps service connection
- Reader on shared connectivity subscription when private DNS zones are external, based on the organisation's network architecture.

### Why this matters

- Keeps deployment identity non-human and auditable
- Separates developer access from runtime deployment permissions
- Supports controlled least-privilege RBAC

## 9. Access and Authentication

Complete the following access and authentication steps before running deployment commands.

- create a GitHub account user id and PAT token with minimal capability to pull from repo

- Clone repo:
   ```bash
  git clone https://github.com/energy-dsi/dpn-infra-deployment
  cd dpn-infra-deployment
   ```
- Authenticate and set subscription:
   ```bash
   az login
   az account set --subscription "<your-subscription-id>"
   az account show --output table
   ```

## 10. Self-Hosted Agent Requirements

Configure self-hosted agents for Azure DevOps to provide better control over deployment pipelines.

DSI recommends using a dedicated self-hosted agent pool instead of the default Microsoft-hosted agents for the following benefits:

- Better control over security posture
- Full management of network access and connectivity
- Complete control over deployment environment configuration
- Pre-installed software and dependencies on private infrastructure

### Self-Hosted Agent Setup

- Provision a dedicated Azure Virtual Machine in the same Virtual Network as your DPN infrastructure
- Install and configure Azure DevOps agent on the VM following Microsoft documentation
- Ensure the agent has network access to all required Azure services (AKS, Key Vault, Container Registry, etc.)
- Configure the agent pool in Azure DevOps with appropriate permissions and labels


### Agent Pool Configuration

Update Azure DevOps pipeline definitions to reference the self-hosted agent pool:

```yaml
pool:
  name: '[your-agent-pool-name]'
```

Replace the default Microsoft-hosted agent pool reference:

```yaml
pool:
  vmImage: 'ubuntu-latest'
```

For detailed setup instructions, refer to the [Microsoft documentation for Linux agent setup](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent).

## 11. Azure File Share Details

This deployment uses Azure Files for application storage, with the file share secured through a private endpoint.

### What is created

- Azure Files share inside the application storage account
- Azure Files private endpoint for secure access from the VNet
- Storage account private DNS and network access configuration through the deployment

### Key configuration values

The following variables are used in the deployment:

- `application_storage_file_share_name` – Azure Files share name
- `application_file_share_quota_gb` – quota size for the share in GiB
- `application_storage_create_file_endpoint` – set to `true` to create the Azure Files private endpoint

### Deployment behavior

- The Azure Files share is only created when `application_storage_file_share_name` is defined.
- The private endpoint is created only when `application_storage_create_file_endpoint` is enabled.
- The file share private endpoint uses the `file` subresource.

### Why this matters

- Ensures developer storage is provided as a managed Azure Files share
- Keeps the file share traffic private inside the VNet
- Supports secure access to developer storage without exposing the share over the public internet

## 12. File Scanning Service Components

This deployment includes a File Scanning Service, made up of an Event Grid topic, a Service Bus namespace, and a dedicated storage account. Together these components decouple file upload notifications from downstream scanning/processing workloads.

### What is created

- **1** Azure Event Grid custom topic, used to publish file-related events (for example, new file uploads) to downstream subscribers
- **1** Azure Service Bus namespace (Premium SKU) with optional queues, used to reliably queue file scanning work items
- **1** new dedicated blob storage account, used to stage files for scanning
- A private endpoint for every component (Event Grid `topic`, Service Bus `namespace`, storage `blob` and optionally `file`), each in its own dedicated subnet
- Role assignments scoped to each component for data-plane access (see [Role Assignments](#role-assignments) below)

### Key configuration values

The following variables are used in the deployment:

- `event_grid_topic_name` / `event_grid_resource_group_name` – Event Grid topic identity
- `event_grid_subnet_name` – subnet used for the Event Grid private endpoint
- `event_grid_local_auth_enabled` – disables topic access/SAS keys; access is via Azure AD/RBAC only
- `event_grid_public_network_access_enabled` – **the Event Grid topic is deployed with public network access enabled** in addition to its private endpoint (unlike Service Bus and the file scanning storage account, which are private-endpoint only). Confirm this is intentional for your environment before deployment.
- `event_grid_data_receiver_principal_ids` / `event_grid_data_sender_principal_ids` / `event_grid_contributor_principal_ids` – principal IDs granted the `EventGrid Data Receiver`, `EventGrid Data Sender`, and `EventGrid Contributor` roles respectively
- `service_bus_namespace_name` / `service_bus_resource_group_name` – Service Bus namespace identity
- `service_bus_sku` – SKU for the namespace; Premium is required to support private endpoints
- `service_bus_subnet_name` – subnet used for the Service Bus private endpoint
- `service_bus_queues` – map of queues to create in the namespace
- `service_bus_data_receiver_principal_ids` / `service_bus_data_sender_principal_ids` / `service_bus_data_owner_principal_ids` – principal IDs granted the `Azure Service Bus Data Receiver`, `Data Sender`, and `Data Owner` roles respectively
- `file_scanning_service_storage_account_name` / `file_scanning_service_storage_resource_group_name` – new storage account identity
- `file_scanning_service_storage_subnet_name` – subnet used for the storage account's private endpoint(s)
- `file_scanning_service_storage_create_blob_endpoint` / `file_scanning_service_storage_create_file_endpoint` – toggle blob and Azure Files private endpoints independently
- `file_scanning_service_storage_data_receiver_principal_ids` / `file_scanning_service_storage_data_contributor_principal_ids` – principal IDs granted `Storage Blob Data Reader` and `Storage Blob Data Contributor` respectively on the **new** storage account
- `dev_storage_additional_blob_contributor_principal_ids` – principal IDs additionally granted `Storage Blob Data Contributor` on the **existing** developer/application storage account (see below), so the file scanning service principal can read from and write to both storage accounts

### Role Assignments

The file scanning service principal (referred to here as the file scanning/DPN SPN) requires role assignments across all three components:

| Component | Role | Variable |
|---|---|---|
| Service Bus namespace | `Azure Service Bus Data Receiver` | `service_bus_data_receiver_principal_ids` |
| New file scanning storage account | `Storage Blob Data Reader` | `file_scanning_service_storage_data_receiver_principal_ids` |
| Existing developer/application storage account | `Storage Blob Data Contributor` | `dev_storage_additional_blob_contributor_principal_ids` |

Additional producer/administrative roles (`EventGrid Data Sender`, `EventGrid Contributor`, `Azure Service Bus Data Sender`, `Azure Service Bus Data Owner`, `Storage Blob Data Contributor` on the new storage account) are assigned to separate publisher/team principals as needed — see Section 7 of [02-configuration-parameters.md](02-configuration-parameters.md#7-file-scanning-service-parameters).

Important: the same SPN object ID must be supplied consistently across `service_bus_data_receiver_principal_ids`, `file_scanning_service_storage_data_receiver_principal_ids`, and `dev_storage_additional_blob_contributor_principal_ids` for the role assignments to apply to the correct identity. This object ID is different for each environment — the file scanning service principal used in dev is a distinct SPN from the ones used in test, preprod, and prod. Each environment's object ID must be obtained and provided separately before that environment's role assignments can be completed; do not reuse the dev object ID in other environments' tfvars.

### Deployment behavior

- Each component (Event Grid, Service Bus, storage) is deployed with its own dedicated subnet and private endpoint, isolated from the core application subnets.
- Service Bus requires the Premium SKU when a private endpoint is used; do not downgrade the SKU without also removing the private endpoint.
- The storage account's Azure Files private endpoint is only created when both `file_scanning_service_storage_create_file_endpoint` is enabled and a file share name is provided.
- RBAC role assignments follow least-privilege data-plane roles (Reader/Receiver, Sender/Contributor, Owner) rather than granting broad control-plane access.

### Why this matters

- Keeps Service Bus and file scanning storage traffic private inside the VNet, while allowing the Event Grid topic's public endpoint where required by the publishing pattern
- Separates the file scanning data path from the core application storage and messaging used elsewhere in the platform
- Supports least-privilege access for producer, consumer, and administrative principals through scoped role assignments, including cross-account access to the existing developer/application storage account

## 13. Observability Logging Storage Account

This deployment includes a dedicated storage account for observability logging, used to centralize log and diagnostic export separately from application and file scanning storage.

### What is created

- **1** new dedicated blob storage account, used to store exported logs/diagnostics
- A private endpoint for the storage account's `blob` subresource (and optionally `file`, if a file share is configured), in its own subnet
- Role assignments scoped to the storage account for data-plane access (see [Key configuration values](#key-configuration-values-2) below)

### Key configuration values

The following variables are used in the deployment:

- `observability_logging_storage_account_name` / `observability_logging_storage_resource_group_name` – new storage account identity
- `observability_logging_storage_subnet_name` – subnet used for the storage account's private endpoint(s)
- `observability_logging_storage_create_blob_endpoint` / `observability_logging_storage_create_file_endpoint` – toggle blob and Azure Files private endpoints independently
- `observability_logging_storage_data_receiver_principal_ids` / `observability_logging_storage_data_contributor_principal_ids` – principal IDs granted `Storage Blob Data Reader` and `Storage Blob Data Contributor` respectively on this storage account

### Deployment behavior

- The storage account is deployed with its own dedicated subnet and private endpoint, isolated from the core application and file scanning subnets (the reference dev environment reuses the file scanning storage subnet — confirm whether your environment should instead provision a dedicated subnet).
- The Azure Files private endpoint is only created when both `observability_logging_storage_create_file_endpoint` is enabled and a file share name is provided.
- RBAC role assignments follow least-privilege data-plane roles (Reader, Contributor) rather than granting broad control-plane access.

### Why this matters

- Keeps observability/log data separate from application, developer, and file scanning storage, reducing blast radius and simplifying retention/lifecycle policy per data type
- Keeps log export traffic private inside the VNet via private endpoint
- Supports least-privilege access for log producers and consumers through scoped role assignments

---

Continue with [02-configuration-parameters.md](02-configuration-parameters.md)