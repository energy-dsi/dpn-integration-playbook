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

### Federator Platform

The **Federator** enables secure data exchange between organisations.

Key functions include:

- Secure communication between nodes using **mutual TLS (mTLS)**
- Transmission of data between producer and consumer environments using GRPC
- Message streaming using **Apache Kafka**
- Coordination using **Zookeeper**
- Offset and transmission tracking using **Redis**
- File storage as **Azure Storage Account blob service** or **S3 bucket in AWS**
- Hashicorp Vault service for **Certificate files** storage

---

### Data Processing Pipeline

The **DPN Data Pipeline** performs validation and transformation of datasets before and after transmission.

The pipeline includes several processing stages:

- Adaptor (source)
- Security labelling (producer/source)
- Extractor (consumer/target)
- The mapper component can also be extended for more capabilities for example transformations or schema assurance.

These processing stages ensure that datasets conform to the required **data schemas and governance rules** before being exchanged.

---

## Deployment Model

The DPN platform is designed to run within an organisation’s own infrastructure using modern cloud-native technologies.

Typical deployments use:

### Azure Deployment Using Azure DevOPS `(ADO)`

- **Azure Kubernetes Service (AKS)** for container orchestration
- **Azure DevOps CI/CD pipelines** for automated deployment
- **Azure Container Registry (ACR)** for container image management
- **Helm charts** for Kubernetes deployments

### AWS Deployment with Manual Execution

DPN integration playbook at this moment does not cover GitHub Actions based flows and pipelines for AWS deployment of application. The manual deployment runbook and deployment yaml files provided with kubectl run commands to perform AWS deployment. 

_**Note** This is an interim instruction and future release of playbook to contain the AWS deployment instruction using GitHub Actions and GitHub Runners based flows._ 

- **Elastic Kubernetes Service (EKS)** for container orchestration
- **GitHub Container Registry (GHCR)** for container image management
- **kubectl utility** for Kubernetes deployments


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