# Introduction

The **Data Preparation Node (DPN)** enables organisations to securely exchange data with other participating organisations while following **Data Sharing Infrastructure (DSI)** ecosystem standards.

A DPN is deployed within an organisation’s own infrastructure and provides the capability to publish, receive, and process data in a **federated data-sharing architecture**.

The DPN platform enables organisations to:

- Maintain **ownership and control of their data**
- Exchange data securely with other organisations
- Participate in a **federated data ecosystem**
- Process and validate datasets before sharing

The architecture follows a **federated model**, where each organisation operates its own DPN node while maintaining interoperability with other participating nodes.Federation of identity and access agreements is provided by the Data Sharing Mechanism service.

---

## DPN Platform Components

The DPN deployment consists of the following major components.

### Federator Gateway Platform (DPN-DG*)

The **Federator** enables secure data exchange between organisations, over either of two federation styles sharing the same certificate, Identity Provider and Management Node infrastructure:

- **gRPC Federator** — a streamed, Kafka-to-Kafka pipeline for producer/consumer data exchange.
- **REST Federator Gateway** — a synchronous, HTTPS request/response alternative for organisations that need an API-driven integration rather than a streamed pipeline.

Key functions include:

- Secure communication between nodes using **mutual TLS (mTLS)**
- Transmission of data between producer and consumer environments using **gRPC** (streaming) or **REST over HTTPS** (synchronous)
- Message streaming using **Apache Kafka**, authenticated via **Keycloak** (`OAUTHBEARER`) in production
- Coordination using **Zookeeper**
- Offset and transmission tracking using **Redis**
- File storage as **Azure Storage Account blob service** or **S3 bucket in AWS**
- Hashicorp Vault service for **certificate material** storage, with component authentication via Vault **AppRole**
- Keycloak-based **Identity Provider** (Data Preparation Node Authentication Service) for token issuance and validation from DSM

---

### Data Processing Pipeline (DPN-DP*)

The **DPN Data Pipeline** performs validation and transformation of datasets before and after transmission.

The pipeline includes several processing stages:

- Adaptor (source)
- Security labelling (producer/source)
- Extractor (consumer/target)
- The mapper component can also be extended for more capabilities for example transformations or schema assurance.

These processing stages ensure that datasets conform to the required **data schemas and governance rules** before being exchanged.

---

### DPN Security Services (DPN-SS*)

The **DPN Security Services** provide the certificate, identity, and file integrity controls that underpin secure operation of the DPN node.

Key functions include:

- **File Scan Service** — scans inbound files for threats on both Azure and AWS deployments using cloud native scan services Defender for Azure and GuardDuty for AWS
- **Certificate Manager Service** — automates renewal of certificates used across DPN components
- **Vault Service** — stores and manages certificate material using Hashicorp Vault
- **Authentication Service** — Keycloak-based Identity Provider issuing and validating tokens for DPN components

---

### DPN Monitoring Services (DPN-MON*)

The **DPN Monitoring Services** provide health, observability, and telemetry capabilities across the DPN platform

Key functions include:

- **Opensearch Dashboard** - To view health status of individual DPN componnets,logs
- **Apache Perses Dashboard** - To view metrics information from DPN components
- **Jaeger Dashboard** - To view traces information of DPN componnets
- **Kafka UI Dashboard** - To view health monitoring log accumulation in Kafka
- **Opentelemetry Collector** - To accumulate logs from all DPN components and send to Kafka
- **Opensearch Dataprepper** - Ingest logs from Kafka and reformat to show logs on the Opensearch Dashboard
- **Jaeger Ingester** - Ingest traces from Kafka and reformat to show traces on the Jaeger Dashboard
- **Prometheus Ingester** - Ingest metrices from Kafka and reformat to show metrices on the Apache Perses Dashboard

---

### DPN Data Store Services (DPN-DS*)

The **DPN Data Store Services** provide the messaging and storage backbone used by the DPN platform.

- **Apache Kafka** for message streaming between producer and consumer environments
- **Blob storage** (Azure Storage Account blob service or AWS S3) for file storage

---

### DPN Unified User Interface (DPN-UI*)

The **DPN Unified User Interface** provides a consolidated portal for monitoring and operating the DPN node. It embeds the necessary links to switch to relevant user interfaces for Data Pipeline, Health monitoring, kafka and federator gateway client (Job runner)

---

## Deployment Model

The DPN platform is designed to run within an organisation’s own infrastructure using modern cloud-native technologies.

Typical deployments use:

### Azure Deployment Using Azure DevOPS `(ADO)`

- **Azure Kubernetes Service (AKS)** for container orchestration
- **Azure DevOps CI/CD pipelines** for automated deployment
- **Azure Container Registry (ACR)** for container image management
- **Helm charts** for Kubernetes deployments

### Azure Deployment Using Github Actions Execution `(GHA)`

- **Azure Kubernetes Service (AKS)** for container orchestration
- **GitHub Actions based Workflow** for automated deployment
- **GitHub Container Registry (GHCR)** for container image management
- **Helm charts** for Kubernetes deployments

### AWS Deployment with Github Actions Execution `(GHA)`

- **GitHub Actions based Workflow** for automated deployment
- **Elastic Kubernetes Service (EKS)** for container orchestration
- **GitHub Container Registry (GHCR)** for container image management
- **Helm charts** for Kubernetes deployments


This architecture ensures that deployments are:

- scalable
- repeatable
- secure
- easy to maintain

---

## Document Structure

The documentation in this repository provides guidance for deploying and operating a DPN node.

The documentation covers:

- Prerequisites and infrastructure requirements
- Deployment configuration
- Installation procedures
- Operational procedures
- Rollback and recovery procedures
- Uninstallation procedures

These documents collectively form the **DPN Installation and Operations Playbook** for organisations participating in the DSI ecosystem.