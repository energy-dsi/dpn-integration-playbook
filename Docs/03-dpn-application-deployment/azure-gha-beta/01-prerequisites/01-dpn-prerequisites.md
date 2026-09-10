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
      - [Azure Service Principal](#azure-service-principal)
      - [GitHub Actions OIDC Federated Credential](#github-actions-oidc-federated-credential)
      - [AKS Access](#aks-access)
      - [Data Pipeline Access](#data-pipeline-access)
  - [Security Prerequisites](#security-prerequisites)
  - [Network Prerequisites](#network-prerequisites)
  - [Certificate Prerequisites](#certificate-prerequisites)
    - [Certificate Lifecycle and Management](#certificate-lifecycle-and-management)
  - [Skills Prerequisites](#skills-prerequisites)
  - [Assumptions](#assumptions)
  - [Review Notes](#review-notes)

## Overview

This section lists the prerequisites that must be completed **before installing DPN nodes into an airgapped Azure environment using the automated GitHub Actions deployment pipeline**.

This is the path for organisations deploying a DPN into their own **Azure airgapped environment** (a separate Azure tenant/subscription outside NESO's own cloud, reachable only via the shared self-hosted GitHub Actions runner). It does not apply to DPN instances hosted directly on NESO's own Azure cloud — see [Azure (ADO)](../azure-ado-beta/01-prerequisites/01-dpn-prerequisites.md) for that path instead.

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
- [Python 3.14.0](https://www.python.org)  
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
- **Write access to the `dpn-containerised-deployment-service` GitHub repository's Actions** (to trigger `workflow_dispatch` deployment pipelines)
- An **Windows Azure Virtual Machine** deployed in the same Azure Network where the DPN components are deployed with minimal configuration (Preferred SKU B8ms or equivalent)
- A **Bastion Host** to connect to the virtual machine

---
## Accessibility Prerequisites

The following configuration is recommended to securely operate DPN nodes on the Azure platform.  
DSI recommends this approach as a **secure and best-practice model**.

- Use private networks and private endpoints wherever possible  
- Use the shared **self-hosted GitHub Actions runner pool** (`[self-hosted, vmss]`) rather than GitHub-hosted runners  
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

#### GitHub Actions OIDC Federated Credential

- A **federated identity credential** on the Service Principal's Azure AD App Registration, trusting the GitHub OIDC token issuer for the `dpn-containerised-deployment-service` repository (subject: the environment/branch that will run the deployment workflows). This is what the pipeline's `cloud-login` composite action uses to run `az login --service-principal --federated-token` — no client secret or service connection object to create or rotate.
- The App Registration's `AZURE_CLIENT_ID` and Azure AD `AZURE_TENANT_ID` stored as GitHub Actions secrets on the repository (or the relevant GitHub Environment).

#### AKS Access

A **Service Principal or Azure AD group** used for managing **Azure Kubernetes Service (AKS)** with the following permissions:

- **Azure Container Registry Pull** role – to pull container images  
- **Azure Key Vault Secrets Reader** role – to access secrets inside containers  

#### Data Pipeline Access

- A **Blob Storage / S3 SAS Token** with **read and write permissions** for file passthrough used by the data pipeline.

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

### Certificate Lifecycle and Management

DPN-to-DPN and DPN-to-DSM communications are secured using mutual TLS (mTLS), meaning both parties in every connection must present a valid certificate to authenticate themselves. Each DPN therefore requires a DSI-issued certificate to participate in the network — without one, it cannot establish any connection with another DPN or with the DSM.

During initial DPN setup, a participant uploads a Certificate Signing Request (CSR) through the DSM user interface. The DSM signs the CSR and returns a bootstrap certificate bundle for download. The participant installs this bundle into their DPN's Vault, after which certificate renewal is handled automatically — the DPN manages its own certificate lifecycle without further manual intervention under normal operating conditions.

If a certificate expires before automatic renewal has taken place — for example due to the DPN being offline during the renewal window — the participant will need to return to the DSM user interface, upload a new CSR, and download a fresh bootstrap certificate to restore connectivity. As with the initial setup, the downloaded certificate bundle should be saved at the point of download since it cannot be retrieved from the platform again once the session ends.

Organisations should factor this recovery process into their operational runbooks so that certificate expiry does not result in extended loss of connectivity to the DSI network.

While the DSM is capable of issuing short-lived certificates and the DPN includes built-in capability to renew them automatically before expiry, the current certificate validity period is set to 60 days. This decision is driven by a known constraint affecting organisations that deploy their DPN behind Cloudflare or an equivalent reverse proxy or edge security layer. In such deployments, enterprise security policies may be configured to terminate mTLS at the Cloudflare boundary rather than passing it through end-to-end. Where mTLS is terminated at Cloudflare, the certificate installed at that layer is outside the DPN's automated renewal process — meaning that when a certificate is renewed by the DPN, the updated certificate must also be manually installed at the Cloudflare boundary. A shorter certificate lifetime would increase the frequency of this manual intervention. Setting the validity period to 60 days balances the security benefit of certificate rotation against the operational burden of manual installation at the proxy layer.

This constraint is under active review. Solutions have been identified that are expected to address 24 hrs certificate TTL back from 60 days while issuing a different certificate for proxy-terminated mTLS deployments. The additional long term TTL certificate to be provided from a different endpoint and serves only the purpose of client authentication at edge proxies for DPN. This longer TTL certificate can not be used for DSM authentication or any client certificate. This change is targeted for delivery in PI4.

_**Note:** Organisations operating DPNs behind Cloudflare or equivalent infrastructure should factor the current manual renewal process into their operational runbooks until this capability is available and also actively monitor the expiry of the certificate installed outside the DPN certificate manager component since DSI does not generate any alert on certificate expiry at this moment._

---
## Skills Prerequisites

DSI recommends the following skillsets to ensure smooth installation and operation of DPN as mentioned in this installation procedure.

- GitHub Actions / CI-CD Engineer  
- Azure Infrastructure Engineer  
- Azure Administrator  

---
## Assumptions

The prerequisites described in this document assume the following:

- The organisation plans to deploy **DPN on an airgapped Azure cloud infrastructure**  
- Deployment (CD) runs via the **`dpn-containerised-deployment-service` GitHub Actions pipeline**, executed on the shared self-hosted runner pool, into the organisation's Azure landing zone

---
## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| 15-May-2026 | DSI Assurance   | Draft  | V0.1.0 |