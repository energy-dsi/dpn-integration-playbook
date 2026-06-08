# README

**Repository:** `dpn-integration-playbook`  
**Description:** Documentation for installing, configuring, operating, and maintaining **Data Preparation Nodes (DPN)** within the DSI Data Sharing Infrastructure.

<!-- SPDX-License-Identifier: OGL-UK-3.0 -->

---

# Overview

This repository provides documentation to support organisations to **install, configure, deploy, and operate a Data Preparation Node (DPN)** within their own infrastructure environment.

The documentation describes how to deploy the **DPN Federator** and **DPN Data Pipeline** components using **Azure DevOps CI/CD pipelines** and **Azure Kubernetes Service (AKS)** with reference implementation. 

The objective of this repository is to provide organisations with a **clear and structured implementation guide** to deploy a DPN that can securely exchange data with other participating organisations in the **Data Sharing Infrastructure (DSI)**.

The DPN architecture enables:

- Secure **data exchange between organisations**
- **Federation with other organisations via the Data Sharing Mechanism**
- **Decentralised data ownership**
- Federated data sharing through **mutual TLS communication**
- Scalable deployment using multiple **container-based services**

---

# Architecture Overview

The DPN working with the Data Sharing Mechanism enables secure data exchange between organisations using a federated architecture.

The architecture consists of two logical environments:

### Producer Environment

- Data extracted from organisational storage
- Processed through adaptor and mapper components
- Published to Kafka topics
- Transmitted to external organisations via the DPN Federator Server

### Consumer Environment

- DPN Federator Client receives transmitted data
- Data is published to Kafka topics
- Schema validation and transformation performed
- Data stored within the organisation environment

Refer to the architecture documentation located in:

```
Docs/04-dpn-architecture/
```

---

# Quick Start

Follow the documentation sections below to deploy and operate a DPN node.


# Explanation for Numbering
The numbering convention (01, 02, 03, etc.) is used to maintain a clear logical sequence and structured flow of the documentation.

This ensures:
- Consistent ordering of sections within the repository
- Improved navigation when browsing files directly
- A step-by-step progression aligned with the playbook approach

### 1. Review Prerequisites

Ensure the organisation satisfies the required infrastructure, security, and access prerequisites.

```
Docs/02-dpn-infrastructure-deployment/azure/01-prerequisites/
Docs/03-dpn-application-deployment/azure-ado-beta/01-prerequisites/
```

Topics covered include:

- Organisation readiness
- Software dependencies
- Azure infrastructure requirements
- Network and firewall requirements
- Certificate requirements
- Skills and operational requirements

---

### 2. Review Deployment Configuration

Understand the configuration required before running deployment pipelines.

```
Docs/02-dpn-infrastructure-deployment/azure/02-configuration/
Docs/03-dpn-application-deployment/azure-ado-beta/02-configuration/
```

Topics covered include:

- Deployment pipeline configuration
- Helm deployment configuration
- Secret management
- Data Sharing Mechanism endpoint configuration
- Network and firewall rules

---

### 3. Deploy the DPN Application

Follow the installation guide to deploy the platform.

```
Docs/02-dpn-infrastructure-deployment/azure/03-installation-process/
Docs/03-dpn-application-deployment/azure-ado-beta/03-installation-process/
```

The installation process includes:

- Building container images
- Configuring Continuous Integration(CI) pipelines
- Deploying containers
- Verifying deployment health

---

### 4. Operational Procedures

To further support the node after installation, the following operational documentation is available:

| Document | Purpose |
|--------|--------|
| Rollback Guide | Restore a previous stable deployment |
| Uninstallation Guide | Remove DPN components from the environment |
| Troubleshooting Guide | Diagnose deployment and runtime issues |

---

# Repository Structure

The repository is organised into structured documentation sections that guide organisations through the **deployment lifecycle of a DPN**.

