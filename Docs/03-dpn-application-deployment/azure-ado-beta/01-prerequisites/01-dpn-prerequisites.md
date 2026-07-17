# DPN Deployment Prerequisites

## Table of Contents

- [Overview](#overview)
- [Organisation Prerequisites](#organisation-prerequisites)
- [Software Prerequisites](#software-prerequisites)
  - [Optional Tools](#optional-tools)
- [Service Prerequisites](#service-prerequisites)
- [Accessibility Prerequisites](#accessibility-prerequisites)
  - [Access Requirements](#access-requirements)
- [Security Prerequisites](#security-prerequisites)
- [Network Prerequisites](#network-prerequisites)
- [Certificate Prerequisites](#certificate-prerequisites)
- [Skills Prerequisites](#skills-prerequisites)
- [Assumptions](#assumptions)
- [Review Notes](#review-notes)

## Overview

This section lists the prerequisites that must be completed **before installing DPN nodes from the repository in an Azure environment**.

The prerequisites are grouped into the following categories:

- organisation prerequisites  
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

- organisation accreditations submitted and required agreements signed with Data Sharing Mechanism (DSM)  
- organisation registration application verified and approved by DSM
- DPN Connection ID / Client ID received from DSM
- DSI participant users created in DSM
- Certificate issued and signed by the DSI Signing Authority via the DSM
- Credentials issued and stored securely in vault or equivalent secure location
- Organisation has accepted the **Techincal Sharing Agreement (TSA)**  

---
## Software Prerequisites

The following softwares must be available in the agent pool before installing DPN nodes.

- Java 21  
- [Maven 3.9+](https://maven.apache.org/download.cgi)  
- [Docker – latest version](https://www.docker.com/)  
- [Git – latest version](https://git-scm.com/)  
- [Python 3.10 or 3.11](https://www.python.org)  
- OpenSSL – latest version  

DPN repositories required:

- [DPN-Infra](https://github.com/energy-dsi/dpn-infra-deployment)  
- [DPN-Data-Pipeline](https://github.com/energy-dsi/dpn-data-pipelines)
- [DPN-Federator Gateway](https://github.com/energy-dsi/dpn-federator)  
- [DPN-Federator Certificate-Manager](https://github.com/energy-dsi/dpn-federator-certificate-manager)
- [DPN-Health-Monitoring-Service](https://github.com/energy-dsi/dpn-health-monitoring-service)
- [DPN-FILE-SCAN-Service](https://github.com/energy-dsi/dpn-file-scan-service)

### Optional Tools

The following tools are optional but recommended for deployment and operations:

- Azure CLI – latest version  
- Kubectl – latest version  
- Helm – latest version  
- OpenTofu – latest version  
- DigiCert utility – latest version (for CSR generation)
- OpenSSL – latest version  


---
## Service Prerequisites

The following cloud services and licenses are required to run DPN nodes on the Azure platform.

- A Git Hub user account and **PAT token** to fetch from GitHub.
- A Docker.io **user account** and **password** to fetch from docker repository
- Azure **Pay-As-You-Go** or equivalent **Enterprise subscription**  
- An active **Azure Tenant and Subscription**  
- An **Azure DevOps license** (Basic or higher) for repository and pipeline access  
- An **Windows Azure Virtual Machine** deployed in the same Azure Network where the DPN components are deployed with minimal configuration (Preferred SKU B8ms or equivalent)
- A **Bastion Host** to connect to the virtual machine

---
## Accessibility Prerequisites

The following configuration is recommended to securely operate DPN nodes on the Azure platform.  
DSI recommends this approach as a **secure and best-practice model**.

- Use private networks and private endpoints wherever possible  
- Use **self-hosted agents and node pools** in Azure DevOps  
- Use **Role-Based Access Control (RBAC)** instead of local authentication  
- Enable **encryption of data at rest and in transit**  
- Follow a **Zero Trust security model**

---
### Access Requirements

The following access configurations are required for DPN deployment.

#### GitHub Access

- A **Personal Access Token (PAT)** with **read-only access** to GitHub repositories in order to clone the required code.

#### Azure Service Principal

A **Service Principal in Azure AD** with the following role permissions:

- **Contributor** role – to create infrastructure resources  
- **User Access Administrator** role – to assign required permissions  
- **Azure Container Registry Push** role – to push container images  
- **Key Vault Secrets Officer** role – to create and manage secrets  
- **Key Vault Certificate Officer** role – to create and manage certificates
- **Storage Blob Data Contributor** role - to access storage accounts 

#### Azure DevOps Service Connection

- A **Service Connection** created using the above Service Principal and used by **Azure DevOps pipelines**.

#### AKS Access

A **Service Principal or Azure AD group** used for managing **Azure Kubernetes Service (AKS)** with the following permissions:

- **Azure Container Registry Pull** role – to pull container images  
- **Azure Key Vault Secrets Reader** role – to access secrets inside containers  

#### Data Pipeline Access

- A **Blob Storage / S3 SAS Token (TBD)** with **read and write permissions** for file passthrough used by the data pipeline.

---
## Security Prerequisites

The following security practices must be implemented before deploying DPN nodes.

- Adoption of a **Zero Trust security model**  
- **Mutual TLS (mTLS)** enforced for communication between organisations DPNs and DSM  
- Storage of secrets in **Azure Key Vault** or an equivalent secure secret store  
- Regular **rotation of secrets and encryption keys**  
- Regular **rotation of certificates used for communication**

For **Bring Your Own (BYO) components**, organisations must follow recommended security scanning practices.

DSI-provided code is scanned using the following tools (not limited to) prior to release :

- **SonarQube** – code quality and coverage  
- **Checkmarx** – static code analysis  
- **JFrog Xray** – container security scanning  

---
## Network Prerequisites

The following networking requirements must be satisfied before installing DPN nodes.

The DPN Node communicates with NESOs DSM through defined **endpoints and ports**(refer to the Interface Documentation), including:

- Management Node  
- Authentication End point
- Cross DPN connection as producer or consumer

Ensure the following:

- organisation **egress firewall rules allow outbound communication** to these endpoints  
- **DNS resolution** can successfully resolve the required domains
- organisation **ingress firewall rules allow the incoming connection** to the DPN producer endpoint for other organisations

---
## Certificate Prerequisites

The DPN Federator service enforces **mutual TLS (mTLS)** when communicating with:

- DSI DSM services  
- Other participating organisations DPNs during data exchange

Required certificate setup:

- A **Certificate Signing Request (CSR)** generated by the organisation with the correct **Common Name (CN)** and **Subject Alternative Names (SANs)**  
- The CSR must be **signed by the DSI Certificate Authority** via the DSM 
- Certificates must be **rotated at regular intervals**, this is automted via the DPN Certificate Manager component.

---
## Skills Prerequisites

DSI recommends the following skillsets to ensure smooth installation and operation of DPN as mentioned in this installation procedure.

- Azure DevOps Engineer  
- Azure Infrastructure Engineer  
- Azure Administrator  

---
## Assumptions

The prerequisites described in this document assume the following:

- The organisation plans to deploy **DPN on Azure` cloud infrastructure**  
- The organisation will use **Azure DevOps** for **Continuous Integration and Continuous Deployment (CI/CD)** into the Azure landing zone

---
## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| 15-May-2026 | DSI Assurance   | Draft  | V0.1.0 |