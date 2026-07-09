# DPN Deployment Configuration Guide

---

## Table of Contents

- [Overview](#overview)
  - [Continuous Integration (CI)](#continuous-integration-ci)
  - [Continuous Deployment (CD)](#continuous-deployment-cd)

- [Global / Generic Configuration](#global--generic-configuration)
  - [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration)
  - [Azure DevOps Configuration](#azure-devops-configuration)
    - [Node Pool Set Up](#node-pool-set-up)
      - [Existing Configuration](#existing-configuration)
      - [Updated Configuration](#updated-configuration)
    - [Azure Environment Configuration](#azure-environment-configuration)
  - [Secrets Configuration (Global)](#secrets-configuration-global)
    - [Certificate Handling Note](#certificate-handling-note)
  - [Network and Ports Configuration](#network-and-ports-configuration)

- [Component-Specific Configuration](#component-specific-configuration)

  - [DPN Security Services](#dpn-security-services)
    - [HashiCorp Vault Configuration](#hashicorp-vault-configuration)
      - [HTTPS Configuration](#https-configuration)
      - [Vault Helm Configuration For Certificate Manager](#vault-helm-configuration-for-certificate-manager)
      - [Vault Secrets Configuration](#vault-secrets-configuration)

    - [Shared Storage Service Configuration](#shared-storage-service-configuration)
      - [Certificate P12 Storage as File Share](#certificate-p12-storage-as-file-share)
      - [Helm Configuration](#helm-configuration)
      - [Secrets Configuration](#secrets-configuration)

    - [Federator Certificate Manager Configuration](#federator-certificate-manager-configuration)
      - [Helm Configuration](#helm-configuration-1)
      - [Secrets Configuration](#secrets-configuration-1)
        - [Key Vault Secrets Configuration](#key-vault-secrets-configuration)
        - [Kubernetes Secrets Configuration](#kubernetes-secrets-configuration)

  - [DPN Data Pipelines Configuration](#dpn-data-pipelines-configuration)
    - [Introduction and Purpose](#introduction-and-purpose)
    - [Helm Configuration](#helm-configuration-data-pipelines)
      - [Data Pipeline Blueprints](#data-pipeline-blueprints)
      - [Producer Setup](#producer-setup)
      - [Consumer Setup](#consumer-setup)
      - [Producer Parameters — dl, eq, eqbd, and ssh (adaptor & schema_mapper)](#producer-parameters--dl-eq-eqbd-and-ssh-adaptor--schema_mapper)
      - [Consumer Parameters — extractor & schema_mapper](#consumer-parameters--extractor--schema_mapper)
    - [Scheduling Configuration](#scheduling-configuration)
      - [Automated Scheduling](#automated-scheduling)
      - [Manual Scheduling](#manual-scheduling)
      - [Onboarding a New Data Product — Scheduling Setup](#onboarding-a-new-data-product--scheduling-setup)
    - [Secrets Configuration](#secrets-configuration-data-pipelines)

  - [DPN Data Store Configuration](#dpn-data-store-configuration)
    - [Storage Blob / S3 Configuration](#storage-blob--s3-configuration)
    - [DPN Streaming Service (Kafka)](#dpn-streaming-service-kafka)

  - [DPN Federator Gateway Configuration](#dpn-federator-gateway-configuration)
    - [Helm Configuration](#helm-configuration-federator-gateway)
    - [Secrets Configuration](#secrets-configuration-federator-gateway)

- [Review Notes](#review-notes)

---

# Overview

Data Preparation Node (DPN) consists of the following components in the DSI package:

![DPN Architecture Blocks](/Docs/04-dpn-architecture/images/dpn_components.png)

- **DPN Security Service**
  - Vault Service — Certificate regeneration for DSM communication and storage.
  - Digital Certificate Manager — Manages recycling of certificates at a predefined interval from the DSI Management Node.
  - Shared File Service — SMB-based shared file storage between the Federator Certificate Manager and Federator Gateway for storing certificate P12 files.
- **DPN Data Pipelines** — Responsible for producing and consuming data products of an organisation.
- **DPN Data Store Service**
  - Storage — Contains storage accounts or S3 buckets to store files produced by DPN data pipelines, certificate P12 files, and Redis caching data.
  - Streaming Service — DPN uses Kafka as a streaming service for managing events and topics during data transmission.
- **DPN Federator Gateway** — Responsible for DSM and DPN authentication, and data transfer between DPN nodes.

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

## Continuous Integration (CI)

The **Continuous Integration (CI)** pipeline is optional, partipants can either use it to build container components from the provided DPN Source code. Or it can be replaced in full by obtaining pre-build DPN containers directly from the DSI provided **GitHub Container Registry (GHCR)**.

The **Continuous Integration (CI)** pipeline performs the following activities:

1. Build the application source code.
2. Produce container image artefacts.
3. Tag the generated container images.
4. Push the images to a container registry.

DSI recommends using **Azure Container Registry (ACR)** for storing container images in Azure due to its seamless integration with Azure services and built-in security capabilities.

Organisations may use alternative container registries if permitted by their internal network and security policies.

---

## Continuous Deployment (CD)

The **Continuous Deployment (CD)** pipeline deploys the container images to the **Azure Kubernetes Service (AKS)** cluster using Helm.

During deployment, the pipeline performs the following steps:

1. Authenticate with Azure using the configured service connection.
2. Retrieve credentials for the target AKS cluster.
3. Validate Helm charts using `helm lint`.
4. Perform a Helm **dry-run** validation.
5. Deploy the DPN platform using Helm.
6. Verify deployment status using Kubernetes rollout checks.

---

# Global / Generic Configuration

## DSI DSM Endpoint Configuration

DSI provides predefined endpoints to support the following environments:

- Development
- Integration Testing
- Pre-Production
- Production

These endpoints are publicly accessible to simplify integration and testing. Organisations must configure their pipelines to use the **appropriate endpoint for the corresponding deployment environment** as provided by DSI.

| Environment | Component | URL |
|-------------|-----------|-----|
| Pre Production-Dev | Authentication | https://auth-mtls.dsm01.dsipreprod1.neso.energy |
| Pre Production-Dev | Management Node | https://management.dsm01.dsipreprod1.neso.energy |
| Pre Production-Dev | DSI DPN Producer | https://producer.dpn01.dsipreprod1.neso.energy |
| Pre Production-Test | Authentication | https://auth-mtls.dsm01.dsipreprod2.neso.energy |
| Pre Production-Test | Management Node | https://management.dsm01.dsipreprod2.neso.energy |
| Pre Production-Test | DSI DPN Producer | https://producer.dpn01.dsipreprod2.neso.energy |
| Pre-Production-Uat | Authentication | https://auth-mtls.dsm01.dsipreprod3.neso.energy |
| Pre-Production-Uat | Management Node | https://management.dsm01.dsipreprod3.neso.energy |
| Pre-Production-Uat | DSI DPN Producer | https://producer.dpn01.dsipreprod3.neso.energy |

---

## Azure DevOps Configuration

The provided pipelines require the following configuration to perform **CI and CD operations**.

### Node Pool Set Up

The provided pipelines are configured with the default Microsoft-hosted agent pool `ubuntu-latest` for pipeline execution.

However, DSI **recommends using a dedicated self-hosted agent pool**, which provides better control over:

- Security
- Network access
- Deployment environment management

Refer to the official Microsoft documentation for Linux node pool agent setup:
https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent

If a self-hosted agent pool is configured, update the pipeline definition as follows.

#### Existing Configuration

```yaml
pool:
  vmImage: 'ubuntu-latest'
```

#### Updated Configuration

```yaml
pool:
  name: '[agent-pool-name]'
```

---

### Azure Environment Configuration

For the pipelines to run, the following parameters must be updated in the environment-specific JSON configuration file located under the Azure Pipelines folder.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── config/
            ├── dev-dpn01.json
            ├── test-dpn01.json
            ├── preprod-dpn01.json
            └── prd-dpn02.json
```

| Parameter | Description | Example Value |
|-----------|-------------|---------------|
| AZURE_SUBSCRIPTION | Azure subscription ID where the infrastructure is deployed | `<valid Azure subscription ID>` |
| SERVICE_CONNECTION | Azure DevOps service connection name for deployment | `<valid Azure service connection name>` |
| RESOURCE_GROUP | Azure resource group containing the AKS cluster | `rg-prd-uks-dpn-01` |
| AKS_CLUSTER | Name of the Azure Kubernetes Service cluster | `aks-prd-uks-dpn-01` |
| NAMESPACE | Kubernetes namespace for container deployment | `ns-dpn-01` |
| KEY_VAULT_NAME | Azure Key Vault used to store secrets and certificates | `akv-prd-uks-dpn-01` |
| BASE_REGISTRY | Base registry path used by deployment images | `<image-registry-url>` |
| ENV_NAME | Deployment environment abbreviation | `dev` / `sit` / `ppd` / `prd` |
| VALUES_FILE | Helm values file name for use in the pipeline | `values-prd-dpn01.yaml` |

---

## Secrets Configuration (Global)

Sensitive credentials must **not be stored in source code repositories**. They must be stored securely in one of the following vaults:

- **HashiCorp Vault** — provided with the DSI DPN package
- **Azure Key Vault** — cloud-specific option for organisations using Azure

The table below lists all secrets required across the DPN package. Refer to the component-specific secrets configuration sections for details on where each secret must be provisioned.

| Variable | Description |
|----------|-------------|
| CLIENT_P12_PASSWORD | Password for the federator client certificate keystore |
| CLIENT_TRUSTSTORE_PASSWORD | Password for the federator client truststore |
| SERVER_P12_PASSWORD | Password for the federator server certificate keystore |
| SERVER_TRUSTSTORE_PASSWORD | Password for the federator server truststore |
| IDP_CLIENT_SECRET | Client secret used for DSI DSM Identity Provider authentication |
| IDP_KEYSTORE_PASSWORD | Password for the IDP keystore |
| IDP_TRUSTSTORE_PASSWORD | Password for the IDP truststore |
| SRC_CONNECTION_STRING | SAS token for connecting to the source Blob Storage account |
| MAPPER_CONNECTION_STRING | SAS token for connecting to the mapper Blob Storage account |
| TARGET_CONNECTION_STRING | SAS token for connecting to the target Blob Storage account |
| VAULT-TOKEN | Root token of the DPN HashiCorp Vault |
| OAUTH2-CLIENT-SECRET | OAuth2 client secret for the DPN's client ID received from DSI DSM (equivalent to `IDP_CLIENT_SECRET`) |
| AZURE-STORAGE-ACCOUNT-NAME | Storage account name for the Azure File Share used for common DPN certificate storage |
| AZURE-STORAGE-ACCOUNT-KEY | Storage account key for the Azure File Share used for common DPN certificate storage |

---

### Certificate Handling Note

During the organisation's onboarding process, an initial certificate package is provided containing the certificate and CA Chain files. Organisations must securely store these certificates in a vault or equivalent secret store. The following certificate artefacts are included in the DPN package:

- The **P12/PFX certificate** issued by the DSI DSM Certificate Authority (keystore)
- The **DSI certificate chain** (truststore)

Refer to the [Federator Certificate Manager Configuration](#federator-certificate-manager-configuration) section for detailed instructions on certificate lifecycle management.

The same certificate files are used across all DPN components that require integration with the Data Sharing Mechanism (DSM), specifically the Federator Gateway and Certificate Lifecycle Manager.

---

## Network and Ports Configuration

This section describes DPN connectivity requirements for ports and protocols, including agent pool requirements for building DPN code.

![DPN Ports & Protocols](/Docs/04-dpn-architecture/images/DPN_ports_and_protocols.png)

The following firewall rules must be applied by the organisation before installing DPN:

| Source IP Address | Source VNET | Source Subnet | Destination IP / Zone / URL | Destination VNET | Destination Subnet | Protocol | Port(s) | Traffic Flow |
|-------------------|-------------|---------------|-----------------------------|------------------|--------------------|----------|---------|--------------|
| Node pool agent VM IP | Node Pool VM VNET | Node Pool VM subnet | `packages.confluent.io/*` | N/A | N/A | TLS | 443 | Outbound |
| Node pool agent VM IP | Node Pool VM VNET | Node Pool VM subnet | `registry-1.docker.io/*`<br>`auth.docker.io/*`<br>`production.cloudflare.docker.com`<br>`index.docker.io/*` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | `auth-mtls.dsm01.dsi(xxx).neso.energy` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | `management.dsm01.dsi(xxx).neso.energy` | N/A | N/A | TLS | 443 | Outbound |
| DPN Kubernetes subnet IP range | DPN Kubernetes VNET | DPN Kubernetes subnet | Organisation-specific URL for DPN-to-DPN data sharing | N/A | N/A | TLS | 443 | Bi-directional |

> **Note:** The organisation-specific URL in the final row defines the target organisation with which data sharing will occur. These firewall rules must be opened from both organisations' network perspectives. The `dsi(xxx)` notation refers to the `dsidev`, `dsitest`, `dsipre`, and `dsi` (production) environments.

> **Note:** DPN uses HTTP/2 traffic over gRPC on port **443**. HTTP/2 traffic requires TCP passthrough to a Layer 4 load balancer; Layer 7 load balancing is not supported for this traffic.

---

# Component-Specific Configuration

## DPN Security Services

The DPN Security Services consist of the Federator Certificate Manager, HashiCorp Vault, Azure Key Vault, and an SMB-based File Share.

---

### HashiCorp Vault Configuration

HashiCorp Vault is used in the DPN to store the Intermediate CA, CA Chain, and KeyPair files. These files are used to create keystore and truststore files for the Federator Gateway Server and Client to communicate with the DSI Management Node and authentication services.

DSI provides a community edition of the HashiCorp Vault container as part of the DSI package. Organisations may choose to substitute an enterprise edition based on their licensing strategy.

#### HTTPS Configuration

Vault should be set up to use a https based connection internally within DPN application. In this document , stpes are provided to create a Root CA (once) for using a self signed certificate in Vault. However, if organisation already have a CA authority, no need to create a ROOT CA. They should generate a CSR for the Vault URL and jump to step 8 onwards.

organisations would require a server machine that has access to the kubernetes cluster private environment/machine from where Certificate manager and federator containers are accessible and has openssl installed as mentioned in the prerequisite section 01.The output of the following steps would generate truststore ,vault crt and key files which would be mounted on the Certificate manager and federator containers to invoke vault service over https.

##### Step 1: 
Create a vault directory and ca subdirectory in a suitable location on the server machine

```bash
mkdir -p vault
cd vault
mkdir -p ca
cd ca
```

##### Step 2: 
Generate Root CA private key

```bash
openssl genrsa -out rootCA.key 4096
```
##### Step 3: 
Generate Root CA certificate

```bash
openssl req -x509 -new -nodes -key rootCA.key \
  -sha256 -days 3650 \
  -out rootCA.crt \
  -subj "<Your Subject>"
```
After the above steps are completed, the following files will be available in the ca folder.

vault/ca/rootCA.key
vault/ca/rootCA.crt

##### Step 4: 
Switch to Vault directory and create another subdirectory certs. Create a Vault private key in the certs folder.

```bash
cd ..
mkdir -p certs
openssl genrsa -out certs/vault.key 4096
```
##### Step 5: 
Create a config file as vault-openssl.cnf to use for certificate signining request. The SAN should include the internal Kubernetes DNS URL or any defined url by the organisation to access the Vault.

**certs/vault-openssl.cnf**
```text
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
C  = <Your Country>
O  = <Your Org>
CN = <Your CN>

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = vault.<namespace>.svc.cluster.local
DNS.2 = <vault.xyz.com>
DNS.3 = <Other SANs>
```

##### Step 6: 
Create a CSR (Certificate Signing Request) for Vault.

```bash
openssl req -new \
  -key certs/vault.key \
  -out certs/vault.csr \
  -config certs/vault-openssl.cnf
```

##### Step 7: 
Go to vault folder again and run the following command to sign the csr using the root CA created before.

```bash
openssl x509 -req \
  -in certs/vault.csr \
  -CA ca/rootCA.crt \
  -CAkey ca/rootCA.key \
  -CAcreateserial \
  -out certs/vault.crt \
  -days 825 \
  -sha256 \
  -extensions req_ext \
  -extfile certs/vault-openssl.cnf
```
At the end of this step the following files will be ready in the respective folders.

certs/vault.crt → signed by Root CA
<br>certs/vault.key → private key
<br>ca/rootCA.crt → CA trust anchor

##### Step 8: 
Verify the vault.hcl file located in the federator-certificate-manager repository has the above tls configuration for tls_cert_file , tls_key_file and path

```text
Root-Repository/
└── docker/
    └── vault-https/
        └── config/
            ├── vault.hcl
```

**vault.hcl**
```text
  listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_disable   = 0
  tls_cert_file = "/vault/certs/vault.crt"
  tls_key_file  = "/vault/certs/vault.key"
  }

api_addr     = "https://localhost:8200"
cluster_addr = "https://localhost:8201"
ui           = true

storage "file" {
path = "/vault/file"
}
```

##### Step 9: 

Verify the docker-compose.yaml located in the federator-certificate-manager repository has the certificate files from the following location on the Vault container.

```text
Root-Repository/
└── docker/
    └── vault-https/
        ├── docker-compose.yaml
```

Check the docker compose file for the certificate mount path

```yaml
- ./certs:/vault/certs:ro
```

##### Step 11:

Prepare truststore for trusting the Vault HTTPS certificate. **Create a Java truststore using keytool** (PKCS12 format) from the vault directory created above 

```bash
keytool -import -trustcacerts -noprompt -alias ca -file ca/rootCA.crt -keystore truststore.jks -storetype PKCS12
```

This trust store needs to be set up in Federator Gateway and Certificate Manager trustore.jks file in the secret configuration defined in the subsequent step below.
 

#### Vault Helm Configuration For Certificate Manager

The `dpn-federator-certificate-manager` repository includes a Helm chart values file for customising the HashiCorp Vault deployment. The values files are located as follows:

```text
Root-Repository
  └── charts
        └── vault-https
              ├── values.yaml             <- Reference file; do not edit directly
              └── values-<env>-dpn01.yaml <- Environment-specific overrides
```

> **Note:** Replicate `values.yaml` for each environment or DPN deployment (e.g. `values-dev-dpn01.yaml`, `values-sit-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section.

DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

| Parameter                       | Purpose                                   | Example Value                                   |
|---------------------------------|-------------------------------------------|-------------------------------------------------|
| image.repository                | Complete URL of the image registry        | `<DSI public image repository>/hashicorp/vault` |
| image.tag                       | Image version tag                         | `1.16`                                          |
| namespace                       | Name of the Kubernetes namespace          | `ns-dpn-01`                                     |
| replicaCount                    | Number of replicas for the container      | `3`                                             |
| vault.storagePath               | Path inside the persistent storage volume | `/vault/file`                                   |
| seal.azureKeyVault.tenantId     | Unseal Key KeyVault's Tenant Id           | `xxxxx-yyyy`                                    |
| seal.azureKeyVault.clientId     | Unseal Key KeyVault's Client Id           | `xxxxx-yyyy`                                    |                                                 |
| seal.azureKeyVault.keyVaultName | Unseal Key KeyVault's Name                | `kv-dpn-dev-uks-xx`                             |
| seal.azureKeyVault.keyName      | Unseal Key KeyVault's Key name            | `vault-unseal-key`                              |
| keyvault.tenantId               | TLS Cert KeyVault's Tenant Id             | `xxxxx-yyyy`                                    |
| keyvault.clientID               | TLS Cert KeyVault's Client Id             | `xxxxx-yyyy`                                    |
| keyvault.name                   | TLS Cert KeyVault's Name                  | `kv-dpn-dev-uks-xx`                             |

#### Vault Secrets Configuration

The `dpn-federator-certificate-manager` repository includes Helm chart secret and `SecretProviderClass` templates for retrieving and bundling secrets from Azure Key Vault (AKV). The relevant files are located as follows:

```text
Root-Repository
  └── charts
        └── vault-https
              └── templates
                    ├── secret.yaml
                    └── secretproviderclass.yaml
```

HashiCorp Vault must be configured to serve over HTTPS with a minimum of TLS 1.2. The following AKV secrets must be created under `<keyvault.name>` to provide the TLS certificate material:

| Secret           | Purpose                                                                                |
|------------------|----------------------------------------------------------------------------------------|
| `VAULT-TLS-CERT` | AKV secret containing the TLS certificate **vault.crt** file  |
| `VAULT-TLS-KEY`  | AKV secret containing the TLS key **vault.key** |

---

### Shared Storage Service Configuration

The keystore and truststore P12 certificate files used by the Federator Gateway Server and Client are stored in a common SMB-based file share (Azure File Share). This file share is mounted by both the Federator Certificate Manager and the Federator Gateway components, as all three require access to the same certificate material when communicating with the DSI DSM Management Node and authentication endpoints.

#### Certificate P12 Storage as File Share

The Federator Certificate Manager, Federator Gateway Server, and Federator Gateway Client all require the certificate P12 files and their passwords to be accessible from a common mount point (e.g. `/tls`) on the file share.These files are dynamically created when certificate manager renews or fetch certificate from DSI.These files are mounted in read only mode for the federator.

```text
/file-share-mount-path
└── tls
    ├── keystore.p12
    ├── truststore.p12
    ├── keystore.password
    └── truststore.password
```

#### Helm Configuration

The `dpn-federator-certificate-manager` repository includes a Helm chart values file and a PV/PVC manifest for customising the File Share deployment. The values files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              ├── values.yaml             <- Reference file; do not edit directly
              ├── values-<env>-dpn01.yaml <- Environment-specific overrides
              └── templates
                    └── pv-pvc.yaml
```

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| fileShare.shareName | SMB File Share name used for common DPN certificate storage | `fs<env>dpn01<region>01` |
| fileShare.secretName | Kubernetes secret name containing the File Share credentials | `azure-fileshare-secret` |
| fileShare.namespace | Kubernetes namespace for the File Share | `ns-dpn-01` |
| fileShare.pvName | Persistent Volume name for the File Share | `pv-dpn-certs-fileshare` |
| fileShare.pvcName | Persistent Volume Claim name for the File Share | `pvc-dpn-certs-fileshare` |
| fileShare.size | Capacity to allocate for the File Share | `1Gi` |

#### Secrets Configuration

The `dpn-federator-certificate-manager` repository includes Helm chart secret and `SecretProviderClass` templates for retrieving and bundling secrets from Azure Key Vault. The relevant files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              └── templates
                    ├── secret.yaml
                    └── secretproviderclass.yaml
```

| Secret Parameter | Purpose | Example Value             |
|------------------|---------|---------------------------|
| `azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-NAME` | Storage account name for the Azure File Share used for common DPN certificate storage | `st<env>>dpn01<region>01` |
| `azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-KEY` | Storage account key for the Azure File Share used for common DPN certificate storage | `XXXXXXXXXXXXXXXX`        |

---

### Federator Certificate Manager Configuration

The Federator Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for Federator components within the **DSI DPN**. It operates as a headless daemon — no HTTP endpoints are exposed — running two scheduled jobs that handle certificate renewal and filesystem synchronisation.

The service integrates with **HashiCorp Vault** (KV v2) for secret persistence, an external **Management Node** API for PKI operations (intermediate CA retrieval and CSR signing), and an **OAuth2 Identity Provider** for token-based authentication. All external HTTP communication is secured via mutual TLS (mTLS).

#### Helm Configuration

The `dpn-federator-certificate-manager` repository includes a Helm chart values file for customising the deployment. The values files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              ├── values.yaml             <- Reference file; do not edit directly
              └── values-<env>-dpn01.yaml <- Environment-specific overrides
```

> **Note:** Replicate `values.yaml` for each environment or DPN deployment (e.g. `values-dev-dpn01.yaml`, `values-test-dpn01.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section.

DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

| Parameter              | Purpose                                                                      | Example Value                                                                                     |
|------------------------|------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| image.repository       | Complete URL of the image in the registry                                    | `<DSI public image repository>/dpn-federator-certificate-manager`                                 |
| namespace              | Name of the Kubernetes namespace                                             | `ns-dpn-01`                                                                                       |
| managementNode.baseUrl | Complete URL of the DSI DSM Management Node                                  | `https://management.dsm01.dsiXXX.neso.energy`                                                     |
| oauth2.clientId        | Client ID received from DSM to establish the DPN connection                  | `9c4f2e8a-6b21-4d73-9a5e-1f6b8c7a4d92`                                                            |
| oauth2.tokenUri        | IDP token URL received from DSM to establish the DPN connection              | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| replicaCount           | Number of replicas for the container                                         | `1`                                                                                               |
| vault.uri              | Complete URL of the DPN Vault                                                | `https://vault.<namespace>.svc.cluster.local:8200`                                                |
| vault.truststorePath   | Absolute Path of the folder under which vault truststore.jks will be mounted | `/vault`                                                                                           |
| existingSecret.name    | Secret bundle name for the Federator Certificate Manager secrets             | `certificate-manager-secrets`                                                                     |
| fileShare.shareName    | File Share name for common DPN certificate storage                           | `fs<env>dpn01<region>01`                                                                          |
| fileShare.secretName   | Secret bundle name for the Azure File Share credentials                      | `azure-fileshare-secret`                                                                          |
| fileShare.namespace    | Kubernetes namespace for the File Share                                      | `ns-dpn-01`                                                                                       |

#### Secrets Configuration

The `dpn-federator-certificate-manager` repository includes Helm chart secret and `SecretProviderClass` templates for retrieving and bundling secrets from Azure Key Vault. 

The relevant files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              └── templates
                    ├── secret.yaml
                    └── secretproviderclass.yaml
```

##### Key Vault Secrets Configuration

| Secret Parameter                                        | Purpose                                                                               | Example Value            |
|---------------------------------------------------------|---------------------------------------------------------------------------------------|--------------------------|
| `certificate-manager-secrets.VAULT-TOKEN`               | Root token of the DPN HashiCorp Vault                                                 | `hsv.xxxxxxxxxxx`        |
| `certificate-manager-secrets.OAUTH2-CLIENT-SECRET`      | OAuth2 client secret for the DPN's client ID received from DSI DSM                    | `xxxxxxxxxxx`            |
| `certificate-manager-secrets.VAULT-TRUSTSTORE-PASSWORD` | DPN Hashicorp Vault Truststore password                                               | `changeit`               |
| `azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-NAME`     | Storage account name for the Azure File Share used for common DPN certificate storage | `fs<env>dpn01<region>01` |
| `azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-KEY`      | Storage account key for the Azure File Share used for common DPN certificate storage  | `xxxxxxxxxxx`            |

##### Kubernetes Secrets Configuration

Below Kubernetes secret must be created to load the Vault `truststore.jks` file created using steps [here](#https-configuration) under path `<vault.truststorePath>`.

| Secret Parameter       | Purpose                                                     | Example Value |
|------------------------|-------------------------------------------------------------|---------------|
| `VAULT-TRUSTSTORE-JKS` | Secret container for DPN Vault's Truststore.jks binary file | ` `           |

---

## DPN Data Pipelines Configuration

### Introduction and Purpose

The DPN Data Pipeline ensures secure and governed data exchange by validating and transforming datasets before and after transmission. It applies schema assurance, security labelling, and controlled processing across producer and consumer stages. This ensures all shared data conforms to required schemas, security classifications, and governance standards, enabling reliable and compliant data sharing.

### Helm Configuration

The Helm configuration for the DPN deployment is segregated between the Producer and Consumer domains.

- On the producer side, Helm values are defined for each schema type to configure the Adaptor and Schema Mapper, ensuring source-specific validation, governance, and transmission rules.
- On the consumer side, separate Helm values files are used for the Extractor and Schema Mapper to validate and deliver data according to target requirements.

This separation ensures that each pipeline stage operates with file-type-specific schemas and policies while maintaining clear isolation between producer and consumer configurations.


#### Data Pipeline Blueprints

DSI provided following schema types belonging to energy industry. organisations are supposed to verify and augment any new schema type following the DSM data template definition and bring their own adaptor and mapper components accordingly. 

| Schema | Description |
|------|-------------|
| DL | Diagram Layout |
| EQ | Equipment |
| EQBD | Equipment Boundary |
| SSH | Steady State Hypothesis |

DSI provides the above schema-type blueprints from which organisations prepare their data products. The `values.yaml` files within the blueprints directory must **not** be modified directly. The blueprints folder is organised by integration pathway (e.g. `file`, `topic`, `api`) and by schema type within each pathway.

```text
Root-Repository
  └── blueprints
        └── consumer
              └── file
                    ├── extractor
                    │     └── charts
                    │           └── values.yaml
                    └── schema_mapper
                          └── charts
                                └── values.yaml
        └── producer
              └── file
                    ├── dl
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    ├── eq
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    ├── eqbd
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    └── ssh
                          ├── adaptor
                          │     └── charts
                          │           └── values.yaml
                          └── schema_mapper
                                └── charts
                                      └── values.yaml
```

#### Producer Setup

The following steps are required when an organisation produces a data product:

1. Define the **`product_type`** name — the identifier for the data product being published. Each product type must conform to one of the schema types available in the blueprints.
2. Copy the relevant schema folder (e.g. `eq`, `eqbd`, `dl`, or `ssh`) from `Root-Repository/blueprints/producer/file/{schema_type}` to `Root-Repository/producer/file/{schema_type}`.
3. Rename the copied `{schema_type}` folder to `{product_type}` (e.g. rename `eq` to `eq-dp-01`). Only hyphens are permitted as special characters; all other special characters are disallowed.
4. Ensure the `product_type` value is passed consistently during the CI pipeline run.

```text
Root-Repository
  └── producer
        └── file
              └── {product_type}   <- e.g. eq-sample-1
                    ├── adaptor
                    │     └── charts
                    │           └── values.yaml
                    └── schema_mapper
                          └── charts
                                └── values.yaml
```

#### Consumer Setup

The following step is required when an organisation is consuming data products:

1. Copy the consumer folder from `Root-Repository/blueprints/consumer` to `Root-Repository/consumer` as-is, without modification.

```text
Root-Repository
  └── consumer
        └── file
              ├── extractor
              │     └── charts
              │           └── values.yaml
              └── schema_mapper
                    └── charts
                          └── values.yaml
```

> **Note:** The `values.yaml` file can be replicated for multiple environments or DPN deployments (e.g. `values-<env>-dpn01.yaml`, `values-<env>-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section.

DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

> **Naming conventions to observe:**
> - Storage container names, Kafka topic names, and product type names must use only alphanumeric characters and hyphens (`-`). No other special characters are permitted.
> - Organisation names must be abbreviated without spaces.
> - Schema type must match the blueprint schema type exactly: `eq`, `eqbd`, `dl`, or `ssh`.

#### Producer Parameters — dl, eq, eqbd, and ssh (adaptor & schema_mapper)

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| imageName | Image name in the DSI registry | `{image name of adaptor or schema_mapper}` |
| productType | Product type name — alphanumeric and hyphens only | `eq-sample-1` |
| srcContainerName | Source storage container name | `eq-sample-1-stage` |
| mapperTopicName | Kafka topic name for the mapper stage | `dpn-producer-eq-sample-1-raw` |
| mapperContainerName | Storage container name for the mapper stage | `eq-sample-1-raw` |
| targetTopicName | Kafka topic name for the target stage | `dpn-producer-eq-sample-1-target` |
| targetContainerName | Storage container name for the target stage | `eq-sample-1-target` |
| orgName | Organisation name abbreviation (no spaces) | `orga` |
| schemaType | Schema type | `eq` / `eqbd` / `dl` / `ssh` |

#### Consumer Parameters — extractor & schema_mapper

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| imageName | Image name in the DSI registry | `{image name of extractor or consumer_mapper}` |
| srcContainerName | Source storage container name | `dp-consumer-stage` |
| mapperTopicName | Kafka topic name for the mapper stage | `dpn-consumer-trfm` |
| mapperContainerName | Storage container name for the mapper stage | `dp-consumer-trfm` |
| targetTopicName | Kafka topic name for the target stage | `dpn-consumer-target` |
| targetContainerName | Storage container name for the target stage | `dp-consumer-target` |

### Scheduling Configuration

Each data pipeline stage (adaptor, schema mapper, extractor) is triggered in one of two ways: **Automated Scheduling** or **Manual Scheduling**. Which one applies is controlled by the `SCHEDULER_BACKEND` parameter in that stage's `values.yaml`.

#### Automated Scheduling

Under automated scheduling, the pipeline stage is started by a software trigger rather than by an operator. The trigger mechanism is a pair of shared Kafka topics:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Set to `kafka-trigger` to enable software-triggered scheduling | `kafka-trigger` |
| PIPELINE_CONTROL_TOPIC | Kafka topic the pipeline stage listens on for a start signal | `dpn-pipeline-control` |
| PIPELINE_STATUS_TOPIC | Kafka topic the pipeline stage publishes run status/progress to | `dpn-pipeline-status` |
| EXECUTION_MODE | `automatic` — the stage self-schedules on `scheduleInterval` — or `manual` — the stage only runs when a message arrives on `PIPELINE_CONTROL_TOPIC` | `automatic` / `manual` |
| scheduleInterval | Polling interval in seconds. Only used when `EXECUTION_MODE: automatic` | `60` |

A message published to `PIPELINE_CONTROL_TOPIC` starts a run; the pipeline stage reports progress back on `PIPELINE_STATUS_TOPIC`. No operator action is required once this is configured — this is why it's referred to as automated.

> **Placeholder:** <Hari's input>

#### Manual Scheduling

Manual scheduling uses an orchestrator (Airflow) to start pipeline runs on a fixed schedule or on operator demand, instead of relying on the Kafka control-topic signal above.

```text
Root-Repository
  └── charts
        └── airflow/
              ├── values-<env>-dpn01.yaml   <- Environment-specific Airflow overrides
              └── dags/
                    └── {product_type}.py   <- One DAG per data product
```

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Set to `airflow` to hand scheduling control to Airflow instead of the Kafka control topic | `airflow` |

#### Onboarding a New Data Product — Scheduling Setup

Scheduling configuration is **not created automatically** — it must be set up alongside every new data product, in addition to the steps in [Producer Setup](#producer-setup):

1. Locate the sample/existing DAG closest to your new product's schema type under `charts/airflow/dags/` (this is the same sample-doc-style copy pattern used for Helm values in Producer Setup).
2. Copy that DAG file and rename it to match the new `product_type` (e.g. copying the sample `eq` DAG to create the DAG for a new product `xyz-sample-1`).
3. Update the copied DAG's references (topic names, container names, `product_type`) so they match the values used in that product's `values.yaml`.
4. Set `SCHEDULER_BACKEND` on the product's `values.yaml` to match the chosen approach — `kafka-trigger` for automated scheduling, or `airflow` for manual scheduling.

> **Placeholder:**  <Hari's input>

### Secrets Configuration

DSI Data Pipeline uses Kubernetes secrets by design, as this is a Bring-Your-Own (BYO) component. Two secret objects are created — one for Producer and one for Consumer.

> - Producer secret name: `producer-<processType>-dp-secret`
> - Consumer secret name: `consumer-<processType>-dp-secret`
> - `<processType>` is `file` for the file-based pathway in MVP. Future values may include `rest`, `topic`, etc.

**Producer Secrets**

The producer secrets contain the storage account connection strings and SAS tokens for each stage. The connection string format is:

```text
https://<storage-account>.blob.core.windows.net/?<sas-token>
```

The secret object `producer-<processType>-dp-secret` contains the following. If the same storage account is used for all stages, the same connection string value may be used for all three:

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Blob Storage connection string for the source storage account |
| MAPPER_CONNECTION_STRING | Blob Storage connection string for the mapper storage account |
| TARGET_CONNECTION_STRING | Blob Storage connection string for the target storage account |

Create the producer secret using the following command:

```bash
kubectl create secret generic producer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=MAPPER_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob mapper connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```

**Consumer Secrets**

The secret object `consumer-<processType>-dp-secret` contains the following. If the same storage account is used for all stages, the same connection string value may be used for all three:

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Blob Storage connection string for the consumer source storage account |
| MAPPER_CONNECTION_STRING | Blob Storage connection string for the consumer mapper storage account |
| TARGET_CONNECTION_STRING | Blob Storage connection string for the consumer target storage account |

Create the consumer secret using the following command:

```bash
kubectl create secret generic consumer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=MAPPER_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob mapper connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```


---

## DPN Data Store Configuration

The DPN Data Store consists of two sub-components:

- **Storage Blob / S3** — File storage for pipeline artefacts
- **Kafka Streaming Service** — Event streaming between DPN components

### Storage Blob / S3 Configuration

Storage Blob / S3 is the integration layer between the organisation's internal data source, the Federator Gateway, Data Pipelines, and the data destination.

The file-based integration pathway requires a set of storage containers (buckets) to be defined upfront, based on the data product template in use. The following naming convention is recommended when provisioning containers:

| Process | Source Container Name | Target Container Name |
|---------|-----------------------|-----------------------|
| adaptor | `{product_type}-stage` | `{product_type}-raw` |
| producer-mapper | `{product_type}-raw` | `{product_type}-target` |
| extractor | `dp-consumer-stage` | `dp-consumer-trfm` |
| consumer-mapper | `dp-consumer-trfm` | `dp-consumer-target` |

```text
Example container names (product_type = eq-sample-1):

  eq-sample-1-stage
  eq-sample-1-raw
  eq-sample-1-target
  dp-consumer-stage
  dp-consumer-trfm
  dp-consumer-target
```

> **Note:** Each storage container is mapped to a single data product type on the producer side. One data product type carries a single version of the file at any given time (e.g. the `eq-sample-1-raw` container contains `sample_1_v1.xml` only, until a version revision changes it to `sample_1_v2.xml`).

> **Note:** Storage containers are accessed asynchronously by the Federator Gateway and the organisation's data source and destination to pick up and deposit files.

---

### DPN Streaming Service (Kafka)

The DPN Streaming Service uses Kafka to emit events between DPN components, including the Data Pipeline adaptor, mapper, extractor, Federator Gateway, and organisation data source/destination endpoints.

The DPN data pipeline processes files by pushing streaming messages onto predefined Kafka topics. The proposed topic names are listed below. Organisations may customise the naming convention if required, but any topic name changes must be reflected in the CD pipeline configuration.

| Process | Source Topic Name | Target Topic Name | Bootstrap Server |
|---------|-------------------|-------------------|------------------|
| adaptor | N/A | `dpn-producer-{product_type}-raw` | `dpn-kafka-src:9092` |
| producer-mapper | `dpn-producer-{product_type}-raw` | `dpn-producer-{product_type}-target` | `dpn-kafka-src:9092` |
| extractor | N/A | `dpn-consumer-trfm` | `dpn-kafka-target:9092` |
| consumer-mapper | `dpn-consumer-trfm` | `dpn-consumer-target` | `dpn-kafka-target:9092` |

where **`product_type`** is a value such as `eq-sample-1` as described in previous sections.

These topics must be pre-created via the Kafka UI before the `dpn-data-pipeline` CI and CD tasks are executed.

The Kafka message structure used by the DSI Data Pipeline follows the convention below. This enables the Federator Server to locate and retrieve the file from the specified storage location during file transfer:

```json
{
  "sourceType": "{cloud type}",
  "storageContainer": "{name of the storage container where the file is placed}",
  "path": "folder-name/file-name"
}
```

Example:

```json
{
  "sourceType": "AZURE",
  "storageContainer": "eq-sample-1-target",
  "path": "eq-orga-sample_v1.xml"
}
```

> **Note:** Valid values for `sourceType` are `AZURE`, `GCP`, and `S3`. 

---

## DPN Federator Gateway Configuration

The DPN Federator Gateway handles all secure communication between your DPN node and other DPN nodes or the DSI DSM platform. It ensures data is sent and received safely, only to and from trusted parties.

The gateway does not operate in isolation. It depends on a set of supporting services that are all deployed together in a single Helm release into the same Kubernetes cluster:

| Component | Purpose |
|-----------|---------|
| Zookeeper Source | Coordination service for the Source Kafka cluster. Must be running before Kafka Source starts. |
| Zookeeper Target | Coordination service for the Target Kafka cluster. Must be running before Kafka Target starts. |
| Kafka Source | Message queue where the DPN's outgoing data is staged. The Federator Server reads from here to send data out. |
| Kafka Target | Message queue where incoming data from other DPNs is delivered. The Federator Client writes received data here. |
| Kafka UI | Web dashboard to monitor and inspect messages in both Kafka clusters. Useful during testing. |
| Redis | Fast in-memory store used by both the Federator Server and Client for caching and tracking data offsets. |
| Federator Server | Listens on port 443 for incoming data connections from other DPN nodes; reads from Kafka Source. |
| Federator Client | Connects outward to a remote Federator Server; writes received data into Kafka Target. |

All components are deployed together in a single pipeline run using one Helm release (`dpn-platform`).

### Helm Configuration {#helm-configuration-federator-gateway}

The `dpn-federator-gateway` repository includes a Helm chart values file for customising the deployment. The values files are located as follows:

```text
Root-Repository
  └── charts
        └── dpn-platform/
              ├── values.yaml              <- Default settings for all components; do not edit directly
              └── values-<env>-dpn01.yaml  <- Environment-specific overrides for all components
```

> **Note:** Replicate `values.yaml` for each environment or DPN deployment (e.g. `values-dev-dpn01.yaml`, `values-sit-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section.

> **Note:** Only a single pipeline run is required. It applies the environment-specific values file on top of `values.yaml` and deploys all components in a single Helm release named `dpn-platform`.

> **Note:** DSI proposes only the minimum required changes listed below. Additional parameters may be customised if needed.

Open `values-<env>-dpn01.yaml` and update the following parameters as a minimum:

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| redis.image.repository | Container registry address for the Redis image | `<DSI public image registry>/redis` |
| redis.image.tag | Redis image tag | `7.2` |
| zookeeper.image.repository | Container registry address for the Zookeeper image | `<DSI public image registry>/cp-zookeeper` |
| zookeeper.image.tag | Zookeeper image tag | `7.5.3` |
| kafka.image.repository | Container registry address for the Kafka image | `<DSI public image registry>/cp-kafka` |
| kafka.image.tag | Kafka image tag | `7.5.3` |
| kafkaUI.image.repository | Container registry address for the Kafka UI image | `<DSI public image registry>/kafka-ui` |
| federatorServer.image.repository | Container registry address for the Federator Server image | `<DSI public image registry>/dpn-federator-server` |
| federatorServer.image.tag | Federator Server image tag | `<latest published version>` |
| federatorServer.service.loadBalancerIP | Fixed internal IP for the Federator Server. Obtain from the Kubernetes service external IP after first deployment. | `<fixed private load balancer IP>` |
| federatorServer.config.management_node_base_url | DSI DSM Management Node URL for your environment | `https://management.dsm01.dsiXXX.neso.energy` |
| federatorServer.idp.clientId | Client ID provided by DSI to identify this DPN node | `7af382c4-1759-4938-b596-c4c5c572304e` |
| federatorServer.idp.jwksUrl | JWKS endpoint for verifying identity tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/certs` |
| federatorServer.idp.tokenUrl | Token endpoint for requesting access tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| federatorClient.image.repository | Container registry address for the Federator Client image | `<DSI public image registry>/dpn-federator-client` |
| federatorClient.image.tag | Federator Client image tag | `<latest published version>` |
| federatorClient.service.loadBalancerIP | Fixed internal IP for the Federator Client. Obtain from the Kubernetes service external IP after first deployment. | `<fixed private load balancer IP>` |
| federatorClient.config.management_node_base_url | DSI DSM Management Node URL for your environment | `https://management.dsm01.dsiXXX.neso.energy` |
| federatorClient.idp.clientId | Client ID provided by DSI to identify this DPN node | `9c4f2e8a-6b21-4d73-9a5e-1f6b8c7a4d92` |
| federatorClient.idp.jwksUrl | JWKS endpoint for verifying identity tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/certs` |
| federatorClient.idp.tokenUrl | Token endpoint for requesting access tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |

**Shared Key Vault Parameters**

DPN Federator uses Azure Key Vault to store secrets for both the Federator Server and Client. Organisations may alternatively use Kubernetes secrets or another approved secret store.

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| keyvault.name | Azure Key Vault name where all secrets are stored | `kv-dpn-<env>-<region>-<seq>` |
| keyvault.clientID | Managed Identity client ID that allows the cluster to read from Key Vault | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| keyvault.tenantId | Organisation's Azure Active Directory tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |

### Secrets Configuration

Secrets must never be written into the values file or the code repository. Organisations must store secrets securely using HashiCorp Vault, Azure Key Vault, or another approved secret management solution, and ensure they are injected automatically when pods start up.

DSI provides a reference implementation using Azure Key Vault. The secret templates are located in the `dpn-federator-gateway` repository as follows:

```text
dpn-federator-gateway/
└── charts/
      └── dpn-platform/
            └── templates/
                  ├── federator-server-secretproviderclass.yaml
                  ├── federator-client-secretproviderclass.yaml
                  └── federator-idp-secretproviderclass.yaml
```

**Federator Server Secrets** (provision in: Azure Key Vault)

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| SERVER-P12-PASSWORD | Password for the server's certificate keystore, used to prove the server's identity to connecting clients | `changeit` |
| SERVER-TRUSTSTORE-PASSWORD | Password for the server's truststore, used to verify the identity of connecting clients | `changeit` |

**Federator Client Secrets** (provision in: Azure Key Vault)

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| CLIENT-P12-PASSWORD | Password for the client's certificate keystore, used to prove the client's identity when connecting to the Federator Server | `changeit` |
| CLIENT-TRUSTSTORE-PASSWORD | Password for the client's truststore, used to verify it is connecting to the correct server | `changeit` |

**Federator IDP Secrets** (provision in: Azure Key Vault)

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| IDP-KEYSTORE-PASSWORD | Password for the IDP keystore certificate file, used to prove the client's identity when connecting to the IDP service | `changeit` |
| IDP-TRUSTSTORE-PASSWORD | Password for the IDP truststore, used to verify connection to the correct IDP server | `changeit` |
| IDP-CLIENT-SECRET | Secret used to authenticate the Federator Client to the DSI authentication service; provided as part of the DSI package | `xxxxxxxx` |

---

# Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
