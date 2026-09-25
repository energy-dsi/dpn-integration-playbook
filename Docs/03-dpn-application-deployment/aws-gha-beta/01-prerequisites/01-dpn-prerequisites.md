# DPN Deployment Prerequisites

## Table of Contents

- [DPN Deployment Prerequisites](#dpn-deployment-prerequisites)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Organisation Prerequisites](#organisation-prerequisites)
  - [Software Prerequisites](#software-prerequisites)
    - [Optional Tools](#optional-tools)
  - [Service Prerequisites](#service-prerequisites)
  - [Accessibility Prerequisites](#accessibility-prerequisites)
    - [Access Requirements](#access-requirements)
      - [GitHub Access](#github-access)
      - [AWS IAM OIDC Role](#aws-iam-oidc-role)
      - [EKS Access](#eks-access)
      - [Data Pipeline Access](#data-pipeline-access)
  - [Security Prerequisites](#security-prerequisites)
  - [Network Prerequisites](#network-prerequisites)
  - [Certificate Prerequisites](#certificate-prerequisites)
    - [Certificate Lifecycle and Management](#certificate-lifecycle-and-management)
  - [Skills Prerequisites](#skills-prerequisites)
  - [Assumptions](#assumptions)
  - [Review Notes](#review-notes)

## Overview

This section lists the prerequisites that must be completed **before installing DPN nodes into an AWS environment using the automated GitHub Actions deployment pipeline**.

This is the path for organisations deploying a DPN into their own **AWS environment** 

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

The following softwares must be available on the machine(s) used to configure DPN nodes (the shared self-hosted GitHub Actions runner already has the tools the pipeline itself needs — this list is for local/administrative use).

- Java 21  
- [Maven 3.9+](https://maven.apache.org/download.cgi)  
- [Docker – latest version](https://www.docker.com/)  
- [Git – latest version](https://git-scm.com/)  
- [Python 3.14.0](https://www.python.org)  
- OpenSSL – latest version  

DPN repositories required:

- [DPN-Infra](https://github.com/energy-dsi/dpn-infrastructure-aws)  
- [DPN-Data-Pipeline](https://github.com/energy-dsi/dpn-data-pipelines)
- [DPN-Federator Gateway](https://github.com/energy-dsi/dpn-federator-gateway)
- [DPN-Rest-Federator-Gateway](https://github.com/energy-dsi/dpn-rest-federator-gateway)
- [DPN-Federator Certificate-Manager](https://github.com/energy-dsi/dpn-federator-certificate-manager)
- [DPN-Health-Monitoring-Service](https://github.com/energy-dsi/dpn-health-monitoring-service)
- [DPN-File-Scan-Service](https://github.com/energy-dsi/dpn-file-scan-service)
- [DPN-Authentication-Service](https://github.com/energy-dsi/dpn-authentication-service)

### Optional Tools

The following tools are optional but recommended for deployment and operations:

- AWS CLI – latest version  
- Kubectl – latest version  
- Helm – latest version  
- OpenTofu – latest version  
- DigiCert utility – latest version (for CSR generation)
- OpenSSL – latest version  


---
## Service Prerequisites

The following cloud services and licenses are required to run DPN nodes on the AWS platform.

- A Git Hub user account and **PAT token** to fetch from GitHub.
- A Docker.io **user account** and **password** to fetch from docker repository
- An active **AWS account** with sufficient service quotas for EKS, EC2, S3, IAM, and KMS
- An **administrative EC2 instance** deployed in the same VPC where the DPN components are deployed with minimal configuration, for any local/manual operations (Session Manager access, no public IP required)
- **AWS Systems Manager (SSM) Session Manager** to connect to that instance without a bastion host or exposed SSH

---
## Accessibility Prerequisites

The following configuration is recommended to securely operate DPN nodes on the AWS platform.  
DSI recommends this approach as a **secure and best-practice model**.

- Use private subnets and VPC endpoints wherever possible  
- Use **self-hosted GitHub Actions runner pool** (`[self-hosted, vmss]`) rather than GitHub-hosted runners 
- Use **Identity and Access Management (IAM) Roles** instead of long-lived static credentials  
- Enable **encryption of data at rest and in transit**  
- Follow a **Zero Trust security model**

---
### Access Requirements

The following access configurations are required for DPN deployment.

#### GitHub Access

- A **Personal Access Token (PAT)** with **read-only access** to GitHub repositories in order to clone the required code.

#### AWS IAM OIDC Role

An **IAM role in your target AWS account**, with:

- Permissions scoped to DPN deployment actually needs at minimum EKS cluster access, plus IAM/S3/KMS permissions for whichever components' prerequisites your organisation provisions (IRSA role, S3 buckets, AWS KMS auto-unseal key, etc.)

#### EKS Access

An **IAM role or user** used for managing **Amazon Elastic Kubernetes Service (EKS)** with the following permissions:

- Pull access to the container registry (GHCR, or your own registry) — to pull container images
- Read access to whichever secrets store backs your cluster's secrets — to access secrets inside containers

#### Data Pipeline Access

- An **S3 bucket** with **read and write permissions** for file passthrough used by the data pipeline.

---
## Security Prerequisites

The following security practices must be implemented before deploying DPN nodes.

- Adoption of a **Zero Trust security model**  
- **Mutual TLS (mTLS)** enforced for communication between organisations DPNs and DSM  
- Storage of secrets in **AWS Secret Manager** (the org's central secrets store, used cross-cloud) or an equivalent secure secret store  
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

### Certificate Lifecycle and Management

DPN-to-DPN and DPN-to-DSM communications are secured using mutual TLS (mTLS), meaning both parties in every connection must present a valid certificate to authenticate themselves. Each DPN therefore requires a DSI-issued certificate to participate in the network — without one, it cannot establish any connection with another DPN or with the DSM.

During initial DPN setup, a participant uploads a Certificate Signing Request (CSR) through the DSM user interface. The DSM signs the CSR and returns a bootstrap certificate bundle for download. The participant installs this bundle into their DPN's Vault, after which certificate renewal is handled automatically — the DPN manages its own certificate lifecycle without further manual intervention under normal operating conditions.

If a certificate expires before automatic renewal has taken place — for example due to the DPN being offline during the renewal window — the participant will need to return to the DSM user interface, upload a new CSR, and download a fresh bootstrap certificate to restore connectivity. As with the initial setup, the downloaded certificate bundle should be saved at the point of download since it cannot be retrieved from the platform again once the session ends.

Organisations should factor this recovery process into their operational runbooks so that certificate expiry does not result in extended loss of connectivity to the DSI network.

While the DPN certificates expire in every 24 Hrs, there may be a need for participants to install certificates to their Edge Proxies e.g. Cloudflare or Akamai to do mTLS negotiation. A 24 Hrs TTL certificate is too short life time . Considering this challenge DSM also provides a server sign certificate with 60 days TTL. The server sign certificate generation process is similar and can be referenced from the [DSI Certificate Management UI Guide](../../../05-dpn-user-interfaces/10-dsi-certificate-management-ui-operations.md).

_**Note:** Organisations operating DPNs behind Cloudflare or equivalent infrastructure should factor the manual renewal process into their operational runbooks until this capability is available and also actively monitor the expiry of the certificate installed outside the DPN certificate manager component since DSI does not generate any alert on certificate expiry at this moment.Also this server certificate can not be used in the DPN Federtor Gateway client to do authentication with DSM_

---
## Skills Prerequisites

DSI recommends the following skillsets to ensure smooth installation and operation of DPN as mentioned in this installation procedure.

- GitHub Actions / CI-CD Engineer  
- AWS Infrastructure Engineer  
- AWS Administrator  

---
## Assumptions

The prerequisites described in this document assume the following:

- The organisation plans to deploy **DPN on an AWS cloud infrastructure**  
- Deployment (CD) runs via the GitHub Actions pipeline, executed on the shared self-hosted runner pool, into the organisation's AWS landing zone (EKS)

---
## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
