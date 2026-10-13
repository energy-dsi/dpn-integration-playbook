# DPN Deployment Configuration Guide

---

## Table of Contents

- [Overview](#overview)
  [Global and Generic Configuration](#global-and-generic-configuration)
  - [Step1: DSI DSM Endpoint Configuration](#step1-dsi-dsm-endpoint-configuration)
  - [Step2: GitHub Actions Configuration](#step2-github-actions-configuration)
    - [Step2.1: Self-Hosted Runner Set Up](#step21-self-hosted-runner-set-up)
    - [Step2.2: AWS Environment Configuration](#step22-aws-environment-configuration)
    - [Step2.3: EKS Namespace Configuration](#step23-eks-namespace-configuration)
    - [Step2.4: GitHub Actions Secrets and Environments](#step24-github-actions-secrets-and-environments)
  - [Step3: Secrets Configuration](#step3-secrets-configuration)
  - [Step4: Certificate Configuration](#step4-certificate-configuration)
  - [Step5: Network and Ports Configuration](#step5-network-and-ports-configuration)
  - [Step6: DPN Internal Domain Naming (DNS) Configuration](#step6-dpn-internal-domain-naming-dns-configuration)
  - [Step7: DPN Secrets Reference](#step7-dpn-secrets-reference)
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
  - DPN File Scan Service - Cloud native file scan service for files arriving on Federator Gateway, using GuardDuty Malware Protection for S3 on AWS

DPN components on an AWS environment are deployed using the **GitHub Actions pipeline**, running on a shared self-hosted runner pool. Deployment is organised into two stages:

- **Continuous Deployment (CD)**

This document describes the configuration parameters required for deploying **DPN nodes on Amazon Elastic Kubernetes Service (EKS)**. These parameters must be configured before running the deployment pipelines.

The configuration covers the following areas:

- DSI DSM endpoint configuration
- GitHub Actions configuration
- Secret configuration
- Helm chart configuration
- Network and ports configuration

### Continuous Deployment (CD)

The **Continuous Deployment (CD)** pipeline deploys the container images to the **AWS EKS** cluster using Helm. 

During deployment, the pipeline performs the following steps:

1. Read the environment/cluster config JSON (`.github/config/aws/<environment>-<cluster>.json`) into the job.
2. Authenticate to AWS via the shared `cloud-login` composite action (`.github/actions/cloud-login`) — a two-step OIDC role chain (runner → `oidc_github_runner_hub` hub role → your account's `oidc_github_runner_admin` role), no long-lived access key involved. See [AWS IAM OIDC Role](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role).
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

The provided pipelines require the following configuration to perform **CD operations**.

#### Step2.1: Self-Hosted Runner Set Up

Every CD workflow runs on the shared self-hosted GitHub Actions runner pool. This runner set up is participant responsibility

```yaml
runs-on: [self-hosted, vmss]
```

---

#### Step2.2: AWS Environment Configuration

Every CD workflow reads its AWS targeting from a single, consistently-named JSON config file. **Update this file with your environment's values before running any pipeline** for that environment/cluster.

```text
dpn-containerised-deployment-service/
└── .github/
    └── config/
        └── aws/
            └── <environment>-<cluster>.json     # dev-dpn01.json, dev-dpn02.json, test-dpn01.json, test-dpn02.json
```

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| AWS_REGION | AWS region the cluster runs in | `eu-west-2` |
| AWS_ACCOUNT_ID | Account ID hosting the infrastructure (the account whose `oidc_github_runner_admin` role is assumed) | `<account-id>` |
| EKS_CLUSTER | Name of the EKS cluster | `eks-dpn-<env>-<nn>-<region>` |
| NAMESPACE | Kubernetes namespace for the deployment | `ns-dpn-01` |
| IMAGE_REGISTRY | Base container registry URL | `ghcr.io/energy-dsi/<version>` (or your own) |
| FILESCAN_SOURCE_BUCKET | S3 bucket scanned by GuardDuty Malware Protection (File Scan Service) | `<source-bucket-name>` |
| FILESCAN_DEST_BUCKET | Destination S3 bucket for scanned files (File Scan Service) | `<destination-bucket-name>` |
| FILESCAN_SNS_TOPIC_NAME | SNS topic GuardDuty publishes scan findings to (File Scan Service) | `<sns-topic-name>` |
| FILESCAN_SQS_QUEUE_NAME | SQS queue subscribed to that SNS topic (File Scan Service) | `<sqs-queue-name>` |
| EFS_FILESYSTEM_ID | ID of the EFS filesystem behind the `efs-sc` StorageClass (printed by `.github/scripts/setup-efs-csi.sh`) | `fs-<id>` |
| OAUTH2_PROXY_EXTERNAL_URL | *(optional)* External URL of the Self-Service Data Pipelines UI, used by `dpn-self-service-cd.yml` | `https://dpn-self-service-external.ns-dpn-dp-01.svc.cluster.local` |

> **Note:** `environment` (`dev`/`test`), `cluster` (`dpn01`/`dpn02`), and `cloud` (`aws`) are supplied as `workflow_dispatch` **inputs** when you trigger a run in the Actions tab — they are **not** keys in the JSON file. The Helm **values file** is derived from those inputs: `<component>/charts/<chart>/values/aws/<environment>-<cluster>.yaml`, inside the central `dpn-containerised-deployment-service` repository (e.g. `dpn-federator-cert-manager/charts/certificate-manager/values/aws/dev-dpn01.yaml`). Each workflow sets this through its `CHART_DIR` / `VALUES_FILE` environment variables.
>

---

#### Step2.3: EKS Namespace Configuration

Create the following Kubernetes namespaces in EKS, along with the shared storage class and image-pull secret every component depends on. This setup needs to be done manually and one time in the Kubernetes cluster — no workflow provisions this cluster bootstrap step:

- ns-dpn-01
- ns-dpn-health-01
- ns-dpn-dp-01 — used by the Self-Service Data Pipelines (`dpn-self-service-cd.yml` fails with `Namespace ns-dpn-dp-01 does not exist` if it is missing)

```bash
kubectl create namespace <NAMESPACE>    # e.g. ns-dpn-01
```

Each component's Helm chart creates its own Kubernetes ServiceAccount (e.g. `dpn-certificate-manager`, `dpn-federator-gateway`, `dpn-rest-federator`, `dpn-file-scan-service`), so no ServiceAccount needs to be created manually.

Most component PVCs use the `gp3` StorageClass. The Certificate Manager's shared file-share PVC uses an EFS-backed `efs-sc` StorageClass, which requires the AWS EFS CSI driver and an EFS filesystem. The central repository provides an idempotent script that provisions the EFS filesystem, the EFS CSI driver's IAM role and the `efs-sc` StorageClass for one cluster. Run it from the administrative instance, authenticated against the target AWS account and with `kubectl` pointed at the target cluster:

```bash
./.github/scripts/setup-efs-csi.sh <cluster-name> <region> <role-name-suffix>
# e.g. ./.github/scripts/setup-efs-csi.sh eks-dpn-dev-02-eu-west-2 eu-west-2 dpn-dev-02
```

Record the filesystem ID it prints as `EFS_FILESYSTEM_ID` in `.github/config/aws/<environment>-<cluster>.json`.

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

kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<GH_USER> \
  --docker-password=<GH_PAT_read:packages> \
  -n ns-dpn-dp-01
```

---

#### Step2.4: GitHub Actions Secrets and Environments

Every CD workflow runs in a **GitHub Environment** named `<environment>-<cluster>` (`environment: ${{ inputs.environment }}-${{ inputs.cluster }}`), so create one Environment per target on the `dpn-containerised-deployment-service` repository — `dev-dpn01`, `dev-dpn02`, `test-dpn01`, `test-dpn02` — and add protection rules (required reviewers) as your organisation requires.

The AWS path uses OIDC, so no AWS access keys are stored in GitHub. The following Actions secrets are required (repository or environment level):

| GitHub Actions Secret | Used by | Purpose |
|-----------------------|---------|---------|
| `DPN_TLS_KEYSTORE_PASSWORD` | `dpn-tls-cd.yaml` | `keystore.jks` password (= `KC_HTTPS_KEY_STORE_PASSWORD` = `UNIVERSAL_DPN_CERT_PASSWORD`) |
| `DPN_TLS_TRUSTSTORE_PASSWORD` | `dpn-tls-cd.yaml`, `dpn-vault-tls-bootstrap-cd.yml`, `dpn-demo-runner-cd.yml` | `truststore.jks` password (= `KC_HTTPS_TRUST_STORE_PASSWORD` = `VAULT_TRUSTSTORE_PASSWORD`) |
| `DPN_TLS_CLIENT_P12_PASSWORD` | `dpn-tls-cd.yaml` | `dsm-client.p12` password |
| `VAULT_KEY` | `dpn-vault-load-bundle-cd.yml` | Contents of `vault.key` (private key for the DSM-signed bundle) |
| `CERTIFICATE_PEM` | `dpn-vault-load-bundle-cd.yml` | Contents of the DSM-signed `certificate.pem` |
| `CA_CHAIN_PEM` | `dpn-vault-load-bundle-cd.yml` | Contents of the DSM `ca-chain.pem` |

```bash
# e.g. set an environment-scoped secret from a file
gh secret set VAULT_KEY --env <environment>-<cluster> < vault.key
```

> **Note:** `workflow_dispatch` has no secret-typed input, so these values are never passed as plain-text workflow inputs — they must be pre-configured as secrets before running the workflows that use them.

---

### Step3: Secrets Configuration

Sensitive credentials must **not be stored in source code repositories**. They must be stored securely in one of the following vaults:

- **HashiCorp Vault** — provided with the DSI DPN package as community edition
- **AWS Secrets Manager** — AWS native secrets store for credentials
- **AWS IAM Roles for Service Accounts (IRSA)** — used where a component needs direct AWS API access (S3, SQS, KMS) without a stored credential

Organisations **must change the default values of secrets** — i.e. sample values such as `changeit`, `admin-password`, `admin-admin`, etc.

Organisations should rotate secrets at defined frequencies.
The secrets are described in the individual component sections of this document that follow.

---

### Step4: Certificate Configuration

During the organisation's onboarding process, an initial certificate package containing the certificate and CA chain files is provided during the bootstrap process from the DSM User Interface. Organisations must securely store these certificates in the vault service. The following certificate artefacts are included in the DPN package:

- The **P12/PFX certificate** issued by the DSI DSM Certificate Authority (keystore)
- The **DSI certificate chain pem file** (truststore)

Refer to the [DPN Federator Certificate Manager](04-configure-dpn-certificate-manager.md) section for detailed instructions on certificate lifecycle management.

The same certificate files are used across all DPN components that require integration with the Data Sharing Mechanism (DSM), specifically the GRPC/REST Federator Gateway and Certificate Lifecycle Manager.

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

> DPN GRPC Federator Gateway uses HTTP/2 traffic over gRPC on port **443**. HTTP/2 traffic requires TCP passthrough to a Layer 4 network load balancer (an AWS NLB); Layer 7 load balancing may not be supported for this traffic for most layer 7 load balancers.

---

### Step6: DPN Internal Domain Naming (DNS) Configuration

Release 2.0.0 introduces a consistent internal domain naming strategy for every DPN user interface, based on **Kubernetes Service DNS** rather than per-UI ingress hostnames or IP addresses. Every browser-facing UI link is configured, from a single place, on the **DPN Unified User Interface (DPN Portal)** service — the `dpn-portal` Helm chart's `tiles[].components[].url` values — which is the source of truth for the table below.

Names follow the standard Kubernetes internal DNS pattern:

```
<service-name>.<namespace>.svc.cluster.local
```

The three EKS namespaces that host DPN UIs are `ns-dpn-01`, `ns-dpn-health-01` and `ns-dpn-dp-01`. The `dpn-common` TLS certificate used across these UIs (generated by `.github/config/scripts/create-dpn-tls.sh`) is issued with three wildcard SANs, `*.ns-dpn-01.svc.cluster.local`, `*.ns-dpn-health-01.svc.cluster.local` and `*.ns-dpn-dp-01.svc.cluster.local`, which is why every UI is reached through one of those domains rather than an IP address or an arbitrary hostname — a wildcard SAN can only match a DNS name, never an `iPAddress` SAN, so browsing by IP always fails certificate validation.

#### DPN component UI DNS reference (configured via the DPN Portal / Unified UI service)

The following internal URLs will be default for accessing the DPN User interfaces. Participants must install the dpn-root certificate generated during the Vault set up process in the respective systems from where DPN portal is accessed. Refer section 3A in [DPN Vault Service](01-configure-dpn-vault-service.md)

These URLs operate on Kuberenetes DNS. To access these URLs, a local host entry needs to be made in the system/Windows VM. The host file is generally present in `C:\Windows\System32\drivers\etc\hosts` location. Open the file in a notepad with admin credential and put the below entries against their load balancer IP. 

```
10.XXX.XXX.XXX dpn-self-service-external.ns-dpn-dp-01.svc.cluster.local
10.XXX.XXX.XXX dpn-kafka-ui-external.ns-dpn-01.svc.cluster.local
10.XXX.XXX.XXX dpn-keycloak.ns-dpn-01.svc.cluster.local
10.XXX.XXX.XXX dpn-federator-gateway-client.ns-dpn-01.svc.cluster.local
10.XXX.XXX.XXX dpn-vault-https-lb.ns-dpn-01.svc.cluster.local
10.XXX.XXX.XXX dpn-observability.ns-dpn-health-01.svc.cluster.local
10.XXX.XXX.XXX dpn-oauth2-proxy-osd.ns-dpn-health-01.svc.cluster.local
10.XXX.XXX.XXX dpn-oauth2-proxy-jaeger.ns-dpn-health-01.svc.cluster.local
10.XXX.XXX.XXX dpn-oauth2-proxy-perses.ns-dpn-health-01.svc.cluster.local
10.XXX.XXX.XXX dpn-kafka-health-ui.ns-dpn-health-01.svc.cluster.local

```


| DPN Portal Tile | Component | DNS Name | Port | Namespace | Access |
|------------------|-----------|----------|------|-----------|--------|
| Users & Roles | Keycloak Console | `dpn-keycloak.ns-dpn-01.svc.cluster.local` (path `/admin/dpn-realm/console/`) | 8443 | ns-dpn-01 | `dpnadmin` only |
| Data / Store | DPN Kafka (Kafka UI) | `dpn-kafka-ui-external.ns-dpn-01.svc.cluster.local` | 8086 | ns-dpn-01 | `dpnadmin`, `dpnreader` — native Keycloak OIDC |
| Gateway | GRPC Gateway Client (Federator Client / Job Runner) | `dpn-federator-gateway-client.ns-dpn-01.svc.cluster.local` | 8085 | ns-dpn-01 | `dpnadmin`, `dpnreader` — plain HTTP (see [Federator Gateway release notes](../../../06-release-notes/release-2.0.0-configuration-changes.md#dpn-federator-gateway)) |
| Data / Pipeline | Data Product Management (Self-Service Data Pipelines UI) | `dpn-self-service-external.ns-dpn-dp-01.svc.cluster.local` | 443 (HTTPS default) | ns-dpn-dp-01 | `dpnadmin`, `dpnreader`, `dpnoperator` — via oauth2-proxy Keycloak SSO |
| Security / Services | Certification Vault Service | `dpn-vault-https-lb.ns-dpn-01.svc.cluster.local` | 8200 | ns-dpn-01 | `dpnadmin`, `dpnreader` |
| Health / Monitoring Service | Log Stack (OpenSearch Dashboards) | `dpn-oauth2-proxy-osd.ns-dpn-health-01.svc.cluster.local` | 5601 | ns-dpn-health-01 | `dpnadmin`, `dpnreader` — via `dpn-oauth2-proxy-osd` Keycloak SSO |
| Health / Monitoring Service | Traces Stack (Jaeger) | `dpn-oauth2-proxy-jaeger.ns-dpn-health-01.svc.cluster.local` | 16686 | ns-dpn-health-01 | `dpnadmin`, `dpnreader` — via `dpn-oauth2-proxy-jaeger` Keycloak SSO |
| Health / Monitoring Service | Metrics Dashboard (Apache Perses) | `dpn-oauth2-proxy-perses.ns-dpn-health-01.svc.cluster.local` | 8083 | ns-dpn-health-01 | `dpnadmin`, `dpnreader` — via `dpn-oauth2-proxy-perses` Keycloak SSO |
| Health / Monitoring Service | Collector Stack (Kafka Health UI) | `dpn-kafka-health-ui.ns-dpn-health-01.svc.cluster.local` | 8082 | ns-dpn-health-01 | `dpnadmin`, `dpnreader` |
| — (the Portal itself) | DPN Portal (Unified UI landing page) | `dpn-observability.ns-dpn-health-01.svc.cluster.local` | 8443 | ns-dpn-health-01 | All authenticated users — via `dpn-oauth2-proxy-portal` Keycloak SSO |

On AWS, the DPN Portal tiles link the OpenSearch, Jaeger and Perses UIs to their own `oauth2-proxy` release Services (`dpn-oauth2-proxy-osd`, `dpn-oauth2-proxy-jaeger`, `dpn-oauth2-proxy-perses`), each on the port its UI already used, so only the scheme changes (`http` → `https`) and the login changes from basic auth to Keycloak SSO. `dpn-observability` (port 8443) is the address configured as the DPN Portal's own `externalUrl` in the `dpn-portal` chart's AWS values files.

#### Using your own DNS instead of the `*.svc.cluster.local` names

Organisations that prefer their own corporate hostnames instead of the Kubernetes-style `*.svc.cluster.local` names above can do so, but this is **not** a DNS-only change — the TLS certificate and every Keycloak client registration are bound to the current names:

1. **Reissue or extend the `dpn-common` TLS certificate** used by the DPN Portal / oauth2-proxy releases so its SAN list covers your chosen hostnames (in addition to, or instead of, the three `*.svc.cluster.local` wildcards). TLS validation matches on the `DNS:` SAN entries only — an IP or an unlisted hostname will fail with `ERR_CERT_COMMON_NAME_INVALID` regardless of whether the CA itself is trusted.
2. **Update `externalUrl` in every affected Helm values file** — the four `oauth2-proxy` releases (`values-portal.yaml`, `values-opensearch.yaml`, `values-jaeger.yaml`, `values-perses.yaml`), the `dpn-portal` chart's own `externalUrl` and `tiles[].components[].url` entries, and `keycloak.publicUrl` — to your new hostnames.
3. **Re-register the new hostnames as Keycloak redirect URIs and Web Origins** on the shared `dpn-service-client` client in the `dpn-realm` realm. Keycloak matches redirect URIs and origins **exactly**; a login attempt against a hostname that isn't registered fails with `invalid_redirect_uri`.
4. **Point your own DNS zone at the same static internal Load Balancer IPs** already provisioned for `dpn-observability` and `dpn-keycloak-service-lb` (or provision your own if you also change the Load Balancer configuration).
5. **Re-run the CD pipelines** for the DPN Portal / Observability UIs and Keycloak (Authentication Service) so the updated values, certificate, and realm configuration are applied together — a partial update (e.g. new DNS record but unregistered redirect URI) will break login for that UI.

---

### Step7: DPN Secrets Reference

This section consolidates secret used across the DPN platform.

#### DPN shared secrets

The following secrets are shared by DPN components to use encryption in transit between component to component communication and also for DPN to DSM mTLS communication for selective components.

In the table below, `<prefix>` is `dpn/<environment>-<cluster>` (e.g. `dpn/dev-dpn01`) — the AWS Secrets Manager naming the workflows and SecretProviderClasses use, one secret per key (`dpn/<environment>-<cluster>/<component>/<KEY>`).

| Kubernetes Secret | Key(s) | Backing AWS Secrets Manager Path | Purpose | Namespace(s) | Consumed by |
|---|---|---|---|---|---|
| `certificate-manager-secrets` | `VAULT_TOKEN`, `VAULT_APPROLE_SECRET_ID` (when `vault.authentication: APPROLE`) | `<prefix>/certificate-manager/VAULT_TOKEN`, `<prefix>/certificate-manager/VAULT_APPROLE_SECRET_ID` (synced by the `dpn-certificate-manager-kv-secrets` SecretProviderClass). The AppRole role ID is stored separately at `<prefix>/certificate-manager/VAULT_APPROLE_ROLE_ID` by `dpn-certificate-manager-role-id-creation.yml` and injected by `dpn-certificate-manager-cd.yml` at deploy time | Vault credentials for PKI bootstrap. The Vault truststore password is no longer synced here — it is read from `tls-auth-secret` (`TRUSTSTORE_PASSWORD`) | ns-dpn-01 | Certificate Manager, Federator Gateway, REST Federator Gateway |
| `dpn-keycloak-secrets` | `KC_SERVICE_CLIENT_SECRET`, `KEYCLOAK_ADMIN_PASSWORD`, `KC_DB_PASSWORD`, `KC_HTTPS_KEY_STORE_PASSWORD`, `KC_HTTPS_TRUST_STORE_PASSWORD` | `<prefix>/keycloak/KC_SERVICE_CLIENT_SECRET` (set manually before first deploy — see note below), `.../KEYCLOAK_ADMIN_PASSWORD`, `.../KC_DB_PASSWORD`, `.../KC_HTTPS_KEY_STORE_PASSWORD`, `.../KC_HTTPS_TRUST_STORE_PASSWORD` | `dpn-service-client` OIDC client secret, Keycloak's own admin/database passwords, and its keystore/truststore passwords | ns-dpn-01 | Authentication Service (Keycloak), Data Pipelines (Kafka OAUTHBEARER), Federator Gateway (Kafka OAUTHBEARER, Kafka UI, Federator Client/Server) |
| `kafka-secrets` | `UNIVERSAL_DPN_CERT_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`, `KC_HTTPS_KEY_STORE_PASSWORD`, `KC_HTTPS_TRUST_STORE_PASSWORD`, `KAFKA_OAUTH_CLIENT_SECRET` | `<prefix>/kafka/UNIVERSAL_DPN_CERT_PASSWORD`, plus its own copies of the Keycloak admin/keystore/truststore passwords and the Kafka OAuth client secret | Kafka broker keystore/truststore password and OAuth client credentials | ns-dpn-01 | Kafka brokers (Federator Gateway's `dpn-platform` chart) |
| `tls-auth-secret` | `KEYSTORE_PASSWORD`, `TRUSTSTORE_PASSWORD`, `DPN_CLIENT_P12_PASSWORD` | n/a — created directly via `kubectl create secret generic`, not sourced from AWS Secrets Manager | Shared passwords for keystore/truststore access and mTLS client cert; written once by `dpn-tls-cd.yaml` into the target namespace, `ns-dpn-health-01` and `ns-dpn-dp-01` (skipped if that namespace does not exist) | ns-dpn-01, ns-dpn-health-01, ns-dpn-dp-01 | Certificate Manager, Federator Gateway (Server/Client, Kafka Source/Target, Kafka UI, Redis), REST Federator Gateway, File Scan Service, Data Pipelines |
| `dpn-tls` | `ca.crt`, `keystore.jks`, `truststore.jks` (files) | n/a — certificate material, not a secrets-manager entry | Universal DPN server TLS identity, written once by `dpn-tls-cd.yaml` (*DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1*) into the target namespace, `ns-dpn-health-01` and `ns-dpn-dp-01` (skipped if absent) | ns-dpn-01, ns-dpn-health-01, ns-dpn-dp-01 | Keycloak, Kafka brokers, Federator Gateway, REST Federator Gateway, File Scan Service, Redis |
| `dpn-health-tls` | `tls.crt`, `tls.key`, `ca.crt` (`kubernetes.io/tls`) | n/a — certificate material, not a secrets-manager entry | Browser-facing HTTPS certificate for the health-monitoring UIs, written once by `dpn-tls-cd.yaml` (when `createHealthTls` is `true`) | ns-dpn-01, ns-dpn-health-01 | Health Monitoring Service (`oauth2-proxy` gateways, Kafka UI TLS) |
| `cert-manager-truststore` | `truststore.jks` (file) | n/a | Trust of the Vault-issued root CA, written once by `dpn-tls-cd.yaml` | ns-dpn-01 | Certificate Manager, Federator Gateway, REST Federator Gateway |
| `fed-gateway-tls` | `tls.crt`, `tls.key` (`kubernetes.io/tls`) | n/a — certificate material, not a secrets-manager entry | Browser-facing HTTPS certificate for the Federator Gateway, written once by `dpn-tls-cd.yaml` | ns-dpn-01 (target namespace) | Federator Gateway |

> **Note on `KC_SERVICE_CLIENT_SECRET`:** unlike the other keys in this table, this value is not auto-generated — it must be created in AWS Secrets Manager at `<prefix>/keycloak/KC_SERVICE_CLIENT_SECRET` before the first Keycloak deploy. The Keycloak CD workflow's realm-configuration step asserts the `dpn-service-client` client's secret matches this stored value on every run, rather than generating a random one, so the client secret never silently drifts.


---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
