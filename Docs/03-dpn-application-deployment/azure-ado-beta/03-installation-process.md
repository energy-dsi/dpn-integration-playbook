# DPN Installation Process

---

# Table of Contents

- [Overview](#overview)
- [DPN Containerized Deployment Architecture](#dpn-containerized-deployment-architecture)
- [Installation Prerequisites](#installation-prerequisites)
  - [1. Clone and Prepare Source Repositories](#1-clone-and-prepare-source-repositories)
  - [2. Prepare Infrastructure and Application Prerequisites](#2-prepare-infrastructure-and-application-prerequisites)
  - [3. Certificate Preparation and CSR Generation](#3-certificate-preparation-and-csr-generation)
  - [4. Identify Pipeline Repository Structure](#4-identify-pipeline-repository-structure)
- [Installation Steps](#installation-steps)
  - [Part 1 — Hashicorp Vault Deployment](#part-1--hashicorp-vault-deployment)
    - [Hashicorp Vault Configuration](#hashicorp-vault-configuration)
    - [Certificate Load Steps in Vault](#certificate-load-steps-in-vault)
  - [Part 2 — DPN Certificate Life Cycle Manager Installation](#part-2--dpn-certificate-life-cycle-manager-installation)
    - [Step 1 — Prepare Federator Certificate Manager CI Pipeline](#step-1--prepare-federator-certificate-manager-ci-pipeline)
    - [Step 2 — Execute Federator Certificate Manager CI Pipeline](#step-2--execute-federator-certificate-manager-ci-pipeline)
    - [Step 3 — Verify Federator Certificate Manager CI Pipeline](#step-3--verify-federator-certificate-manager-ci-pipeline)
    - [Step 4 — Prepare Federator Certificate Manager CD Pipeline](#step-4--prepare-federator-certificate-manager-cd-pipeline)
    - [Step 5 — Execute Federator Certificate Manager CD Pipeline](#step-5--execute-federator-certificate-manager-cd-pipeline)
    - [Step 6 — Verify Federator Certificate Manager CD Pipeline](#step-6--verify-federator-certificate-manager-cd-pipeline)
  - [Part 3 — DPN Data Pipeline Installation](#part-3--dpn-data-pipeline-installation)
    - [Step 1 — Configure Data Pipeline CI Pipeline](#step-1--configure-data-pipeline-ci-pipeline)
    - [Step 2 — Execute Data Pipeline CI Pipeline](#step-2--execute-data-pipeline-ci-pipeline)
    - [Step 3 — Validate Data Pipeline CI Pipeline](#step-3--validate-data-pipeline-ci-pipeline)
    - [Step 4 — Configure Data Pipeline CD Pipeline](#step-4--configure-data-pipeline-cd-pipeline)
    - [Step 5 — Execute Data Pipeline CD Pipeline](#step-5--execute-data-pipeline-cd-pipeline)
    - [Step 6 — Verify Data Pipeline CD Pipeline](#step-6--verify-data-pipeline-cd-pipeline)
  - [Part 4 — DPN Federator Gateway Installation](#part-4--dpn-federator-gateway-installation)
    - [Pipeline Variable Groups](#pipeline-variable-groups)
    - [Step 1 — Configure Maven Settings](#step-1--configure-maven-settings)
    - [Step 2 — Configure Federator CI Pipeline](#step-2--configure-federator-ci-pipeline)
    - [Step 3 — Execute Federator CI Pipeline](#step-3--execute-federator-ci-pipeline)
    - [Step 4 — Configure Federator CD Pipeline](#step-4--configure-federator-cd-pipeline)
    - [Step 5 — Execute Federator CD Pipeline](#step-5--execute-federator-cd-pipeline)
    - [Post Deployment Verification](#post-deployment-verification)
    - [Kafka UI Verification](#kafka-ui-verification)
- [Troubleshooting](#troubleshooting)

---

## Overview

This document provides step-by-step instructions for installing and deploying **DPN components** using **Azure DevOps (ADO) pipelines**.

The deployment uses the following repositories:

- https://github.com/energy-dsi/dpn-federator.git
- https://github.com/energy-dsi/dpn-federator-certificate-manager.git
- https://github.com/energy-dsi/dpn-data-pipelines.git

The deployment process consists of:

- **Continuous Integration (CI)** — builds container images
- **Continuous Deployment (CD)** — deploys images into **Azure Kubernetes Service (AKS)**

The following flow diagram explains the installation process steps.

![DPN Components](/Docs/04-dpn-architecture/images/TBD.png)

---

## DPN Containerized Deployment Architecture

The following diagram illustrates the reference DPN deployment architecture for the **DPN Data Exchange platform**. It consists of the following containerised components:

![DPN Architecture Blocks](/Docs/04-dpn-architecture/images/dpn_deployment_architecture.png)

**DPN Federator Gateway**
This component is responsible for file transmission over a gRPC connection, communication with the DSM Keycloak service, and management node services.

**DPN Federator Gateway — Server Mode**
- Receives Federator Client requests
- Authenticates with the DSM service
- Receives producer and consumer configuration from the management node
- Connects to the Kafka topic based on the client request for a data product
- Initiates a gRPC-based file streaming service with the Federator Client

**DPN Federator Gateway — Client Mode**
- Initiates a Federator Server request based on a scheduled job
- Authenticates with the DSM service
- Receives producer and consumer configuration from the management node
- Initiates a gRPC-based file streaming service with the Federator Server
- Places the file in the storage container

**DPN Certificate Manager**
This component is responsible for issuing bootstrap certificates to initiate a connection with the management node. It renews certificates with the management node and stores them in P12 storage. The Federator Server and Client use this location to reference the certificate files for initiating mutual TLS with DSM and other DPNs.

**DPN Shared Storage**
This is a file share component shared between the Federator Certificate Manager and the Federator Gateway, enabling use of the same keystore and truststore P12 certificate generated by DPN Vault after the Vault is configured with the certificate, CA chain, and private and public key files.

**DPN Data Pipeline Producer**
- Files are extracted from the organisation's source storage location automatically on a scheduled basis
- Processed by adaptor and mapper components
- Published to Kafka topics with the final file location
- Published to the target storage location

**DPN Data Pipeline Consumer**
- Federator Client receives the file in a consumer-specific storage account or bucket
- Checksum and hash validation are performed on the received file(s)
- The file is processed by the extractor service and placed into another target container
- Mapper components perform schema validation based on the schema type specified in the file name
- The processed file is stored in the consumer target storage container or bucket
- A Kafka-based streaming message is sent to a destination Kafka topic to mark the end of the data pipeline process

**DPN Streaming Service — Kafka**
This component is responsible for event emission and storing the locations of data product files produced by the Data Pipeline Producer. It also signals events occurring between the adaptor, mapper, and extractor processes. The Kafka service additionally provides a UI to monitor topics and messages. This component is packaged with the Federator component.

**DPN Caching Service**
This component uses Redis caching to store Kafka offsets for various topics and to cache tokens as necessary for the Federator Server and Clients. It is also bundled with the Federator Gateway package.

**DPN Vault Service**
This component uses HashiCorp Vault for storing secrets used by the individual DPN components. It is also packaged with the Federator Gateway package.

---

## Installation Prerequisites

The following prerequisites must be completed before beginning the installation process.

### 1. Clone and Prepare Source Repositories

Clone the official repositories from GitHub.

```bash
git clone https://github.com/energy-dsi/dpn-federator.git
git clone https://github.com/energy-dsi/dpn-federator-certificate-manager.git
git clone https://github.com/energy-dsi/dpn-data-pipelines.git
```

Switch to the desired branch.

```bash
git checkout main
```

or

```bash
git checkout release/<version>
```

Push the code to the organisation's Azure DevOps repository.

```bash
git remote add ado https://dev.azure.com/<org>/<project>/_git/<repository>
git push -u ado main
```

---

### 2. Prepare Infrastructure and Application Prerequisites

Ensure the following prerequisites are completed before deployment:

- Infrastructure prerequisites
- Software prerequisites
- Network prerequisites
- Security prerequisites
- Certificate prerequisites

[Refer to the **Prerequisites** and **Configuration** documentation for details](01-prerequisites.md)

---

### 3. Certificate Preparation and CSR Generation

Organisations must provide their own Certificate Signing Request (CSR) file to DSI and have it signed by the DSI Certificate Authority before DPN usage. The following CSR generation process uses OpenSSL commands. Organisations may alternatively use their own standard CSR generation process.

The CSR file must contain at minimum the following Subject Alternative Names (SANs):

- A producer endpoint for serving data products — e.g. `producer.xyz.com`
- A consumer endpoint for consuming data products — e.g. `consumer.xyz.com`

### Step-by-Step Certificate Generation

For development purposes, follow these steps to generate certificates for mTLS. All passwords used are `changeit`. When generating these certficates, for the `Country Name`, you can use the value of 'UK'. All remaining certificate fields can be left to their default values.

move to the docker folder
```bash
cd docker
```

Create a config file `<orgname.cnf>` to include required SANs. 

```text
[req]
default_bits       = 2048
prompt             = no
distinguished_name = dn
req_extensions     = req_ext

[dn]
CN = <organisation specific CN>

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = producer.xyz.com
DNS.2 = consumer.xyz.com
```

Generate an RSA private key for the organisation's DPN:

```text
openssl genrsa -out <orgname>.key 2048
```

Generate the CSR for the organisation using the key file above, then submit the CSR to DSI DSM through the UI:

```text
openssl req -new -key <orgname>.key -out <orgname>.csr -config <orgname>.cnf
```

Organisations receive a **signed certificate from DSI DSM** based on their submitted CSR.

#### Certificate Files Received in DPN Package from DSI

Organisations receive a certificate package after uploading their CSR file to DSI. The package contains the `certificate.crt` and `ca_chain.crt` files from DSI. The following table lists the files provided to DPNs during DPN connection setup.

| File            | Description |
|-----------------|-------------|
| `<orgname>.crt` | Certificate signed by DSI DSM |
| `ca_chain.crt`  | Intermediate certificate chain provided by DSI DSM |

---

### 4. Identify Pipeline Repository Structure

Each DPN code repository includes the necessary CI and CD pipelines in the following folder structure for reference.

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        ├── ci-pipelines/
        └── cd-pipelines/
```

---

## Installation Steps

The DPN currently comprises the following components:

- DPN Vault and Shared File Service
- DPN Federator Certificate Manager
- DPN Federator Gateway
- DPN Data Pipeline
- DPN Data Store

The installation steps for each component are outlined separately below.

---

### Part 1 — Hashicorp Vault Deployment

**Anik To Complete this block**

#### Hashicorp Vault Configuration

Once the HashiCorp Vault pod is running on port **8200** in the Kubernetes environment, issue the following commands to initialise the Vault. The examples below assume the pod instance ID is `vault-x` and the namespace is `<namespace>`.

##### Step 1 — Verify the HashiCorp Vault Container is Running

```bash
kubectl -n <namespace> exec vault-x -- vault status -format=json
```

##### Step 2 — Initialise the Vault and Generate Unseal Keys and Root Token

```bash
kubectl -n <namespace> exec vault-x -- vault operator init -key-shares=1 -key-threshold=1 -format=json
```

> **Note:** A single key share is used here for convenience. In production, use multiple key shares (e.g. `-key-shares=5 -key-threshold=3`) to distribute unseal keys across different operators via [Shamir's secret sharing](https://developer.hashicorp.com/vault/docs/concepts/seal).

##### Step 3 — Unseal the Vault

Use the `<unseal_key>` received in the step above:

```bash
kubectl -n <namespace> exec vault-x -- vault operator unseal <unseal_key>
```

##### Step 4 — Enable the Vault KV v2 Engine

Use the `<RootToken>` received during the initialisation step:

```bash
kubectl -n <namespace> exec vault-x -- env VAULT_TOKEN=<RootToken> vault secrets enable -path=pki-client kv-v2
```

---

#### Certificate Load Steps in Vault

The following commands load the key pair and certificate bundle received from DSI DSM into the Vault. The examples assume the pod instance ID is `vault-x`, the Vault root token is `<RootToken>`, and the namespace is `<org-namespace>`. The signing key is `<orgname>.key`, and the bundle contains `ca-chain.crt` and `certificate.crt`.

##### Step 1 — Load the Key Pair to Vault

```bash
kubectl -n <namespace> exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/keypair \
  privateKey="$(cat <orgname>.key)" \
  publicKey="$(openssl rsa -in <orgname>.key -pubout 2>/dev/null)"
```

##### Step 2 — Load the CA Chain to Vault

```bash
kubectl -n <namespace> exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/ca-chain \
  chain="$(cat ca-chain.crt)"
```

##### Step 3 — Load the Certificate to Vault

```bash
kubectl -n <namespace> exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/certificate \
  certificate="$(cat certificate.crt)"
```

---

### Part 2 — DPN Certificate Life Cycle Manager Installation

The Certificate Life Cycle Manager has the following dependencies that must be fulfilled before deployment:

- HashiCorp Vault service for certificate synchronisation and renewal
- Shared file service provisioned for storing the keystore and truststore files
- Configuration prerequisites met

#### Step 1 — Prepare Federator Certificate Manager CI Pipeline

Create a new Azure DevOps Pipeline from the `certificate-manager-ci.yaml` file located at the following path in the `dpn-federator-certificate-manager` repository:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── certificate-manager-ci.yaml
```

#### Step 2 — Execute Federator Certificate Manager CI Pipeline

The CI pipeline requires the following runtime parameters. These are selected when manually triggering a pipeline run:

- **serviceConnection** — Required for deployment on the Azure Private platform
- **environment** — The deployment environment

> **Note:** The parameters above must be configured according to the existing provisioned infrastructure configuration.

#### Step 3 — Verify Federator Certificate Manager CI Pipeline

Execute the CI pipeline and verify that the image registry has been updated with the correct image tag. Use the following commands against the Azure Container Registry platform.

List all repositories in the registry:

```bash
az acr repository list --name <acr-name>
```

Verify the image tag for a specific image:

```bash
az acr repository show-tags --name <acr-name> --repository <image-name>
```

Replace `<acr-name>` with the registry name and `<image-name>` with the image being checked (e.g. `dpn-federator-certificate-manager`).

> **Note:** The Build ID generated by a successful `certificate-manager-ci.yaml` run is used as the `imageTag` parameter when executing the CD pipeline in the next step.

---

#### Step 4 — Prepare Federator Certificate Manager CD Pipeline

Create a new Azure DevOps Pipeline from the `certificate-manager-cd.yaml` file located at the following path:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── certificate-manager-cd.yaml
```

#### Step 5 — Execute Federator Certificate Manager CD Pipeline

The CD pipeline requires the following runtime parameters. These are selected when manually triggering a pipeline run:

- **serviceConnection** — Required for deployment on the Azure Private platform
- **environment** — The deployment environment
- **imageTag** — The image tag generated from the CI pipeline after verification

#### Step 6 — Verify Federator Certificate Manager CD Pipeline

Once the CD pipeline completes, verify the deployment using the following commands. Replace `<namespace>` with the target namespace.

Check that both the certificate manager and Vault pods are in a `Running` state:

```bash
kubectl get pods -n <namespace>
```

Check that the Vault service is exposed:

```bash
kubectl get svc -n <namespace>
```

Check that all deployments are healthy (`READY` should match `DESIRED`, e.g. `1/1`):

```bash
kubectl get deployments -n <namespace>
```

View logs for a specific pod and verify that they are clean:

```bash
kubectl logs <pod-name> -n <namespace>
```

Check the common keystore and truststore P12 file location (e.g. `/tls`) using the following command, and verify that these files are present along with their password files (as specified in [Certificate P12 Storage as File Share](02-configuration-parameters.md#certificate-p12-storage-as-file-share)):

```bash
kubectl -n <namespace> exec <pod-name> -- ls /tls
```

---

### Part 3 — DPN Data Pipeline Installation

![DPN Data Pipeline DevOps Architecture](/Docs/04-dpn-architecture/images/dpn_data_pipeline_devops.png)

The DPN Data Pipeline is a series of data validation stages processed through the adaptor and mapper components as outlined in the architecture overview above.

---

#### Step 1 — Configure Data Pipeline CI Pipeline

Create a new Azure DevOps Pipeline from the CI pipeline YAML file located at the following path:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── dsi-data-pipelines-ci.yaml
```

---

#### Step 2 — Execute Data Pipeline CI Pipeline

The CI pipeline is designed to support both Producer and Consumer configurations. When triggering the pipeline, parameters must be selected carefully, as the required inputs vary depending on the selected configuration type.

##### Common Parameters (Required for Both Producer and Consumer)

- **Pipeline Version** — Select the appropriate branch or tag (e.g. `devops`)
- **Environment** — Choose the target environment (e.g. `dev`)
- **Service Connection** — Select the Azure service connection corresponding to the chosen environment

##### Consumer Configuration

When **Config Type = `consumer`** is selected:

- **Process Type** — Not required (selection is ignored by the pipeline)
- **Schema Type** — Not required

The pipeline proceeds with consumer-specific configuration and deployment only.

##### Producer Configuration

When **Config Type = `producer`** is selected:

- **Process Type** — Mandatory. Currently supported value: `file`. (This may be extended in future releases.)
- **Schema Type** — Mandatory. Currently supported values: `eq`, `dl`, `eqbd`, `ssh`. (This list is extensible in future releases.)
- **Product Type** — Mandatory. Must be provided to correctly parameterise the producer pipeline.

Failure to provide Process Type and Schema Type when running the pipeline in producer mode will result in an invalid or incomplete execution.

> **Notes:**
> - The same CI pipeline is used for both producer and consumer, with behaviour controlled entirely by parameter selection.
> - Schema Type and Process Type are validated only when `producer` is selected.
> - Future enhancements may introduce additional schema types and process types without changing the overall pipeline structure.

---

#### Step 3 — Validate Data Pipeline CI Pipeline

Verify that the image registry has been updated with images in the following naming format:

```
<configType>-<processType>-adaptor-<schemaType>:<buildId-productType>
<configType>-<processType>-mapper-<schemaType>:<buildId-productType>
<configType>-<processType>-extractor:<buildId>
<configType>-<processType>-mapper:<buildId>
```

List all repositories in the registry to confirm:

```bash
az acr repository list --name <acr-name>
```

---

#### Step 4 — Configure Data Pipeline CD Pipeline

Create a new Azure DevOps Pipeline from the CD pipeline YAML file located at the following path:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dsi-data-pipelines-cd.yaml
```

> **Note:** Organisations must determine which data templates they require for processing. The pipelines are designed to be generic, processing a specific type (producer or consumer), integration pathway (file, topic, API), cloud provider type (Azure, AWS, GCP), and consumer ID.

---

#### Step 5 — Execute Data Pipeline CD Pipeline

Execute the CD pipeline and verify that the containers are deployed on the Azure Kubernetes platform. There should be the following two containers running per data product file produced, for each template type (`DL`, `EQ`, `EQBD`, or `SSH`) at each integration pathway level on the producer side:

```
producer-{integration type}-adaptor-{data product type}-xxxxxxxx
producer-{integration type}-mapper-{data product type}-yyyyyyyy
```

Similarly, the following containers will be deployed on the consumer side for each data product consumer ID subscribed to a specific data product type:

```
consumer-{integration type}-extractor-{data product type}-{consumer ID}-xxxxxxxx
consumer-{integration type}-mapper-{data product type}-{consumer ID}-xxxxxxxx
```

Example container names post-deployment:

```
producer-file-adaptor-eqbd-xxxxxxxx
producer-file-mapper-eqbd-xxxxxxxx
consumer-file-extractor-xxxxxxxx
consumer-file-mapper-xxxxxxxx
```

---

#### Step 6 — Verify Data Pipeline CD Pipeline

Once a successful deployment has completed, the DPN Kubernetes cluster should show an output similar to the example below. This example uses selective `eq` and `dl` producer sample data products on the producer side, and an organisation receiving two data products using the schema type and organisation name.

```text
- Product type  : eq-sample-1, dl-sample-1
- Schema type   : eq and dl
- Cloud type    : azure
- Process type  : file
```

![DPN Reference Implementation](/Docs/04-dpn-architecture/images/dpn_reference_implementation.png)

```bash
kubectl get pods -n <namespace>
```

Verify clean logs inside the container:

```bash
kubectl logs <pod-name> -n <namespace>
```

---

### Part 4 — DPN Federator Gateway Installation

The Federator deployment includes the following components, each appearing as an individual container when deployed.

| Component       | Purpose |
|-----------------|---------|
| Zookeeper Src   | Coordination service for the Kafka producer cluster |
| Zookeeper Dest  | Coordination service for the Kafka consumer cluster |
| Kafka Src       | Source Kafka cluster |
| Kafka Dest      | Target Kafka cluster |
| Kafka UI        | Kafka monitoring interface |
| Redis           | Stores Kafka offsets |
| Federator Server| Sends data via gRPC |
| Federator Client| Receives data and writes to Kafka |
| Vault Service   | Secret store |

---

#### Pipeline Variable Groups

Before running any pipeline, ensure the following **Azure DevOps Variable Groups** are created and populated as secrets. Variable groups store credentials and shared configuration values referenced by all Federator pipelines. Organisations may adopt any other pipeline environment variable strategy to pass these confidential parameters at runtime.

##### Variable Group: `dockerhub-creds`

| Variable Name       | Description |
|---------------------|-------------|
| `DOCKERHUB_USERNAME` | DockerHub username used to pull base images during CI builds |
| `DOCKERHUB_PASSWORD` | DockerHub password or access token |

##### Variable Group: `federator-ci`

| Variable Name          | Description |
|------------------------|-------------|
| `GITHUB_MAVEN_USERNAME` | GitHub username with access to the GitHub Maven Package Registry |
| `GITHUB_MAVEN_TOKEN`    | GitHub Personal Access Token (PAT) with `read:packages` scope |

---

#### Step 1 — Configure Maven Settings

The Federator is a Java application built using Maven. Some of its dependencies are hosted in the **GitHub Maven Package Registry**, which requires authentication. This step ensures the CI pipeline can authenticate with GitHub when downloading those dependencies.

The following credentials must be set in the `federator-ci` pipeline variable group:

```
GITHUB_MAVEN_USERNAME=<GitHub username>
GITHUB_MAVEN_TOKEN=<GitHub PAT token>
```

The CI pipeline automatically injects these values into a `settings.xml` file at runtime, located at:

```
Root-Repository/
└── .m2/
    └── settings.xml
```

The relevant section of the generated `settings.xml` is shown below for reference. **Do not commit credentials directly into this file.**

```xml
<settings>
  <servers>
    <server>
      <id>github</id>
      <username>${env.GITHUB_ACTOR}</username>
      <password>${env.GH_PACKAGES_PAT}</password>
    </server>
  </servers>
</settings>
```

> **Note:** The `GITHUB_MAVEN_TOKEN` must have the `read:packages` scope. Using a token without this scope will cause the Maven build to fail with an authentication error.

---

#### Step 2 — Configure Federator CI Pipeline

The following CI pipeline is present in the `dpn-federator` repository. Create a new Azure DevOps Pipeline from the YAML file at the following location:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── DPN-Federator-CI.yaml
```

##### How to Create the Pipeline in Azure DevOps

1. Go to **Pipelines** in your Azure DevOps project and click **New Pipeline**.
2. Select the source repository (e.g. Azure Repos Git or GitHub).
3. Choose the `dpn-federator` repository.
4. Select **Existing Azure Pipelines YAML file**.
5. Point to the relevant YAML file path from the list above.
6. Click **Save** (do not run yet — parameters must be provided at runtime).

##### CI Pipeline Parameters

The CI pipeline accepts the following runtime parameters, which are selected when manually triggering a pipeline run:

- **Pipeline Version** — Select the appropriate branch or tag (e.g. `main`)
- **Environment** — Choose the target environment (e.g. `dev`, `test`)
- **Service Connection** — Select the Azure service connection corresponding to the chosen environment

> **Note:** The parameters above must be configured according to the existing provisioned infrastructure and cluster configuration.

---

#### Step 3 — Execute Federator CI Pipeline

Run the `federator-ci.yaml` pipeline.

Once the pipeline has executed, verify that the image registry has been updated with the correct image tag.

List all repositories in the registry:

```bash
az acr repository list --name <acr-name>
```

Verify the image tag for a specific image:

```bash
az acr repository show-tags --name <acr-name> --repository <image-name>
```

Replace `<acr-name>` with the registry name (e.g. `acrdpndevuks01`) and `<image-name>` with the image being checked (e.g. `dpn-federator-client`).

> **Note:** The Build ID generated by a successful `federator-ci.yaml` run is used as the `imageTag` parameter when executing the CD pipeline in Step 5.

---

#### Step 4 — Configure Federator CD Pipeline

Create a new Azure DevOps Pipeline from the CD pipeline YAML file located at the following path. The CD pipeline deploys the complete Federator package, comprising the following components:

1. `zookeeper-src`
2. `zookeeper-target`
3. `kafka-src`
4. `kafka-target`
5. `kafka-ui`
6. `redis`
7. `federator-server`
8. `federator-client`

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── azure-dpn-cd.yaml
```

##### CD Pipeline Parameters

The following parameters must be provided during CD pipeline execution:

- **Pipeline Version** — Select the appropriate branch or tag (e.g. `main`)
- **Environment** — Choose the target environment (e.g. `dev`, `test`)
- **Service Connection** — Select the Azure service connection corresponding to the chosen environment
- **Image Tag** — The image tag created by the Federator CI pipeline

##### Environment Configuration Files

The CD pipeline reads its environment-specific values from a JSON configuration file in the repository. The file used depends on the `environment` and `dpncluster` parameters selected at runtime. To deploy to a new environment, create a new JSON configuration file following the same structure as the examples below, and ensure the corresponding service connection is configured in Azure DevOps.

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── config/
            ├── dev-dpn01.json
            ├── test-dpn01.json
            ├── preprod-dpn01.json
            └── prd-dpn02.json
```

---

#### Step 5 — Execute Federator CD Pipeline

1. Go to **Pipelines** in your Azure DevOps project.
2. Click on the `azure-dpn-cd` pipeline.
3. Click **Run Pipeline**.
4. Fill in the parameters:
   - **ServiceConnection** — select the correct service connection for the target environment
   - **environment** — e.g. `dev`
   - **imageTag** — the Build ID from the successful `federator-ci.yaml` run (e.g. `1042`), found in the pipeline run history
5. Click **Run** and monitor the pipeline log.

If the pipeline completes successfully, the following message will appear at the end of the deployment stage:

```
DPN DEPLOYMENT COMPLETE
```

---

#### Post Deployment Verification

Once the CD pipeline completes, verify the deployment using the following commands. Replace `<namespace>` with the target namespace.

Check that all pods are in a `Running` state:

```bash
kubectl get pods -n <namespace>
```

Check that all services are exposed:

```bash
kubectl get svc -n <namespace>
```

Check that all deployments are healthy (`READY` should match `DESIRED`, e.g. `1/1`):

```bash
kubectl get deployments -n <namespace>
```

View logs for a specific pod:

```bash
kubectl logs <pod-name> -n <namespace>
```

---

#### Kafka UI Verification

To verify Kafka topics, a User Interface is provided with the DPN deployment. To access this UI, the Windows Azure Virtual Machine specified in the prerequisites is required, as the interface is only accessible within the Azure network.

```
http://kafka-ui:8085
```

This interface provides the following capabilities:

- Viewing Kafka clusters deployed in DPN
- Inspecting topics in the clusters
- Publishing test messages to verify connectivity
- Verifying data transmission between organisations

After publishing a test message to the source Kafka cluster topic, check the corresponding topic on the destination Kafka cluster. If the Federator is working correctly, the message should appear within seconds.

---

## Troubleshooting

### CI Pipeline Failure

Possible causes:

- Incorrect GitHub PAT token or missing `read:packages` scope
- Maven repository authentication failure — verify `GITHUB_MAVEN_USERNAME` and `GITHUB_MAVEN_TOKEN` in the `federator-ci` variable group
- Docker login failure — verify `DOCKERHUB_USERNAME` and `DOCKERHUB_PASSWORD` in the `dockerhub-creds` variable group
- ACR login failure — verify that the service principal used by the Service Connection has the `AcrPush` role on the Container Registry

Verify pipeline logs and ensure all credentials are correct.

---

### Container Image Not Found

Check whether the CI pipeline pushed images to the registry:

```bash
az acr repository list --name <acr-name>
```

If the expected repository is not listed, re-run the relevant CI pipeline and ensure it completes without errors before proceeding to the CD pipeline.

---

### Pods Not Starting

Check pod events to identify scheduling or image pull issues:

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Review the `Events` section at the bottom of the output. Common causes include insufficient node resources, missing Persistent Volume Claims, or image pull errors due to incorrect ACR credentials.

---

### Container CrashLoopBackOff

A `CrashLoopBackOff` status means the container starts, crashes, and Kubernetes repeatedly attempts to restart it. Check the logs to identify the root cause:

```bash
kubectl logs <pod-name> -n <namespace>
```

Common causes:

- Invalid or missing environment variables — check the Helm values file for typographical errors or missing entries
- Missing secrets or incorrect SAS Token for Blob storage — verify all required secrets exist in Azure Key Vault with the correct names and values
- Kafka topic is not pre-populated — run the Kafka Topic Creator job or manually create topics via the Kafka UI

---

### Kafka Topic Issues

Verify Kafka topics using the Kafka UI:

```
http://kafka-ui:8085
```

Check that:

- The topic exists in both the source and destination Kafka clusters
- The topic name in the Federator configuration matches exactly (topic names are case-sensitive)
- There are no consumer group errors shown in the Kafka UI for the Federator consumer group

---

### Certificate Renewal Job Failing

When the CD pipeline is run and pods are started for the first time, the log verification step described in [Verify Federator Certificate Manager CD Pipeline](#step-6--verify-federator-certificate-manager-cd-pipeline) may show Vault access errors. This occurs because the Vault configuration has not yet been completed at this stage.

Ensure that both the Vault and certificate manager pods are restarted after configuring the Vault as described in [HashiCorp Vault Configuration](02-configuration-parameters.md#vault-configuration).

To restart a pod:

```bash
kubectl -n <namespace> delete po/<pod_id>
```

> **Note:** If the renewal job fails after the pods have been stopped for a period exceeding the renewal frequency (`cert.renewalRateMs`), the organisation's DPN administrator must raise a request with a new CSR to the DSM to obtain a new certificate bundle. Load the new bundle into the DPN Vault using the steps described in [Certificate Load Steps in Vault](02-configuration-parameters.md#certificate-load-steps-in-vault).

---

### Certificate Sync Job Failing

If the sync job fails with the following error:

```text
INFO  u.g.d.n.f.c.m.s.KeyStoreSyncServiceImpl [] - Synchronizing keystores to filesystem...
ERROR u.g.d.n.f.c.m.job.CertificateSyncJob [] - Error during certificate synchronization job execution: Failed to create keystore
uk.gov.dbt.ndtp.federator.certificate.manager.exception.KeyStoreCreationException: Failed to create keystore
        at uk.gov.dbt.ndtp.federator.certificate.manager.service.pki.KeyStoreService.createKeyStore(KeyStoreService.java:62)
Caused by: java.security.KeyStoreException: Certificate chain is not valid
```

Verify that the CA chain, intermediate CA, certificate, and key pair files stored in the Vault are in sync — that is, all are linked to the same CSR and root CA. If they are not, raise a new certificate bundle request using a new CSR.

---

### Federator Connection Failing

If the following log entries are observed and the connection does not proceed:

```
u.g.d.n.f.c.s.i.IdpTokenServiceMtlsImpl - No cached token in Redis for default management node, fetching from IDP
15:15:34.346 [main] DEBUG u.g.d.n.f.c.s.i.IdpTokenServiceMtlsImpl - attempting to fetch token for management node
```

Verify that the mutual TLS certificates are correctly loaded in Vault and that the Vault and certificate manager pods are in a healthy running state. Check that keystore and truststore files are present at the expected shared storage path (e.g. `/tls`).

---

### Invalid Client Credential

An "Invalid client credential" error can arise due to a mismatch in the IDP client secret (`OAUTH2-CLIENT-SECRET`), which may occur following a periodic rotation carried out at the DSM side that renders the secret invalid at the DPN end.

```
Recommended fix: Obtain the updated client secret for the Client ID from DSM by raising a request with the DSM team.
```

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 15-May-2026 | DSI Assurance    | Draft  | V0.1.0 |
