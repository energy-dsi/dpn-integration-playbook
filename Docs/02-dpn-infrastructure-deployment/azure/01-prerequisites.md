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
    - [Required](#required)
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
    - [Agent Requirements](#agent-requirements)
    - [Agent Pool Configuration](#agent-pool-configuration)
  - [11. Azure File Share Details](#11-azure-file-share-details)
    - [What is created](#what-is-created)
    - [Key configuration values](#key-configuration-values)
    - [Deployment behavior](#deployment-behavior)
    - [Why this matters](#why-this-matters-1)

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
  - AKS : 12+ vCPUs (Standard_D4s_v3)
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

---

Continue with [02-configuration-parameters.md](02-configuration-parameters.md)