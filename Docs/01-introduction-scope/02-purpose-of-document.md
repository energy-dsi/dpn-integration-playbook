# Purpose

The purpose of this documentation is to provide a **comprehensive implementation guide** for organisations deploying a **Data Platform Node (DPN)** as part of the Data Sharing Infrastructure (DSI).

This documentation describes the technical procedures required to:

- Install the DPN platform (Infrastructure and application)
- Configure the deployment environment
- Deploy and operate DPN services
- Integrate with the DSI ecosystem
- Maintain and manage DPN infrastructure

---

## Objectives

The primary objectives of this documentation are to:

1. Provide a **clear deployment procedure** for organisations installing a DPN node.
2. Describe the **configuration requirements** for infrastructure, networking, and security.
3. Provide **operational guidance** for running and maintaining DPN services.
4. Enable organisations to **securely exchange data** with other DPN nodes.
5. Provide reference documentation for **rollback, troubleshooting, and uninstallation procedures**.

---

## Scope

This documentation focuses on the deployment and operation of DPN nodes using the following technologies:

- Azure DevOps CI/CD pipelines
- Azure Kubernetes Service (AKS)
- Helm deployments
- Kafka messaging platform
- Redis state management
- Container-based microservices

The documentation assumes that the DPN node will be deployed within an **Azure cloud environment**, although the platform architecture is designed to support deployment in other environments with appropriate adjustments.

**Deployment on AWS - Alpha Stage**
This document provides reference Github Actions pipelines for application deployment on AWS platform. However, infrastructure deployment is not covered in this version.Organizations using AWS still require to develop infrastructure pipelines on their own.

**Deployment on GCP - Upcoming**
This is not covered in this document yet


---

## Intended Outcome

By following the procedures in this documentation, organisations will be able to:

- Successfully deploy a DPN node on either Azure, AWS or GCP. (Support for other clouds upcoming)
- Integrate with the DSI ecosystem
- Exchange data securely with other participating organisations
- Operate and maintain the platform within their infrastructure environment