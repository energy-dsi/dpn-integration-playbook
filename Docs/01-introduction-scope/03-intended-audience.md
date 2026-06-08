# Intended Audience

This documentation is intended for **technical teams responsible for deploying and operating a Data Preparation Node (DPN)** within an organisation.

The guide assumes that readers have experience with cloud infrastructure, container technologies, and DevOps practices.It is also assumed that readers will have an overview understanding of the DSI using the resources of the DSI Shared Knowledge Base.

---

## Primary Audience

The primary audience includes the following technical roles:

### Platform Engineers

Platform engineers responsible for:

- Designing the infrastructure environment
- Deploying container platforms
- Managing Kubernetes clusters
- Maintaining infrastructure services

---

### DevOps Engineers

DevOps engineers responsible for:

- Managing CI/CD pipelines
- Building container images
- Deploying applications using automated pipelines
- Managing container registries

---

### Cloud Infrastructure Engineers

Cloud engineers responsible for:

- Provisioning Azure infrastructure
- Managing virtual networks and firewall rules
- Configuring identity and access management
- Managing Azure Kubernetes Service (AKS)

---

### System Administrators

System administrators responsible for:

- Managing certificates and security configuration
- Maintaining operating environments
- Monitoring system health and logs

---

## Secondary Audience

This documentation may also be useful for:

- Solution architects designing DPN deployments
- Security teams reviewing infrastructure architecture
- Integration teams implementing data exchange workflows

---

## Knowledge Requirements

Readers should have working knowledge of the following technologies:

- Kubernetes and container orchestration
- Docker containerisation
- Their organisation’s chosen cloud infrastructure
- DevOps pipelines
- Helm deployments
- Network and firewall configuration
- TLS certificates and secure communications

---

## Assumed Environment

The documentation assumes that the organisation intends to deploy DPN nodes using:

### Azure Platform : 

- Azure DevOps CI/CD pipelines
- Azure Kubernetes Service (AKS)
- Azure Container Registry (ACR)

### AWS Platform

- TBD and upcoming

### GCP Platform

- TBD and upcoming

However, organisations may adapt the deployment architecture to other environments if required.