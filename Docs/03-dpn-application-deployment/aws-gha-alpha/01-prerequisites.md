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
    - [IAM Role](#iam-role)
    - [AWS IAM Role (GitHub Actions Integration)](#aws-iam-role-github-actions-integration)
    - [EKS Access](#eks-access)
    - [Data Pipeline Access](#data-pipeline-access)
- [Security Prerequisites](#security-prerequisites)
- [Network Prerequisites](#network-prerequisites)
- [Certificate Prerequisites](#certificate-prerequisites)
- [Skills Prerequisites](#skills-prerequisites)
- [Assumptions](#assumptions)
- [Review Notes](#review-notes)

---

## Overview

This section lists the prerequisites that must be completed **before installing DPN nodes from the repository in an AWS environment**.

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
| AWS CLI | Latest |
| Kubectl | Latest |
| Helm | Latest |
| OpenTofu | Latest |
| DigiCert utility | Latest (for CSR generation) |

---

## Service Prerequisites

The following cloud services and licences are required to run DPN nodes on the AWS platform.

- A GitHub user account with appropriate repository access (and optionally a Personal Access Token (PAT) if required for integrations)
- A container registry account (e.g., Docker Hub / GHCR / other) with credentials (username/password or token) to pull container images
- An active AWS account (Pay-As-You-Go or Enterprise Agreement equivalent)
- Configured AWS Identity and Access Management (IAM) with required roles and permissions
- A configured OIDC trust relationship between GitHub and AWS IAM for secure, keyless authentication
- An Amazon EKS (Elastic Kubernetes Service) cluster deployed in the target environment
- A compute instance (e.g., Amazon EC2) within the same network (VPC) as the EKS cluster for administrative access
  (Recommended instance size equivalent to Azure B8ms or as per workload requirements)
- A secure access mechanism such as a bastion host or AWS Systems Manager (SSM Session Manager) to connect to the compute instance

---

## Accessibility Prerequisites

The following configuration is recommended to securely operate DPN nodes on the AWS platform. DSI recommends this approach as a **secure and best-practice model**.

- Use **VPC with private subnets, VPC endpoints**
- Use **self-hosted runners OR CodeBuild environments**
- Use **IAM roles (not local users)**
- Enable **encryption at rest (EBS, S3, RDS) and in transit (TLS)**
- Follow **Zero Trust model**

---

### Access Requirements

The following access configurations are required for DPN deployment.

#### GitHub Access

- A **Personal Access Token (PAT)** with **read-only access** to the required GitHub repositories

#### IAM Role

Create an **AWS IAM Role** with permissions:

| Role | Purpose |
|------|---------|
| AdministratorAccess or scoped IAM policies | Resource provisioning |
| IAM PassRole | Assign roles |
| AmazonEC2FullAccess | Infrastructure creation |
| AmazonECRFullAccess | Push container images |
| SecretsManagerFullAccess | Manage secrets |
| ACMFullAccess | Manage certificates |


### AWS IAM Role (GitHub Actions Integration)

An IAM Role configured with a trust relationship to GitHub (via OIDC) and used by GitHub Actions workflows to securely access AWS resources.

#### EKS Access

A **IAM roles** used for managing **Elastic Kubernetes Service (EKS)** with the following permissions:

| Role | Purpose |
|------|---------|
| AmazonECRReadOnly | Pull container images |
| Secrets Manager access | Inject secrets into pods |

#### Data Pipeline Access

- A **Use Amazon S3 pre-signed URLs OR IAM policies** for file passthrough used by the data pipeline

---

## Security Prerequisites

The following security practices must be implemented before deploying DPN nodes.

- Adoption of a **Zero Trust architecture**
- **Mutual TLS (mTLS)** enforced for all inter-organisation communication
- Storage of secrets in **AWS Secrets Manager** or an equivalent secure secret store
- Regular **rotation of secrets and encryption keys**
- Regular **rotation of certificates** used for communication

For **Bring Your Own (BYO)** components, organisations must follow recommended security scanning practices.

DSI-provided code is scanned using the following tools (not limited to):

| Tool | Purpose |
|------|---------|
| **SonarQube** | Code quality and test coverage |
| **Checkmarx** | Static code analysis |
| **JFrog Xray** | Container security scanning |

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
| AWS DevOps Engineer | Configure and manage CI/CD pipelines |
| AWS Infrastructure Engineer | Provision and maintain AWS resources |
| AWS Administrator | Manage IAM, networking, platform access |

---

## Assumptions

The prerequisites described in this document assume the following:

- The organisation plans to deploy DPN on AWS cloud infrastructure
- The organisation will use GitHub Actions for Continuous Integration and Continuous Deployment (CI/CD) into the AWS environment

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
