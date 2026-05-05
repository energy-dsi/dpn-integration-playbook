# DPN Deployment Prerequisites

---

## Table of Contents

- [Overview](#overview)
- [Organisation Prerequisites](#organisation-prerequisites)
- [Software Prerequisites](#software-prerequisites)
  - [Optional Tools](#optional-tools)
- [Service Prerequisites](#service-prerequisites)
- [Accessibility Prerequisites](#accessibility-prerequisites)
  - [Access Requirements](#access-requirements)
    - [GitHub Access](#github-access)
    - [Azure Service Principal](#azure-service-principal)
    - [Azure DevOps Service Connection](#azure-devops-service-connection)
    - [AKS Access](#aks-access)
    - [Data Pipeline Access](#data-pipeline-access)
- [Security Prerequisites](#security-prerequisites)
- [Network Prerequisites](#network-prerequisites)
- [Certificate Prerequisites](#certificate-prerequisites)
- [Skills Prerequisites](#skills-prerequisites)
- [Assumptions](#assumptions)
- [Review Notes](#review-notes)

---

## Overview

This section lists the prerequisites that must be completed **before installing DPN nodes from the repository in an Azure environment**.

The prerequisites are grouped into the following categories:

- Organisation prerequisites
- Software prerequisites
- Service prerequisites
- Accessibility prerequisites
- Security prerequisites
- Network prerequisites
- Certificate prerequisites
- Skills prerequisites

---

## Organisation Prerequisites

This section describes the organisational readiness required before installing DPN nodes.

The following conditions must be met:

- Organisation accreditations submitted and required agreements signed with the Data Sharing Mechanism (DSM)
- Organisation registration application verified and approved by DSM
- DPN Connection ID and Client ID received from DSM
- DSI participant users created
- Certificate issued and signed by the DSI Signing Authority
- Credentials issued and stored securely in a vault or equivalent secure location
- Organisation has accepted the **Technology Sharing Agreement (TSA)**

---

## Software Prerequisites

The following software must be available in the agent pool before installing DPN nodes.

| Software | Version |
|----------|---------|
| Java | 21 |
| [Maven](https://maven.apache.org/download.cgi) | 3.9 or later |
| [Docker](https://www.docker.com/) | Latest |
| [Git](https://git-scm.com/) | Latest |
| [Python](https://www.python.org) | 3.10 or 3.11 |
| OpenSSL | Latest |

The following DPN repositories are required:

| Repository | URL |
|------------|-----|
| DPN Infrastructure | https://github.com/energy-dsi/dpn-infra-deployment |
| DPN Data Pipeline | https://github.com/energy-dsi/dpn-data-pipelines |
| DPN Federator Gateway | https://github.com/energy-dsi/dpn-federator |
| DPN Federator Certificate Manager | https://github.com/energy-dsi/dpn-federator-certificate-manager |

### Optional Tools

The following tools are optional but recommended for deployment and operations:

| Tool | Version |
|------|---------|
| Azure CLI | Latest |
| Kubectl | Latest |
| Helm | Latest |
| Terraform | Latest |
| DigiCert utility | Latest (for CSR generation) |

---

## Service Prerequisites

The following cloud services and licences are required to run DPN nodes on the Azure platform.

- A **GitHub user account** and **Personal Access Token (PAT)** to fetch from GitHub
- A **Docker Hub user account** and **password** to fetch from the Docker repository
- An Azure **Pay-As-You-Go** or equivalent **Enterprise subscription**
- An active **Azure Tenant and Subscription**
- An **Azure DevOps licence** (Basic or higher) for repository and pipeline access
- A **Windows Azure Virtual Machine** deployed in the same Azure network as the DPN components (recommended SKU: B8ms or equivalent)
- A **Bastion Host** to connect to the virtual machine

---

## Accessibility Prerequisites

The following configuration is recommended to securely operate DPN nodes on the Azure platform. DSI recommends this approach as a **secure and best-practice model**.

- Use private networks and private endpoints wherever possible
- Use **self-hosted agents and node pools** in Azure DevOps
- Use **Role-Based Access Control (RBAC)** instead of local authentication
- Enable **encryption of data at rest and in transit**
- Follow a **Zero Trust security model**

---

### Access Requirements

The following access configurations are required for DPN deployment.

#### GitHub Access

- A **Personal Access Token (PAT)** with **read-only access** to the required GitHub repositories

#### Azure Service Principal

A **Service Principal in Azure AD** with the following role permissions:

| Role | Purpose |
|------|---------|
| Contributor | Create infrastructure resources |
| User Access Administrator | Assign required permissions |
| Azure Container Registry Push | Push container images |
| Key Vault Secrets Officer | Create and manage secrets |
| Key Vault Certificate Officer | Create and manage certificates |

#### Azure DevOps Service Connection

- A **Service Connection** created using the above Service Principal, used by Azure DevOps pipelines

#### AKS Access

A **Service Principal or Azure AD group** used for managing **Azure Kubernetes Service (AKS)** with the following permissions:

| Role | Purpose |
|------|---------|
| Azure Container Registry Pull | Pull container images |
| Azure Key Vault Secrets Reader | Access secrets inside containers |

#### Data Pipeline Access

- A **Blob Storage SAS Token** with **read and write permissions** for file passthrough used by the data pipeline

---

## Security Prerequisites

The following security practices must be implemented before deploying DPN nodes.

- Adoption of a **Zero Trust security model**
- **Mutual TLS (mTLS)** enforced for all inter-organisation communication
- Storage of secrets in **Azure Key Vault** or an equivalent secure secret store
- Regular **rotation of secrets and encryption keys**
- Regular **rotation of certificates** used for communication

For **Bring Your Own (BYO)** components, organisations must follow recommended security scanning practices.

DSI-provided code is scanned using the following tools (not limited to):

| Tool | Purpose |
|------|---------|
| SonarQube | Code quality and test coverage |
| Checkmarx | Static code analysis |
| JFrog Xray | Container security scanning |

---

## Network Prerequisites

The following networking requirements must be satisfied before installing DPN nodes.

The DPN node communicates with the DSI Data Sharing Mechanism (DSM) and other organisation DPNs through defined endpoints and ports (refer to the Interface Documentation), including:

- Management Node
- Authentication endpoint
- Cross-DPN connections as producer or consumer

Ensure the following:

- Organisation **egress firewall rules allow outbound communication** to the required endpoints
- **DNS resolution** can successfully resolve the required domains
- Organisation **ingress firewall rules allow incoming connections** to the DPN producer endpoint from other organisations

---

## Certificate Prerequisites

The DPN Federator service enforces **mutual TLS (mTLS)** when communicating with:

- DSI DSM services
- Other participating organisations during data exchange

The following certificate setup is required:

- A **Certificate Signing Request (CSR)** generated by the organisation with the correct **Common Name (CN)** and **Subject Alternative Names (SANs)**
- The CSR must be **signed by the DSI Certificate Authority**
- Certificates must be **rotated at regular intervals**

---

## Skills Prerequisites

DSI recommends the following skill sets to ensure smooth installation and operation of DPN.

| Role | Responsibility |
|------|---------------|
| Azure DevOps Engineer | Configure and manage CI/CD pipelines |
| Azure Infrastructure Engineer | Provision and maintain Azure resources |
| Azure Administrator | Manage Azure AD, RBAC, and platform access |

---

## Assumptions

The prerequisites described in this document assume the following:

- The organisation plans to deploy DPN on **Azure cloud infrastructure**
- The organisation will use **Azure DevOps** for **Continuous Integration and Continuous Deployment (CI/CD)** into the Azure landing zone

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
