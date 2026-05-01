# Introduction

The **Data Platform Node (DPN)** enables organisations to securely exchange data following **Data Sharing Infrastructure (DSI)** ecosystem standars with other Organizations participating in the Data Sharing process.

A DPN node is deployed within an organisation’s own infrastructure and provides the capability to publish, receive, and process data in a **federated data-sharing architecture**.

The DPN platform enables organisations to:

- Maintain **ownership and control of their data**
- Exchange data securely with other organisations
- Participate in a **federated data ecosystem**
- Process and validate datasets before sharing

The architecture follows a **decentralised model**, where each organisation operates its own DPN node while maintaining interoperability with other participating nodes.

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

---

### Data Processing Pipeline

The **DPN Data Pipeline** performs validation and transformation of datasets before and after transmission.

The pipeline includes several processing stages:

- Adaptor (source)
- Schema assurance (producer/source)
- Security labelling (producer/source)
- Schema assurance (consumer/target)
- Extractor (consumer/target)

These processing stages ensure that datasets conform to the required **data schemas and governance rules** before being exchanged.

---

## Deployment Model

The DPN platform is designed to run within an organisation’s own infrastructure using modern cloud-native technologies.

Typical deployments use:

Multicloud deployment support with Azure, AWS and GCP but to be extended for other clouds in future. 

### Azure Deployment: 

- **Azure Kubernetes Service (AKS)** for container orchestration
- **Azure DevOps CI/CD pipelines** for automated deployment
- **Azure Container Registry (ACR)** for container image management
- **Helm charts** for Kubernetes deployments

### AWS Deployment: 
The present DSI playbook provides a guidance on using Github Actions based pipelines for AWS deployment. However, infrastructure and detailed application deployment steps are in alpha testing phase. Orgnizations may use this as prescriptive guidance to deploy DPN in AWS. 

### GCP Deployment: 
TBD and upcoming

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