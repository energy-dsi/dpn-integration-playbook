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
    - [Step2.2: AWS Environment Configuration](#step22-aws-environment-configuration)
    - [Step2.3: EKS Namespace Configuration](#step23-eks-namespace-configuration)
  - [Step3: Secrets Configuration](#step3-secrets-configuration)
  - [Step4: Certificate Configuration](#step4-certificate-configuration)
  - [Step5: Network and Ports Configuration](#step5-network-and-ports-configuration)
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

DPN components on an airgapped AWS environment are deployed using the **GitHub Actions pipeline**, running on a shared self-hosted runner pool. Deployment is organised into two stages:

- **Continuous Integration (CI)**
- **Continuous Deployment (CD)**

The CI pipeline builds the application artefacts, while the CD pipeline deploys them to the target infrastructure.

This document describes the configuration parameters required for deploying **DPN nodes on Amazon Elastic Kubernetes Service (EKS)**. These parameters must be configured before running the deployment pipelines.

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

Organisations may use their own container registry (e.g. Amazon ECR) if permitted by their internal network and security policies, though DSI-provided images are published to GHCR by default.

---

### Continuous Deployment (CD)

The **Continuous Deployment (CD)** pipeline deploys the container images to the **Amazon EKS** cluster using Helm. 

During deployment, the pipeline performs the following steps:

1. Read the environment/cluster config JSON (`.github/config/aws/<environment>-<cluster>.json`) into the job.
2. Authenticate to AWS via the shared `cloud-login` composite action — a two-step OIDC role chain (runner → hub role → your account's `oidc_github_runner_admin` role), no long-lived access key involved. See [AWS IAM OIDC Role](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role).
3. Retrieve credentials for the target EKS cluster (`aws eks update-kubeconfig`).
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

Every CD workflow in `dpn-containerised-deployment-service` runs on the shared self-hosted GitHub Actions runner pool:

```yaml
runs-on: [self-hosted, vmss]
```

This runner pool is hosted in Azure and reaches both the Azure airgap and AWS airgap environments' clusters via per-cloud OIDC (see [AWS IAM OIDC Role](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role)) — there is no separate agent pool to register or maintain per environment, and nothing in the workflow files needs editing to point at a different pool.

---

#### Step2.2: AWS Environment Configuration

Every CD workflow reads its AWS targeting from a single, consistently-named JSON config file in `dpn-containerised-deployment-service`. **Update this file with your environment's values before running any pipeline** for that environment/cluster.

```text
dpn-containerised-deployment-service/
└── .github/
    └── config/
        └── aws/
            └── <environment>-<cluster>.json     # e.g. dev-dpn01.json, test-dpn02.json
```

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| AWS_REGION | AWS region the cluster runs in | `eu-west-2` |
| AWS_ACCOUNT_ID | Account ID hosting the infrastructure | `<account-id>` |
| EKS_CLUSTER | Name of the EKS cluster | `eks-dpn-<env>-<region>` |
| NAMESPACE | Kubernetes namespace for the deployment | `ns-dpn-01` |
| IMAGE_REGISTRY | Base container registry URL | `ghcr.io` (or your own) |
| KEY_VAULT_NAME | Azure Key Vault for secrets and certificates — **still required on AWS**, since Vault/Certificate Manager/Federator Gateway read secrets from the org's central Azure Key Vault regardless of target cloud (see [AWS IAM OIDC Role](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role)); not present in the sample AWS config, so you likely need to add it | `kv-dpn-<env>-<region>-<seq>` |

> **Note:** `environment`, `cluster`, and `cloud` (`aws`) are supplied as `workflow_dispatch` **inputs** when you trigger a run in the Actions tab — they are **not** keys in the JSON file. The Helm **values file** is derived from those inputs: `<chart-dir>/values/aws/<environment>-<cluster>.yaml`.
>
> **Most AWS values files are now populated with real environment values** — no longer the "Azure is the only cloud deployed today" placeholder stubs of earlier releases. Two charts are still pending AWS onboarding as placeholder stubs: the **Vault** chart in `dpn-federator-certificate-manager` (all four `values/aws/*.yaml`) and **`dpn-redis`**'s `test-dpn02` file in `dpn-rest-federator-gateway` — adapt each from its `values/azure/*.yaml` equivalent before relying on its CD workflow. Each component's configuration section below calls out the AWS-specific values it actually needs.

---

#### Step2.3: EKS Namespace Configuration

Create the following Kubernetes namespaces in EKS, along with the shared storage class, ServiceAccount, and image-pull secret every component depends on. This setup needs to be done manually and one time in the Kubernetes cluster — no workflow provisions this cluster bootstrap step:

- ns-dpn-01
- ns-dpn-health-01

```bash
kubectl create namespace <NAMESPACE>    # e.g. ns-dpn-01
```

An **AWS EFS CSI driver** must be installed on the cluster (as an EKS add-on or Helm chart), with an EFS filesystem created and mount targets in the subnets your worker nodes run in — `gp2`'s in-tree `kubernetes.io/aws-ebs` provisioner was removed from Kubernetes in 1.27+, so every component's charts target an EFS-backed StorageClass (`efs-sc`) instead:

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: <EFS_FILESYSTEM_ID>
  directoryPerms: "700"
EOF
```

A shared `federator-server` Kubernetes ServiceAccount is used by several components' pods:

```bash
kubectl create serviceaccount federator-server -n ns-dpn-01
```

Create the GHCR image-pull secret used by every component (imperatively — do not store real credentials in a file). Requires a GitHub personal access token with `read:packages` scope:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<GH_USER> \
  --docker-password=<GH_PAT_read:packages> \
  -n ns-dpn-01

kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<GH_USER> \
  --docker-password=<GH_PAT_read:packages> \
  -n ns-dpn-health-01
```

---

### Step3: Secrets Configuration

Sensitive credentials must **not be stored in source code repositories**. They must be stored securely in one of the following vaults:

- **HashiCorp Vault** — provided with the DSI DPN package
- **Azure Key Vault** — the org's central secrets store, used by several components regardless of target cloud (see [Step2.2](#step22-aws-environment-configuration))
- **AWS IAM Roles for Service Accounts (IRSA)** — used where a component needs direct AWS API access (S3, SQS, KMS) without a stored credential

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

---

### Step5: Network and Ports Configuration

This section describes DPN connectivity requirements for ports and protocols.

![DPN Ports & Protocols](../../../04-dpn-architecture/images/DPN_ports_and_protocols.png)

The following firewall rules must be applied by the organisation before installing DPN:

| Source IP Address | Source VPC | Source Subnet | Destination IP / Zone / URL | Destination VPC | Destination Subnet | Protocol | Port(s) | Traffic Flow |
|-------------------|-------------|---------------|-----------------------------|------------------|--------------------|----------|---------|--------------|
| EKS worker node IP range | DPN Kubernetes VPC | Node subnet | `packages.confluent.io/*` | N/A | N/A | TLS | 443 | Outbound |
| EKS worker node IP range | DPN Kubernetes VPC | Node subnet | `registry-1.docker.io/*`<br>`auth.docker.io/*`<br>`production.cloudflare.docker.com`<br>`index.docker.io/*` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VPC | DPN Kubernetes subnet | `auth-mtls.dsm01.dsi(xxx).neso.energy` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VPC | DPN Kubernetes subnet | `management.dsm01.dsi(xxx).neso.energy` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VPC | DPN Kubernetes subnet | Organisation-specific URL for DPN-to-DPN data sharing | N/A | N/A | TLS | 443 | Bi-directional |

> **Note:** The organisation-specific URL in the final row defines the target organisation with which data sharing will occur. These firewall rules must be opened from both organisations' network perspectives. The `dsi(xxx)` notation refers to the `dev` and `test` environments.

> **Note:** DPN uses HTTP/2 traffic over gRPC on port **443**. HTTP/2 traffic requires TCP passthrough to a Layer 4 network load balancer (an AWS NLB); Layer 7 load balancing may not be supported for this traffic for most layer 7 load balancers (an AWS ALB).

> **Note:** the EFS mount-target security group must allow TCP **2049** from the worker node subnets, or every EFS-backed PVC sits `Pending` indefinitely.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
