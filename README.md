# README

**Repository:** `dpn-integration-playbook`  
**Description:** Documentation for installing, configuring, operating, and maintaining **Data Preparation Nodes (DPN)** — covering both **infrastructure provisioning** and **application deployment**, on both **Azure** and **AWS** — within the DSI Data Sharing Infrastructure.

<!-- SPDX-License-Identifier: OGL-UK-3.0 -->

---

# Overview

This repository provides documentation to support organisations to **install, configure, deploy, and operate a Data Preparation Node (DPN)** within their own infrastructure environment.

The documentation is organised around **Multiple deployment layers**, each of which is documented for **Azure and AWS**:

| Layer | Purpose | Azure | AWS |
|---|---|---|---|
| **Infrastructure** | Provision the underlying cloud infrastructure (Kubernetes cluster, networking, secrets store, registry) | OpenTofu, with optional Bicep bootstrap | OpenTofu |
| **Application** | Deploy the DPN components (Federator, Data Pipeline, Vault, Certificate Manager, Health Monitoring, File Scan) on top of that infrastructure | Azure DevOps (ADO) CI/CD pipelines — fully automated | Manual `kubectl apply` runbooks — interim, pending future GitHub Actions support |

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

The architecture consists of two logical processes:

### Producer Process

- Producer process is responsible for fetching data from organisational internal data sources
- Processed through adaptor and producer mapper components
- Publishes the data, or its location, to Kafka topics
- Transmitted to external organisations via the DPN Federator Server

### Consumer Process

- DPN Federator Client receives transmitted data
- Performs file scans via a cloud-native solution as applicable
- Data is published to Kafka topics or moved to a storage container, depending on whether the integration pattern is stream-based or file-based
- Data stored within the organisation environment and ready to be consumed by internal data destination process

---

# Partner Onboarding & Governance

Before a DPN can exchange data with another organisation, it must complete the following onboarding sequence with the Data Sharing Mechanism (DSM):

