# DPN Deployment Configuration Guide

---

## Table of Contents

- [Overview](#overview)
  - [Continuous Integration (CI)](#continuous-integration-ci)
  - [Continuous Deployment (CD)](#continuous-deployment-cd)
- [Global and Generic Configuration](#global-and-generic-configuration)
  - [Step1: DSI DSM Endpoint Configuration](#step1-dsi-dsm-endpoint-configuration)
  - [Step2: Azure DevOps Configuration](#step2-azure-devops-configuration)
    - [Step2.1: Node Pool Set Up](#step21-node-pool-set-up)
    - [Step2.2: Azure Environment Configuration](#step22-azure-environment-configuration)
    - [Step2.3: AKS Namespace Configuration](#step23-aks-namespace-configuration)
  - [Step3: Secrets Configuration](#step3-secrets-configuration)
  - [Step4: Certificate Configuration](#step4-certificate-configuration)
  - [Step5: Network and Ports Configuration](#step5-network-and-ports-configuration)
  - [Step6: DPN Internal Domain Naming (DNS) Configuration](#step6-dpn-internal-domain-naming-dns-configuration)
- [Review Notes](#review-notes)

---

## Overview

Data Preparation Node (DPN) consists of the following components in the DSI package:

![DPN Architecture Blocks](../../../04-dpn-architecture/images/dpn_components.png)

- **DPN User Interface** - A unified user interface experience for DPN with embedded links for individual DPN component User interfaces for example, Opensearch dashboard, Apache Perses, Jaeger, DPN Vault service, User and Role management, Kafka UI and Federator Job runner
- **DPN Health Monitoring Service** - Provides health monitoring view of DPN components, metric, traces and logs collector with Open Telemetry data format, Kafka for log consolidation, Opensearch, Jaeger and Apache Perses for logs, Traces and metrics view of individual DPN components in health dashboard
- **DPN Data Pipelines** — Responsible for producing and consuming data products of an organisation.Scheduler to control DPN data pipeline manual and automatic scheduling
- **DPN Gateway Service** — Responsible for DSM and DPN authentication, and data transfer between DPN nodes, either via the streamed gRPC Federator or the synchronous REST Federator Gateway.
- **DPN Data Store Service**
  - Storage — Contains storage accounts or S3 buckets to store files produced by DPN data pipelines, certificate material, and Redis caching data.
  - Streaming Service — DPN uses Kafka as a streaming service for managing events and topics during data transmission, authenticated via Keycloak (`SASL_SSL`/`OAUTHBEARER`) by default.
- **DPN Security Service**
  - Vault Service — Certificate regeneration for DSM communication and storage, and the store the Certificate Manager and Federator Gateway build their mTLS keystore/truststore from in memory (no shared file share).
  - Digital Certificate Manager — Manages recycling of certificates at a predefined interval from the DSI Management Node.
  - DPN Authentication Service — Keycloak-based OAuth2/OIDC Identity Provider used for Kafka broker authentication and Keycloak SSO on the DPN observability UIs.
  - DPN File Scan Service - Cloud native file scan service for files arriving on Federator Gateway, using Defender for Cloud Storage on Azure or GuardDuty Malware Protection for S3 on AWS

DPN components on Azure are deployed using **Azure DevOps (ADO) pipelines**, as defined in the DPN repositories provided by DSI. These pipelines are organised into two stages:

- **Continuous Integration (CI)**
- **Continuous Deployment (CD)**

The CI pipeline builds the application artefacts, while the CD pipeline deploys them to the target infrastructure.

This document describes the configuration parameters required for deploying **DPN nodes on Azure Kubernetes Service (AKS)**. These parameters must be configured before running the deployment pipelines.

The configuration covers the following areas:

- DSI DSM endpoint configuration
- Azure DevOps configuration
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

The **Continuous Deployment (CD)** pipeline deploys the container images to the **Azure Kubernetes Service (AKS)** cluster using Helm.

During deployment, the pipeline performs the following steps:

1. Authenticate with Azure using the configured service connection.
2. Retrieve credentials for the target AKS cluster.
3. Validate Helm charts using `helm lint`.
4. Perform a Helm **dry-run** validation.
5. Deploy the DPN platform using Helm.
6. Verify deployment status using Kubernetes rollout checks.

---
## Global and Generic Configuration

### Step1: DSI DSM Endpoint Configuration

DSI provides predefined endpoints to support the following environments:

- Development
- Integration Testing (upcoming)
- Pre-Production (upcoming)

These endpoints are publicly accessible to simplify integration and testing. Organisations must configure their pipelines to use the **appropriate endpoint for the corresponding deployment environment** as provided by DSI.

| Environment | Component | URL |
|-------------|-----------|-----|
| Pre Production-Dev (pdev) | Authentication | https://auth-mtls.dsm01.dsipreprod1.neso.energy |
| Pre Production-Dev (pdev)| Management Node | https://management.dsm01.dsipreprod1.neso.energy |
| Pre Production-Dev (pdev)| DSI DPN GRPC Producer | https://producer.dpn01.dsipreprod1.neso.energy |
| Pre Production-Dev (pdev)| DSI DPN REST Producer | https://producer-rest01.dpn01.dsipreprod1.neso.energy |

---

### Step2: Azure DevOps Configuration

The provided pipelines require the following configuration to perform **CI and CD operations**.

#### Step2.1: Node Pool Set Up

The provided pipelines are configured with the default Microsoft-hosted agent pool `ubuntu-latest` for pipeline execution.

However, DSI **recommends using a dedicated self-hosted agent pool**, which provides better control over:

- Security
- Network access
- Deployment environment management

Refer to the official Microsoft documentation for Linux node pool agent setup:
https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent

If a self-hosted agent pool is configured, update the pipeline definition as follows.

##### Existing Configuration

```yaml
pool:
  vmImage: 'ubuntu-latest'
```

##### Updated Configuration

```yaml
pool:
  name: '[agent-pool-name]'
```

---

#### Step2.2: Azure Environment Configuration

Each CD pipeline reads its Azure targeting from an environment-specific JSON config file under the repository's Azure Pipelines folder. **Update this file with your environment's values before running any pipeline.**

The config file naming differs slightly per repository:

- **Vault and Certificate Manager** (`dpn-federator-certificate-manager`): `config/<env>.json`
- **Federator Gateway** (`dpn-federator-gateway`): `config/<env>-<cluster>.json` (one per DPN cluster)

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── config/
            └── <env>.json
```

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| ENV_NAME | Deployment environment abbreviation | `<env>` |
| AZURE_SUBSCRIPTION_ID | Subscription ID where the infrastructure is deployed | `<subscription-id>` |
| RESOURCE_GROUP | Resource group containing the AKS cluster | `rg-<env>-uks-dpn-01` |
| AKS_CLUSTER | Name of the AKS cluster | `aks-<env>-uks-dpn-01` |
| NAMESPACE | Kubernetes namespace for the deployment | `ns-dpn-01` |
| KEY_VAULT_NAME | Azure Key Vault for secrets and certificates | `kv-dpn-<env>-<region>-<seq>` |
| BASE_REGISTRY | Base container registry URL | `<image-registry-url>` |
| CONTAINER_REGISTRY / CONTAINER_REGISTRY_URL | Registry name / URL | `<image-registry-url>`|

> **Note:** The **service connection**, **environment**, and (Federator Gateway only) **DPN cluster** are supplied as pipeline **runtime parameters** when you trigger a run — they are **not** keys in the JSON file. The Helm **values file** is derived from those parameters: `values-<env>.yaml` (Vault / Certificate Manager) or `values-<env>-<cluster>.yaml` (Federator Gateway).

---

#### Step2.3: AKS Namespace Configuration

Create the following Kubernetes namespaces in AKS. This setup needs to be done manually and one time in the Kubernetes cluster:

- ns-dpn-01
- ns-dpn-health-01
- ns-dpn-dp-01

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

Refer to the [DPN Federator Certificate Manager](04-configure-dpn-certificate-manager.md) section for detailed instructions on certificate lifecycle management.

The same certificate files are used across all DPN components that require integration with the Data Sharing Mechanism (DSM), specifically the Federator Gateway and Certificate Lifecycle Manager.

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
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | Organisation-specific URL for DPN-to-DPN data sharing, i.e. `producer.dpn01.dsipreprod1.neso.energy` | N/A | N/A | TLS | 443 | Bi-directional |

> **Note:** The organisation-specific URL in the final row defines the target organisation with which data sharing will occur. These firewall rules must be opened from both organisations' network perspectives. The `dsi(xxx)` notation refers to the `pdev` environments.

> **Note:** DPN uses HTTP/2 traffic over gRPC on port **443** for GRPC federator. HTTP/2 traffic requires TCP passthrough to a Layer 4 load balancer; Layer 7 load balancing may not be supported for this traffic for most of the layer 7 load balancers. The REST based federator uses HTTP/1.1 and can be used with layer 7 load balancer.DSI uses layer 4 for both REST and GRPC based federators

---

### Step6: DPN Internal Domain Naming (DNS) Configuration

Release 2.0.0 introduces a consistent internal domain naming strategy for every DPN user interface, based on **Kubernetes Service DNS** rather than per-UI ingress hostnames or IP addresses. Every browser-facing UI link is configured, from a single place, on the **DPN Unified User Interface (DPN Portal)** service — the `dpn-portal` Helm chart's `tiles[].components[].url` values — which is the source of truth for the table below.

Names follow the standard Kubernetes internal DNS pattern:

```
<service-name>.<namespace>.svc.cluster.local
```

The two AKS namespaces that host DPN UIs are `ns-dpn-01` and `ns-dpn-health-01` (see [Step2.3](#step23-aks-namespace-configuration)). The `dpn-common` TLS certificate used across these UIs is issued with exactly two SANs, `*.ns-dpn-01.svc.cluster.local` and `*.ns-dpn-health-01.svc.cluster.local`, which is why every UI is reached through one of those two domains rather than an IP address or an arbitrary hostname — a wildcard SAN can only match a DNS name, never an `iPAddress` SAN, so browsing by IP always fails certificate validation.

#### DPN component UI DNS reference (configured via the DPN Portal / Unified UI service)

| DPN Portal Tile | Component | DNS Name | Port | Namespace | Access |
|------------------|-----------|----------|------|-----------|--------|
| Users & Roles | Keycloak Console | `dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local` | 8443 | ns-dpn-01 | `dpnadmin` only |
| Data / Store | DPN Kafka (Kafka UI) | `dpn-kafka-ui-external.ns-dpn-01.svc.cluster.local` | 8086 | ns-dpn-01 | `dpnadmin`, `dpnreader` — native Keycloak OIDC |
| Gateway | GRPC Gateway Client (Federator Client / Job Runner) | `dpn-federator-client-1-external.ns-dpn-01.svc.cluster.local` | 8085 | ns-dpn-01 | `dpnadmin`, `dpnreader` — plain HTTP (see [Federator Gateway release notes](../../../06-release-notes/release-2.0.0-configuration-changes.md#dpn-federator-gateway)) |
| Data / Pipeline | Pipeline Orchestrator (Apache Airflow) | `dpn-airflow-webserver-external.ns-dpn-01.svc.cluster.local` | 8080 | ns-dpn-01 | `dpnadmin`, `dpnreader`, `dpnoperator` — native Keycloak OIDC |
| Security / Services | Certification Vault Service | `dpn-vault-https-lb.ns-dpn-01.svc.cluster.local` | 8200 | ns-dpn-01 | `dpnadmin`, `dpnreader` |
| Health / Monitoring Service | Log Stack (OpenSearch Dashboards) | `dpn-observability.ns-dpn-health-01.svc.cluster.local` | 5601 | ns-dpn-health-01 | `dpnadmin`, `dpnreader` — via `dpn-oauth2-proxy-osd` Keycloak SSO |
| Health / Monitoring Service | Traces Stack (Jaeger) | `dpn-observability.ns-dpn-health-01.svc.cluster.local` | 16686 | ns-dpn-health-01 | `dpnadmin`, `dpnreader` — via `dpn-oauth2-proxy-jaeger` Keycloak SSO |
| Health / Monitoring Service | Metrics Dashboard (Apache Perses) | `dpn-observability.ns-dpn-health-01.svc.cluster.local` | 8083 | ns-dpn-health-01 | `dpnadmin`, `dpnreader` — via `dpn-oauth2-proxy-perses` Keycloak SSO |
| Health / Monitoring Service | Collector Stack (Kafka Health UI) | `dpn-observability.ns-dpn-health-01.svc.cluster.local` | 8082 | ns-dpn-health-01 | `dpnadmin`, `dpnreader` |
| — (the Portal itself) | DPN Portal (Unified UI landing page) | `dpn-observability.ns-dpn-health-01.svc.cluster.local` | 8443 | ns-dpn-health-01 | All authenticated users — via `dpn-oauth2-proxy-portal` Keycloak SSO |

`dpn-observability` is a single static internal Load Balancer address in `ns-dpn-health-01` shared by all four Keycloak-fronted UIs above (OpenSearch, Jaeger, Perses, and the Portal itself) — each one takes the port its UI already used, so only the scheme changes (`http` → `https`) and the login changes from basic auth to Keycloak SSO.

> **Note:** This requires **client-side DNS** — browsers never resolve through the cluster's internal `kube-dns`, so both `dpn-observability.ns-dpn-health-01.svc.cluster.local` and `dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local` must be published in the organisation's own VNet or corporate DNS, resolving to the respective service's static Load Balancer IP. An Azure Private DNS zone for `svc.cluster.local` linked to the VNet, with an A record for each of the two names above, is the standard way to do this. The CD pipeline cannot verify this step — it resolves through `kube-dns` like any other pod, which says nothing about a client machine's resolution — so confirm resolution from a client machine before going live.

#### Using your own DNS instead of the `*.svc.cluster.local` names

Organisations that prefer their own corporate hostnames instead of the Kubernetes-style `*.svc.cluster.local` names above can do so, but this is **not** a DNS-only change — the TLS certificate and every Keycloak client registration are bound to the current names:

1. **Reissue or extend the `dpn-common` TLS certificate** used by the DPN Portal / oauth2-proxy releases so its SAN list covers your chosen hostnames (in addition to, or instead of, the two `*.svc.cluster.local` wildcards). TLS validation matches on the `DNS:` SAN entries only — an IP or an unlisted hostname will fail with `ERR_CERT_COMMON_NAME_INVALID` regardless of whether the CA itself is trusted.
2. **Update `externalUrl` in every affected Helm values file** — the four `oauth2-proxy` releases (`values-portal.yaml`, `values-opensearch.yaml`, `values-jaeger.yaml`, `values-perses.yaml`), the `dpn-portal` chart's own `externalUrl` and `tiles[].components[].url` entries, and `keycloak.publicUrl` — to your new hostnames.
3. **Re-register the new hostnames as Keycloak redirect URIs and Web Origins** on the shared `dpn-service-client` client in the `dpn-realm` realm. Keycloak matches redirect URIs and origins **exactly**; a login attempt against a hostname that isn't registered fails with `invalid_redirect_uri`.
4. **Point your own DNS zone at the same static internal Load Balancer IPs** already provisioned for `dpn-observability` and `dpn-keycloak-service-lb` (or provision your own if you also change the Load Balancer configuration).
5. **Re-run the CD pipelines** for the DPN Portal / Observability UIs and Keycloak (Authentication Service) so the updated values, certificate, and realm configuration are applied together — a partial update (e.g. new DNS record but unregistered redirect URI) will break login for that UI.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 | 