# DPN Deployment Configuration Guide

---

## Table of Contents

- [Overview](#overview)
  - [Continuous Integration (CI)](#continuous-integration-ci)
  - [Continuous Deployment (CD)](#continuous-deployment-cd)
- [Global and Generic Configuration](#global-and-generic-configuration)
  - [Step1: DSI DSM Endpoint Configuration](#step1-dsi-dsm-endpoint-configuration)
  - [Step2: GitHub Actions Configuration](#step2-github-actions-configuration)
    - [Step2.1: Self-Hosted Runner Set Up](#step21-self-hosted-runner-set-up)
    - [Step2.2: Azure Environment Configuration](#step22-azure-environment-configuration)
    - [Step2.3: AKS Namespace Configuration](#step23-aks-namespace-configuration)
  - [Step3: Secrets Configuration](#step3-secrets-configuration)
  - [Step4: Certificate Configuration](#step4-certificate-configuration)
  - [Step5: Network and Ports Configuration](#step5-network-and-ports-configuration)
- [Review Notes](#review-notes)

---

## Overview

Data Preparation Node (DPN) consists of the following components in the DSI package:

![DPN Architecture Blocks](../../../04-dpn-architecture/images/dpn_components.png)

- **DPN Security Service**
  - Vault Service — Certificate regeneration for DSM communication and storage, and the store the Certificate Manager and Federator Gateway build their mTLS keystore/truststore from in memory (no shared file share).
  - Digital Certificate Manager — Manages recycling of certificates at a predefined interval from the DSI Management Node.
  - DPN Authentication Service — Keycloak-based OAuth2/OIDC Identity Provider used for Kafka broker authentication and Keycloak SSO on the DPN observability UIs.
  - DPN File Scan Service - Cloud native file scan service for files arriving on Federator Gateway, using Defender for Cloud Storage on Azure or GuardDuty Malware Protection for S3 on AWS
- **DPN Data Pipelines** — Responsible for producing and consuming data products of an organisation.
- **DPN Data Store Service**
  - Storage — Contains storage accounts or S3 buckets to store files produced by DPN data pipelines, certificate material, and Redis caching data.
  - Streaming Service — DPN uses Kafka as a streaming service for managing events and topics during data transmission, authenticated via Keycloak (`SASL_SSL`/`OAUTHBEARER`) by default.
- **DPN Federator Gateway** — Responsible for DSM and DPN authentication, and data transfer between DPN nodes, either via the streamed gRPC Federator or the synchronous REST Federator Gateway.

DPN components on an airgapped Azure environment are deployed using the **GitHub Actions pipeline**, running on a shared self-hosted runner pool. Deployment is organised into two stages:

- **Continuous Integration (CI)**
- **Continuous Deployment (CD)**

The CI pipeline builds the application artefacts, while the CD pipeline deploys them to the target infrastructure.

This document describes the configuration parameters required for deploying **DPN nodes on Azure Kubernetes Service (AKS)**. These parameters must be configured before running the deployment pipelines.

The configuration covers the following areas:

- DSI DSM endpoint configuration
- GitHub Actions configuration
- Secret configuration
- Helm chart configuration
- Network and ports configuration

---

### Continuous Integration (CI)

The **Continuous Integration (CI)** pipeline is optional. Participants can either use it to build container components from the provided DPN source code, or replace it entirely by obtaining pre-built DPN containers directly from the DSI-provided **GitHub Container Registry (GHCR)**.

The **Continuous Integration (CI)** pipeline performs the following activities:

1. Build the application source code.
2. Produce container image artefacts.
3. Tag the generated container images.
4. Push the images to a container registry.

The DSI Azure reference implementation uses **Azure Container Registry (ACR)** for storing container images in Azure, due to its seamless integration with Azure services and built-in security capabilities.

Organisations may use alternative container registries if permitted by their internal network and security policies. 

---

### Continuous Deployment (CD)

The **Continuous Deployment (CD)** pipeline deploys the container images to the **Azure Kubernetes Service (AKS)** cluster using Helm. Each DPN component has its own `workflow_dispatch`-triggered GitHub Actions workflow (e.g. `dpn-vault-https-cd.yml`), all taking the same core inputs — `environment` (dev/test), `cluster` (dpn01/dpn02), and `cloud` (`azure` for this path) — plus any component-specific inputs (image tag, etc.) documented in that component's section below.

During deployment, the pipeline performs the following steps:

1. Read the environment/cluster config JSON (`.github/config/azure/<environment>-<cluster>.json`) into the job.
2. Authenticate to Azure via the shared `cloud-login` composite action — OIDC federated login (`az login --federated-token`), no service connection object involved.
3. Retrieve credentials for the target AKS cluster (`az aks get-credentials` + `kubelogin`).
4. Validate Helm charts using `helm lint` and a Helm **dry-run**.
5. Deploy the DPN component using `helm upgrade --install`.
6. Verify deployment status using Kubernetes rollout checks, and publish the deployed image digest as a workflow artifact.

---
## Global and Generic Configuration

### Step1: DSI DSM Endpoint Configuration

DSI provides predefined endpoints to support the following environments:

- Development
- Integration Testing

These endpoints are publicly accessible to simplify integration and testing. Organisations must configure their pipelines to use the **appropriate endpoint for the corresponding deployment environment** as provided by DSI.

| Environment | Component | URL |
|-------------|-----------|-----|
| Development (dev) | Authentication | https://auth-mtls.dsm01.dsipreprod1.neso.energy |
| Development (dev) | Management Node | https://management.dsm01.dsipreprod1.neso.energy |
| Development (dev) | DSI DPN Producer | https://producer.dpn01.dsipreprod1.neso.energy |
| Integration Testing (test) | Authentication | https://auth-mtls.dsm01.dsipreprod2.neso.energy |
| Integration Testing (test) | Management Node | https://management.dsm01.dsipreprod2.neso.energy |
| Integration Testing (test) | DSI DPN Producer | https://producer.dpn01.dsipreprod2.neso.energy |

---

### Step2: GitHub Actions Configuration

The provided pipelines require the following configuration to perform **CI and CD operations**.

#### Step2.1: Self-Hosted Runner Set Up

Every CD workflow runs on the shared self-hosted GitHub Actions runner pool:

```yaml
runs-on: [self-hosted, vmss]
```

This runner pool is hosted in Azure and reaches both the Azure airgap and AWS airgap environments' clusters via per-cloud OIDC (see [GitHub Actions OIDC Federated Credential](../01-prerequisites/01-dpn-prerequisites.md#github-actions-oidc-federated-credential)) — there is no separate agent pool to register or maintain per environment, and nothing in the workflow files needs editing to point at a different pool.

---

#### Step2.2: Azure Environment Configuration

Every CD workflow reads its Azure targeting from a single, consistently-named JSON config file. **Update this file with your environment's values before running any pipeline** for that environment/cluster.

```text
github-pipeline/
    └── config/
        └── azure/
            └── <environment>-<cluster>.json     # e.g. dev-dpn01.json, test-dpn02.json
```

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| ARM_SUBSCRIPTION_ID | Subscription ID where the infrastructure is deployed | `<subscription-id>` |
| RESOURCE_GROUP | Resource group containing the AKS cluster | `rg-<env>-uks-dpn-01` |
| AKS_CLUSTER | Name of the AKS cluster | `aks-<env>-uks-dpn-01` |
| NAMESPACE | Kubernetes namespace for the deployment | `ns-dpn-01` |
| KEY_VAULT_NAME | Azure Key Vault for secrets and certificates | `kv-dpn-<env>-<region>-<seq>` |
| BASE_REGISTRY | Base container registry URL | `<image-registry-url>` |
| CONTAINER_REGISTRY / CONTAINER_REGISTRY_URL | Registry name / URL | `<image-registry-url>`|

> **Note:** `environment`, `cluster`, and `cloud` (`azure`) are supplied as `workflow_dispatch` **inputs** when you trigger a run in the Actions tab — they are **not** keys in the JSON file. The Helm **values file** is derived from those inputs: `<chart-dir>/values/azure/<environment>-<cluster>.yaml`.

---

#### Step2.3: AKS Namespace Configuration

Create the following Kubernetes namespaces in AKS. This setup needs to be done manually and one time in the Kubernetes cluster:

- ns-dpn-01
- ns-dpn-health-01

```bash
kubectl create namespace <NAMESPACE>    # e.g. ns-dpn-01
```

---

### Step3: Secrets Configuration

Sensitive credentials must **not be stored in source code repositories**. They must be stored securely in one of the following vaults:

- **HashiCorp Vault** — provided with the DSI DPN package
- **Azure Key Vault** — cloud-specific option for organisations using Azure

Organisations **must change the default values of secrets** — i.e. sample values such as `changeit`, `admin-password`, `admin-admin`, etc.

Organisations should rotate secrets at defined frequencies.
The secrets are described in the individual component sections of this document that follow.

---

### Step4: Certificate Configuration

During the organisation's onboarding process, an initial certificate package containing the certificate and CA chain files is provided during the bootstrap process from the DSM User Interface. Organisations must securely store these certificates in the vault service. The following certificate artefacts are included in the DPN package:

- The **P12/PFX certificate** issued by the DSI DSM Certificate Authority (keystore)
- The **DSI certificate chain pem file** (truststore)

Refer to the [DPN Federator Certificate Manager](03-configure-dpn-certificate-manager.md) section for detailed instructions on certificate lifecycle management.

The same certificate files are used across all DPN components that require integration with the Data Sharing Mechanism (DSM), specifically the Federator Gateway and Certificate Lifecycle Manager.

In addition to that DSM-issued bundle, the platform's own internal mTLS material (the `dpn-tls` / `dpn-health-tls` Kubernetes secrets consumed by Keycloak, Kafka, cert-manager, the `oauth2-proxy` observability gateways, and Health Monitoring Service's Data Prepper) is generated and published by a shared, cloud-aware **DPN CD - Prerequisite Pipeline (Universal TLS)** workflow (`dpn-prerequisite-pipeline.yml`) rather than being created by hand. This pipeline publishes its certificate secrets into **both** the target namespace (`ns-dpn-01`, or whichever `targetNamespace` you use) **and** `ns-dpn-health-01` — Health Monitoring Service components running in that second namespace need their own copy of the same certificate material, so both namespaces must exist (see [AKS Namespace Configuration](#step23-aks-namespace-configuration)) before this pipeline is run.

---

### Step5: Network and Ports Configuration

This section describes DPN connectivity requirements for ports and protocols, including agent pool requirements for building DPN code.

![DPN Ports & Protocols](../../../04-dpn-architecture/images/DPN_ports_and_protocols.png)

The following firewall rules must be applied by the organisation before installing DPN:

| Source IP Address | Source VNET | Source Subnet | Destination IP / Zone / URL | Destination VNET | Destination Subnet | Protocol | Port(s) | Traffic Flow |
|-------------------|-------------|---------------|-----------------------------|------------------|--------------------|----------|---------|--------------|
| Node pool agent VM IP | Node Pool VM VNET | Node Pool VM subnet | `packages.confluent.io/*` | N/A | N/A | TLS | 443 | Outbound |
| Node pool agent VM IP | Node Pool VM VNET | Node Pool VM subnet | `registry-1.docker.io/*`<br>`auth.docker.io/*`<br>`production.cloudflare.docker.com`<br>`index.docker.io/*` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | `auth-mtls.dsm01.dsi(xxx).neso.energy` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | `management.dsm01.dsi(xxx).neso.energy` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | Organisation-specific URL for DPN-to-DPN data sharing | N/A | N/A | TLS | 443 | Bi-directional |

> **Note:** The organisation-specific URL in the final row defines the target organisation with which data sharing will occur. These firewall rules must be opened from both organisations' network perspectives. The `dsi(xxx)` notation refers to the `dev` and `test` environments.

> **Note:** DPN uses HTTP/2 traffic over gRPC on port **443**. HTTP/2 traffic requires TCP passthrough to a Layer 4 load balancer; Layer 7 load balancing may not be supported for this traffic for most of the layer 7 load balancers

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