1. **Organisation registration** — submit organisation accreditation and Technical Sharing Agreement (TSA) to DSM; receive a DPN Connection ID / Client ID. See [Organisation Prerequisites](Docs/03-dpn-application-deployment/azure-ado-beta/01-prerequisites/01-dpn-prerequisites.md#organisation-prerequisites).
2. **Certificate issuance** — generate and submit a Certificate Signing Request (CSR) through the DSM user interface; DSM signs the CSR and returns a bootstrap certificate bundle. See [Certificate Lifecycle and Management](Docs/03-dpn-application-deployment/azure-ado-beta/01-prerequisites/01-dpn-prerequisites.md#certificate-lifecycle-and-management).
3. **Infrastructure and DPN deployment** — provision the underlying infrastructure, then install the bootstrap certificate bundle into Vault and deploy the DPN Federator components (see Quick Start below).
4. **mTLS trust verification** — confirm the DPN can establish mutual TLS connections with DSM and with counterpart organisation DPNs before going live.

Organisations should factor certificate renewal and expiry recovery into their operational runbooks, as described in the Certificate Lifecycle section linked above.

---

# Quick Start

Follow the documentation sections below to deploy and operate a DPN node. Each phase below has a separate path for the **infrastructure layer** and the **application layer**, and for **Azure** and **AWS**.

# Explanation for Numbering

The numbering convention (01, 02, 03, etc.) is used to maintain a clear logical sequence and structured flow of the documentation.

This ensures:
- Consistent ordering of sections within the repository
- Improved navigation when browsing files directly
- A step-by-step progression aligned with the playbook approach

### 1. Review Prerequisites

Ensure the organisation satisfies the required infrastructure, security, and access prerequisites.

**Infrastructure prerequisites summary:**

| Requirement | Azure (AKS) | AWS (EKS) |
|---|---|---|
| Cluster sizing | 16+ vCPUs (e.g. `Standard_D16lds_v6`) | Equivalent EKS managed node group sizing |
| Secrets management | Azure Key Vault/Kubernetes Secrets | Hashicorp Vault/Kubernetes Secrets |
| Ingress / networking | Requires GRPC/HTTP2 traffic supported ingress/Layer 4 Network load balancer for Federator Server ingress | Same as Azure |
| Container registry | GitHub Container Registry (GHCR) for DSI-provided pre-built images, or Azure Container Registry (ACR) if the organisation runs its own CI pipeline | GitHub Container Registry (GHCR) |

Full detail is in the platform-specific prerequisites documents linked below.

For Azure Deployment refer:

- [Azure Infrastructure Prerequisites](Docs/02-dpn-infrastructure-deployment/azure/01-prerequisites.md)
- [Azure Application Deployment Prerequisites](Docs/03-dpn-application-deployment/azure-ado-beta/01-prerequisites/01-dpn-prerequisites.md)

For AWS Deployment refer:

- [AWS Infrastructure Prerequisites](Docs/02-dpn-infrastructure-deployment/aws/01-prerequisites.md)
- [AWS Shared Prerequisites RUNBOOK](Docs/03-dpn-application-deployment/aws-manual-beta/00-shared-prerequisites/RUNBOOK.md)

Topics covered include:

- Organisation readiness
- Software dependencies
- Azure infrastructure requirements
- AWS infrastructure requirements
- Network and firewall requirements
- Certificate requirements
- Skills and operational requirements

---

### 2. Review Deployment Configuration

Understand the configuration required before running deployment pipelines.

For Azure Deployment refer:

- [Azure Infrastructure Configuration Parameters](Docs/02-dpn-infrastructure-deployment/azure/02-configuration-parameters.md)
- [Azure Application Configuration Guides](Docs/03-dpn-application-deployment/azure-ado-beta/02-configuration/) — Vault, Health Monitoring, Certificate Manager, Federator Gateway, Data Pipelines, File Scan Service

For AWS Deployment refer:

- [AWS Infrastructure Configuration Parameters](Docs/02-dpn-infrastructure-deployment/aws/02-configuration-parameters.md)
- [AWS Component RUNBOOKs](Docs/03-dpn-application-deployment/aws-manual-beta/) — see the `RUNBOOK.md` under each component folder as per numbering order

Topics covered include:

- Deployment pipeline configuration
- Helm deployment configuration
- Secret management
- Data Sharing Mechanism endpoint configuration
- Network and firewall rules

---

### 3. Deploy the DPN Infrastructure and Application

Follow the installation guides to provision infrastructure and deploy the platform.

For Azure Deployment refer:

- [Azure Infrastructure Installation Process](Docs/02-dpn-infrastructure-deployment/azure/03-installation-process.md)
- [Azure Application Installation Guides](Docs/03-dpn-application-deployment/azure-ado-beta/03-installation/) — Vault, Health Monitoring, Certificate Manager, Federator Gateway, Data Pipelines, File Scan Service

For AWS deployment refer:

- [AWS Infrastructure Installation Process](Docs/02-dpn-infrastructure-deployment/aws/03-installation-process.md)
- [AWS Component RUNBOOKs](Docs/03-dpn-application-deployment/aws-manual-beta/) — applied in order: `00-shared-prerequisites` → `01-vault-certificate-manager` → `02-health-monitor` → `03-data-pipeline` → `04-federator-gateway`

The installation process includes:

- Provisioning infrastructure (cluster, networking, secrets store, registry)
- Building container images
- Configuring Continuous Integration (CI) pipelines (Azure) or applying manifests directly (AWS) as interim till GitHub Actions runner-based deployment instructions are published
- Deploying containers
- Verifying deployment health

---

### 4. Operational Procedures

To further support the node after installation, the following operational documentation is available:

| Document | Purpose |
|--------|--------|
| [Azure Infrastructure Rollback Guide](Docs/02-dpn-infrastructure-deployment/azure/04-rollback-procedures.md) / [Azure Application Rollback Guide](Docs/03-dpn-application-deployment/azure-ado-beta/04-rollback/04-rollback-procedures.md) | Restore a previous stable deployment |
| [Azure Infrastructure Uninstallation Guide](Docs/02-dpn-infrastructure-deployment/azure/05-uninstall-decommissioning.md) / [Azure Application Uninstallation Guide](Docs/03-dpn-application-deployment/azure-ado-beta/05-uninstall/05-uninstall-decommissioning.md) | Remove DPN components from the environment |
| [AWS Infrastructure Rollback Guide](Docs/02-dpn-infrastructure-deployment/aws/04-rollback-procedures.md) | Restore a previous stable deployment on AWS |
| [AWS Infrastructure Uninstallation Guide](Docs/02-dpn-infrastructure-deployment/aws/05-uninstall-decommissioning.md) | Remove DPN components from AWS |
| [User Interfaces & Operations](#user-interfaces--operations) | Day-to-day monitoring and operation via component UIs |
| [Troubleshooting Guide](#troubleshooting) | Diagnose deployment and runtime issues |

---

### Troubleshooting

Each component's installation/RUNBOOK document includes a troubleshooting section for issues specific to that component:

**Azure (ADO) components:**

- [Common Installation Troubleshooting](Docs/03-dpn-application-deployment/azure-ado-beta/03-installation/00-dpn-common-installation-process.md#common-troubleshooting-guidance)
- [Health Monitoring Service Troubleshooting](Docs/03-dpn-application-deployment/azure-ado-beta/03-installation/02-dpn-monitoring-service-installation-process.md#step3-troubleshooting)
- [Certificate Manager Troubleshooting](Docs/03-dpn-application-deployment/azure-ado-beta/03-installation/03-dpn-certificate-manager-installation-process.md#step3-troubleshooting)
- [Federator Gateway Troubleshooting](Docs/03-dpn-application-deployment/azure-ado-beta/03-installation/04-dpn-federator-gateway-installation-process.md#step3-troubleshooting)
- [Data Pipeline Troubleshooting](Docs/03-dpn-application-deployment/azure-ado-beta/03-installation/05-dpn-data-pipeline-installation-process.md#step4-troubleshooting)
- [File Scan Service Troubleshooting](Docs/03-dpn-application-deployment/azure-ado-beta/03-installation/06-dpn-file-scan-service-installation-process.md#step4-troubleshooting)

**AWS (manual-beta) components:**

- [Shared Prerequisites Troubleshooting](Docs/03-dpn-application-deployment/aws-manual-beta/00-shared-prerequisites/RUNBOOK.md#troubleshooting)
- [Vault + Certificate Manager Troubleshooting](Docs/03-dpn-application-deployment/aws-manual-beta/01-vault-certificate-manager/RUNBOOK.md#35-troubleshooting)
- [Health Monitor Troubleshooting](Docs/03-dpn-application-deployment/aws-manual-beta/02-health-monitor/RUNBOOK.md#312-troubleshooting)
- [Data Pipeline Troubleshooting](Docs/03-dpn-application-deployment/aws-manual-beta/03-data-pipeline/RUNBOOK.md#34-troubleshooting)
- [Federator Gateway Troubleshooting](Docs/03-dpn-application-deployment/aws-manual-beta/04-federator-gateway/RUNBOOK.md#37-troubleshooting)

---

# Repository Structure

The repository is organised into structured documentation sections that guide organisations through the **deployment lifecycle of a DPN**, covering both the infrastructure layer and the application layer, for both Azure and AWS.

```
./
├── Docs/
│   ├── 01-introduction-scope
│   │   ├── 01-introduction.md
│   │   ├── 02-purpose-of-document.md
│   │   └── 03-intended-audience.md
│   │
│   ├── 02-dpn-infrastructure-deployment        # Infrastructure layer (OpenTofu)
│   │   ├── aws
│   │   │   ├── 01-prerequisites.md
│   │   │   ├── 02-configuration-parameters.md
│   │   │   ├── 03-installation-process.md
│   │   │   ├── 04-rollback-procedures.md
│   │   │   ├── 05-uninstall-decommissioning.md
│   │   │   └── README.md
│   │   └── azure
│   │       ├── 01-prerequisites.md
│   │       ├── 02-configuration-parameters.md
│   │       ├── 03-installation-process.md
│   │       ├── 04-rollback-procedures.md
│   │       ├── 05-uninstall-decommissioning.md
│   │       └── README.md
│   │
│   ├── 03-dpn-application-deployment           # Application layer (DPN components)
│   │   ├── aws-manual-beta                     # AWS: manual kubectl RUNBOOKs (interim)
│   │   │   ├── 00-shared-prerequisites
│   │   │   │   ├── manifests/
│   │   │   │   └── RUNBOOK.md
│   │   │   ├── 01-vault-certificate-manager
│   │   │   │   ├── manifests/
│   │   │   │   ├── scripts/
│   │   │   │   └── RUNBOOK.md
│   │   │   ├── 02-health-monitor
│   │   │   │   ├── manifests/
│   │   │   │   ├── scripts/
│   │   │   │   └── RUNBOOK.md
│   │   │   ├── 03-data-pipeline
│   │   │   │   ├── manifests/
│   │   │   │   └── RUNBOOK.md
│   │   │   └── 04-federator-gateway
│   │   │       ├── manifests/
│   │   │       ├── scripts/
│   │   │       └── RUNBOOK.md
│   │   │
│   │   └── azure-ado-beta                      # Azure: automated ADO CI/CD pipelines
│   │       ├── 01-prerequisites
│   │       │   └── 01-dpn-prerequisites.md
│   │       ├── 02-configuration
│   │       │   ├── 00-common-dpn-configuration.md
│   │       │   ├── 01-configure-dpn-vault-service.md
│   │       │   ├── 02-configure-dpn-health-mon-service.md
│   │       │   ├── 03-configure-dpn-certificate-manager.md
│   │       │   ├── 04-configure-dpn-federator-gateway.md
│   │       │   ├── 05-configure-dpn-data-pipelines.md
│   │       │   └── 06-configure-dpn-file-scan-service.md
│   │       ├── 03-installation
│   │       │   ├── 00-dpn-common-installation-process.md
│   │       │   ├── 01-dpn-vault-installation-process.md
│   │       │   ├── 02-dpn-monitoring-service-installation-process.md
│   │       │   ├── 03-dpn-certificate-manager-installation-process.md
│   │       │   ├── 04-dpn-federator-gateway-installation-process.md
│   │       │   ├── 05-dpn-data-pipeline-installation-process.md
│   │       │   └── 06-dpn-file-scan-service-installation-process.md
│   │       ├── 04-rollback
│   │       │   └── 04-rollback-procedures.md
│   │       └── 05-uninstall
│   │           └── 05-uninstall-decommissioning.md
│   │
│   ├── 04-dpn-architecture
│   │   └── images
│   │
│   └── 05-dpn-user-interfaces                  # Day-2 operations UIs
│       ├── 01-hashicorp-vault-ui-operations.md
│       ├── 02-apache-airflow-scheduler-ui-operations.md
│       ├── 03-federator-client-job-runner-ui-operations.md
│       ├── 04-kafka-ui-operations.md
│       ├── 05-opensearch-dashboard-ui-operations.md
│       ├── 06-jaeger-dashboard-ui-operations.md
│       ├── 07-kafka-health-ui-operations.md
│       └── images
│
├── CHANGELOG.md
└── README.md
```

---

# Key Platform Components

The DPN platform is composed of multiple containerised services, grouped as follows.

## Security Service

| Component | Purpose |
|----------|---------|
| Vault | Secrets manager — stores certificate material and keystore/truststore passwords used for mTLS |
| Certificate Manager | Automates X.509 certificate lifecycle management — renews the DSM-signed certificate and builds keystore/truststore P12 files |
| Shared File Service | SMB-based (Azure) or shared-volume (AWS) storage between the Certificate Manager and Federator Gateway for certificate P12 files |
| File Scan Service | Cloud-native file scan for files arriving on the Federator Gateway (Azure Defender for Cloud Storage). **Azure only, as of today** |

## Federator Gateway

| Component | Purpose |
|----------|---------|
| Zookeeper (Source / Target) | Coordination service for Kafka clusters |
| Kafka (Source / Target) | Message broker for producer and consumer environments |
| Kafka UI | Kafka monitoring interface |
| Redis | Offset and transmission tracking |
| Federator Server | Handles outbound data transmission to other DPNs |
| Federator Client | Handles inbound data reception from other DPNs |

## Data Processing Pipelines

Data pipelines perform validation and transformation of exchanged datasets.

| Component | Purpose |
|----------|---------|
| Adaptor | Initial data ingestion (producer/source side) |
| Producer Mapper | Producer-side schema validation |
| Extractor | Data extraction and storage (consumer/target side) |
| Consumer Mapper | Consumer-side schema validation |
| Apache Airflow | Orchestration layer scheduling the pipeline stages (webserver, scheduler, worker, triggerer, Postgres metadata DB) |

The mapper component can also be extended for more capabilities, for example transformations or schema assurance.

## Health Monitoring Stack

| Component | Purpose |
|----------|---------|
| OpenTelemetry Collector | Aggregates traces, metrics, and logs from DPN components |
| OpenSearch + Data Prepper | Log storage, indexing, and dashboarding |
| Prometheus + Thanos | Metrics collection and long-term storage |
| Jaeger | Distributed tracing UI |
| Perses | Dashboarding |
| Nginx proxy | Observability stack ingress/reverse proxy |

## Data Store

| Component | Purpose |
|----------|---------|
| Storage (Azure Storage Account / S3 bucket) | Stores files produced by DPN data pipelines, certificate P12 files |
| Kafka | Streaming service for managing events and topics during data transmission |

---

# User Interfaces & Operations

Day-to-day monitoring and operation of a running DPN node is performed through the following component user interfaces:

| Interface | Purpose | Guide |
|---|---|---|
| Hashicorp Vault UI | Certificate and secrets management | [Guide](Docs/05-dpn-user-interfaces/01-hashicorp-vault-ui-operations.md) |
| Apache Airflow UI | Data pipeline scheduling and monitoring | [Guide](Docs/05-dpn-user-interfaces/02-apache-airflow-scheduler-ui-operations.md) |
| Federator Client JobRunr Dashboard | Monitor, trigger, and troubleshoot consumer jobs | [Guide](Docs/05-dpn-user-interfaces/03-federator-client-job-runner-ui-operations.md) |
| Kafka UI | Kafka topic and broker monitoring | [Guide](Docs/05-dpn-user-interfaces/04-kafka-ui-operations.md) |
| OpenSearch Dashboard | Pipeline health monitoring and log investigation | [Guide](Docs/05-dpn-user-interfaces/05-opensearch-dashboard-ui-operations.md) |
| Jaeger UI | Distributed trace inspection | [Guide](Docs/05-dpn-user-interfaces/06-jaeger-dashboard-ui-operations.md) |
| Kafka Health UI | Health monitoring service Kafka view | [Guide](Docs/05-dpn-user-interfaces/07-kafka-health-ui-operations.md) |

---

# Deployment Platform

The DPN platform is deployed in two layers — infrastructure and application — using the following technologies.

## Infrastructure Layer (both clouds)

| Technology | Purpose |
|-----------|--------|
| OpenTofu | Infrastructure-as-code provisioning for both Azure and AWS |
| Bicep (optional) | Azure-only bootstrap for initial landing zone resources |

## Azure Application Layer

| Technology | Purpose |
|-----------|--------|
| Azure DevOps | CI/CD pipelines |
| Azure Kubernetes Service (AKS) | Container orchestration |
| Azure Container Registry (ACR) | Container image repository |
| Helm | Kubernetes deployment management |
| Kafka | Message streaming platform |
| Redis | Offset tracking and state management |
| Vault | Secrets manager for certificate material and mTLS keystore/truststore passwords |
| Docker | Container packaging |
| Azure Service Bus | Service Bus message orchestration |
| Azure Event Grid | Event emission from Azure Defender for Storage |
| Azure Storage Account | Blob storage and SMB file share |
| Azure Defender for Storage | Defender file scan service |

## AWS Application Layer

| Technology | Purpose |
|-----------|--------|
| Elastic Kubernetes Service (EKS) | Container orchestration |
| GitHub Container Registry (GHCR) | Container image repository |
| kubectl | Kubernetes deployment management (manual manifests, no CI/CD pipeline yet) |
| Kafka | Message streaming platform |
| Redis | Offset tracking and state management |
| Vault | Secrets manager for certificate material and mTLS keystore/truststore passwords |
| Docker | Container packaging |
| S3 Bucket | Data store |

---

# Security

The platform follows several core security principles:

- **Zero Trust architecture**
- **Mutual TLS (mTLS) communication between nodes**
- **Role-Based Access Control (RBAC)**
- **Secure secret storage using Azure Key Vault (Azure) or Hashicorp Vault (AWS)**
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

**Security and Responsible Disclosure**

We take security seriously. If you believe you have identified a security vulnerability in this repository, please contact the DSI team using the details in the Support and Contact section below.

**Contributing**

We welcome contributions that improve documentation clarity, deployment guidance, or operational procedures. Before submitting a pull request, please open an issue to discuss the proposed change.

**Acknowledgements**

This documentation has been developed with collaboration from organisations participating in the NESO Data Sharing Infrastructure ecosystem.

# Support and Contact

For questions, feedback, or support requests:

- Raise a work item against this repository in [Issues](https://github.com/energy-dsi/dpn-integration-playbook/issues)
- Contact the DSI team using [dsi@neso.energy](mailto:dsi@neso.energy)

---

## Maintained by the National Energy System Operator (NESO)

Copyright 2026 NESO.  This work is licensed under the Open Government Licence 3.0 (OGL). This work has been developed by NESO using content licensed by the Department for Business and Trade (UK) under the OGL.   
 
Licensed under the Open Government Licence v3.0.

For full licensing terms, [OGL_LICENSE.md](./OGL_LICENSE.md)