```
Docs/
│
├── 01-introduction-scope
│   ├── 01-introduction.md
│   ├── 02-purpose-of-document.md
│   └── 03-intended-audience.md
│
├── 02-dpn-infrastructure-deployment
│   └── azure
│       ├── 01-prerequisites.md
│       ├── 02-configuration-parameters.md
│       ├── 03-installation-process.md
│       ├── 04-rollback-procedures.md
│       ├── 05-uninstall-decommissioning.md
│       └── README.md
│
├── 03-dpn-application-deployment
│   └── azure-ado-beta
│       ├── 01-prerequisites.md
│       ├── 02-configuration-parameters.md
│       ├── 03-installation-process.md
│       ├── 04-rollback-procedures.md
│       └── 05-uninstall-decommissioning.md
│
├── 04-dpn-architecture
│
├── CHANGELOG.md
│
└── README.md
```

---

# Key Platform Components

The DPN platform is composed of multiple containerised services.

## Federator Platform

| Component | Purpose |
|----------|---------|
| Zookeeper | Coordination service for Kafka clusters |
| Kafka Source | Source message broker |
| Kafka Target | Target message broker |
| Kafka UI | Kafka monitoring interface |
| Redis | Offset and transmission management |
| Federator Server | Handles outbound data transmission |
| Federator Client | Handles inbound data reception |
| Vault | Secrets manager |
| Cert manager | Certificate life cycle management |

---

## Data Processing Pipelines

Data pipelines perform validation and transformation of exchanged datasets.

| Component | Purpose |
|----------|---------|
| Adaptor | Initial data ingestion |
| Produer Mapper| Producer-side schema validation |
| Extractor | Data extraction and storage |
| Consumer Mapper | Consumer-side schema validation |

The mapper component can also be extended for more capabilities for example transformations or schema assurance.

---

# Deployment Platform

The DPN platform is deployed using the following technologies:

| Technology | Purpose |
|-----------|--------|
| Azure DevOps | CI/CD pipelines |
| Azure Kubernetes Service (AKS) | Container orchestration |
| Azure Container Registry (ACR) | Container image repository |
| Helm | Kubernetes deployment management |
| Kafka | Message streaming platform |
| Redis | Offset tracking and state management |
| Vault | Hashicorp Vault |
| Docker | Container packaging |

---

# Security

The platform follows several core security principles:

- **Zero Trust architecture**
- **Mutual TLS (mTLS) communication between nodes**
- **Role-Based Access Control (RBAC)**
- **Secure secret storage using Azure Key Vault**
- **Secure container image repositories**

Code provided by DSI is security scanned using tools including:

- SonarQube
- Checkmarx
- JFrog Xray

---

**Public Funding Acknowledgment**

The Data Preparation Node builds on the development of the Integration Architecture by the National Digital Twin Programme, a programme run by the Department for Business and Trade in UK Government with public funding.

This repository has been developed with public funding as part of the **National Energy System Operator (NESO)** Data Sharing Infrastructure initiative.

The initiative aims to promote **secure, federated, and interoperable data-sharing across organisations** within the energy sector for Great Britain.

**License**

This repository contains documentation licensed under the **Open Government Licence v3.0**.

By contributing to this repository, you agree that your contributions will be licensed under these terms.
Refer to:
OGL_LICENSE.md
NOTICE.md

**Security and Responsible Disclosure**

We take security seriously. If you believe you have identified a security vulnerability in this repository, please follow the responsible disclosure process defined in:

SECURITY.md

**Contributing**

We welcome contributions that improve documentation clarity, deployment guidance, or operational procedures.

Before submitting a pull request, please review the contributing guidelines:
CONTRIBUTING.md

**Acknowledgements**

This documentation has been developed with collaboration from organisations participating in the NESO Data Sharing Infrastructure ecosystem.
Refer to:
ACKNOWLEDGEMENTS.md

# Support and Contact

For questions, feedback, or support requests:

- Open an issue in this repository
- Contact the DSI team using dsi@neso.energy

**TBD**

---
**Maintained by Data Sharing Infrastructure Coordinator operated by NESO.**
