# DPN Installation Process

---

# Table of Contents

- [Overview](#overview)
- [Architecture Overview](#architecture-overview)
- [Installation Prerequisites](#installation-prerequisites)
- [1. Clone and Prepare Source Repositories](#1-clone-and-prepare-source-repositories)
- [2. Prepare Infrastructure and Application Prerequisites](#2-prepare-infrastructure-and-application-prerequisites)
- [3. Certificate Preparation](#3-certificate-preparation)
- [4. Pipeline Repository Structure](#4-pipeline-repository-structure)
- [Part 1 — DPN Federator Gateway Installation](#part-1--dpn-federator-gateway-installation)
- [Step 1 — Configure Maven Settings](#step-1--configure-maven-settings)
- [Step 2 — Setup Keystore and Truststore](#step-2--setup-keystore-and-truststore)
- [Step 3 — Configure Federator CI Pipelines](#step-3--configure-federator-ci-pipelines)
- [Step 4 — Execute Federator CI Pipelines](#step-4--execute-federator-ci-pipelines)
- [Step 5 — Configure Federator CD Pipeline](#step-5--configure-federator-cd-pipeline)
- [Step 6 — Execute Federator CD Pipeline](#step-6--execute-federator-cd-pipeline)
- [Post Deployment Verification](#post-deployment-verification)
- [Part 2 — DPN Data Pipeline Integration](#part-2--dpn-data-pipeline-integration)
- [Step 1 — Configure Storage Access](#step-1--configure-storage-access)
- [Step 2 — Configure Kafka Topics](#step-2--configure-kafka-topics)
- [Step 3 — Configure Data Pipeline CI Pipeline](#step-3--configure-data-pipeline-ci-pipeline)
- [Step 4 — Execute Data Pipeline CI Pipeline](#step-4--execute-data-pipeline-ci-pipeline)
- [Step 5 — Configure Data Pipeline CD Pipeline](#step-5--configure-data-pipeline-cd-pipeline)
- [Step 6 — Execute Data Pipeline CD Pipeline](#step-6--execute-data-pipeline-cd-pipeline)
- [Post Deployment Verification](#deployment-verification)
- [Troubleshooting](#troubleshooting)

---

## Overview

This document provides step-by-step instructions for installing and deploying **DPN components** using **Azure DevOps (ADO) pipelines**.

The deployment uses the following repositories:

- https://github.com/energy-dsi/dpn-deployment
- https://github.com/energy-dsi/dsi-data-pipelines

The deployment process consists of:

- **Continuous Integration (CI)** – builds container images
- **Continuous Deployment (CD)** – deploys images into **Azure Kubernetes Service (AKS)**

The following flow diagram explains the installation process steps.

![DPN Components](/Docs/04-dpn-architecture/images/dpn_installation.png)

---

## DPN Data Pipelines Architecture Overview

The following diagram illustrates the high-level architecture blocks of the **DPN Data Exchange platform** between a Data Producer and Data Consumer using file integration pathway and Federator gateway.

![DPN Architecture Blocks](/Docs/04-dpn-architecture/images/dpn_architecture.png)

The architecture consists of following logical componenets:

**DPN Federator Gateway**
This component is responsible for file transmission over GRPC Connection, communication with DSM Keycloak and management node services.

**DPN Federtor Gaeteway Server**
- Receives Federator Client requests
- Authenticate with DSM service
- Receives Producer and consumer configuration from management node
- Connects to the kafka topic based on the client request on data product
- Initiates GRPC based file streaming service with Federator client

**DPN Federator Gateway Client**
- Initiates Federator server request based on a scheduled job
- Authenticate with DSM service
- Receives Producer and consumer configuration from management node
- Initiates GRPC based file streaming service with Federator server
- Places the file in storage container

**DPN Certificate Life Cycle Manager**
This Component is responsible for issuing bootstrap certificates to initiate connection with managment node. This component renews the certificates with management node and stores in a P12 storage. Federator server and client uses the location to point the certificate files for initiating mutual TLS with DSM and other DPNs.

**DPN Data Pipeline Producer**
- File extracted from organization source storage location automatically on a schedule basis
- Processed by adaptor and mapper components
- Published to Kafka topics with final file location
- Published to the target storage location

**DPN Data Pipeline Consumer**
- Federator Client receives file in a consumer specific storage account or bucket
- Checksum and hashes validation are performed on the received file(s)
- File is taken for processing by the extractor service and placed into another target container
- Mapper components perform schema validation based on the schema type mentioned in the file name.
- Processed file is stored in the consumer target storage container or bucket
- A Kafka based streaming message is sent to a destination kafka topic to mark end of the data pipleline process

**DPN Streaming Service - Kafka**
This component is responsible for event emission and storing locations of the data product files produced by Data Pipeline producer. Also it helps in signaling events occured between adaptor, mapper and extractor processes. The Kafka service also provides an UI to monitor the topics and messages inside it. This is packaged along with Federator component.

**DPN Caching Service**
This component uses redis caching to store the kafka offsets for various topics, caching of tokens as necessary for federator server and clients. This is also bundled with Federator gateway package

**DPN Vault Servie**
This component uses Hashicorp Vault set up for storing of secrets used by the individual components. This is also packaged with Federator Gatway package.

---
## Installation Prerequisites

The following steps 

### 1. Clone and Prepare Source Repositories

Clone the official repositories from GitHub.

```bash
git clone https://github.com/energy-dsi/dpn-federator-certificate-manager.git
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

Push the code to the organization's Azure DevOps repository.

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

### 3. Certificate Preparation & CSR Generation
<Anuran - Please check with Ramya as she is preparing a document>

Organizations receive a **signed certificate from DSI DSM** based on their submitted CSR.

#### Certificate Files from DSI
Organizations to receive a certificate package post upload of CSR files. The package would contain the .crt and the ca_chain files from DSI.The following is an example list of files to be provided to DPNs during DPN connection.

| File | Description |
|-----|-------------|
| orgcert.crt | Certificate signed by DSI DSM |
| ca_chain.crt | Intermediate certificate chain provided by DSI DSM |

#### Set up Vault Service
<Anuran>

#### Certificate Upload in Hashicorp Vault
<Anuran>

#### Set up P12 File Share Service
<Anuran>
Mention Secrets/access key set up for file share

---
### 4. Identify Pipeline Repository Structure

Each DPN code repositories are provided with necessary CI and CD pipelines in the following folder structure as reference. 

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        ├── ci-pipelines/
        └── cd-pipelines/
```

---

## Installation Steps

The DPN is presently comprises of following components. 

* DPN Vault and P12 File Share
* DPN Federator Certificate Manager
* DPN Federator Gateway
* DPN Data Pipeline
* DPN Data Store

The installation steps are outlined below for each of the components separately. 

### PART 1 - DPN Vault Service and File Share Installation
<Anuran> - Mention Installation Steps, CD pipelines for vault, For file share mention about Azure File share, mounting as persistent Volume

### PART 2 - DPN Certificate Life Cycle Manager Installation
<Anuran> - Mention details steps with appropriate heading , helm chart/values and specific configurations

Provide UI Screenshots as required.

### PART 3 - DPN Data Store Installation
<Tamanna/Shrini>
Mention about Storage account containers and Kafka topics for DSI Data Pipeline

### PART 4 — DPN Data Pipeline Installation with File based Integration Pathway
<Tamanna/Shrini> - <Provide a step by step configuration and helm chart/values yaml, Describe data product CI/CD and consumer side configurations required in CI/CD as per the diagram below.>

![DPN Data Pipeline DevOPS Architecture](/Docs/04-dpn-architecture/images/dpn_data_pipeline_devops.png)

DPN Data Pipeline is a series of data validation through the adaptor and mappers process as outlined in the architecture overview above. 

---

#### Step 1 — Configure Storage and Containers

[Go to Helm Chart Configuration for DPN Data Pipeline](02-configuration-parameters.md#helm-chart-configuration)

#### Data Pipeline Repository Structure

The DPN-data-pipeline has following structure which defines a list of blueprints for both producer and consumers.DSI has provided reference blueprints of types below.DPN organization should refer the blueprint templates or they can bring their own blueprint templates. 

The repository structure follows /blueprint/producer/{integration pathway} and /blueprint/consumer/{integration pathway}. 

```
Root-Repository/
└── .docs/
└── .pipelines
└── packages/
└── producer/ {DPN Needs to add this folder manaually. The existing repo will onle provide blueprint}
    ├── file/
    │   ├── eq-prod-1/  {eq-prod-1 is a reference from EQ blueprint type and should be placed exactly here}
    │   │   ├── adaptor/
    │   │   ├── schema-mapper/    
    │   ├── dl-dp-3/  {dl-dp-3 is a reference from dl blueprint type and should be placed exactly here}
    │   │   ├── adaptor/
    │   │   ├── schema-mapper/ 
└── cosnumer/ {DPN Needs to add this folder manaually. The existing repo will onle provide blueprint}
    ├── file/
    │   ├── eqbd-con-1/  {eqbd-con-1 is a reference from EQBD blueprint type and should be placed exactly here}
    │   │   ├── extractor/
    │   │   ├── schema-mapper/    
    │   ├── ssh-dp-2/  {ssh-dp-2 is a reference from ssh blueprint type and should be placed exactly here}
    │   │   ├── adaptor/
    │   │   ├── schema-mapper/ 
└── consumer/
└── blueprints/
    ├── producer/
    │   ├── file/
    |   │   ├── eq/
    │   │   │   ├── adaptor/
    │   │   │   ├── schema-mapper/    
    │   │   ├── eqbd/
    │   │   └── dl/
    │   │   └── ssh/
    ├── consumer/
    │   ├── file/
    |   │   ├── eq/
    │   │   │   ├── extractor/
    │   │   │   ├── schema-mapper/    
    │   │   ├── eqbd/
    │   │   └── dl/
    │   │   └── ssh/
└── smoke-test/
└── tests/
README.md

```
**Note the following**

- There is a 1:1 relation ship between the data product type folder name under producer and consumer in the pipeline. The name of the folder should be exactly the same as productType when running the CI and CD pipelines. 
- The repository will not contain producer and consumer folders in it. DPNs are required to create this exact structure while preparing for a data product. 
- DPNs should copy a product type from blueprint i.e. lets say /blueprint/producer/file/eq folder and copy to /producer/file/eq with all it's contents.
- DPNs may rename the eq to anything meaningful for the data product of type eq. However, the same name should be provided as productType during CI and CD pipeline execution.
- The same step should be repeated while building the consumer. A new folder should be created as /consumer under the root repository and point the integration pathway and data product type under it. 
---

#### Supported Energy Data Schemas

DSI provided adaptors with following schema types belonging to energy industry. Organizations are supposed to verify and augment any new schema type following the DSM data template definition and bring their own adaptor and mapper components accordingly. 


| Schema | Description |
|------|-------------|
| DL | Diagram Layout |
| EQ | Equipment |
| EQBD | Equipment Boundary |
| SSH | Steady State Hypothesis |

---

#### Step 3 — Configure Data Pipeline CI Pipeline

Prepare a new Azure DevOPS Pipeline by reading the CI pipeline yaml file from the below location under ci-pipelines.

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── dsi-data-pipelines-ci.yaml
```

---

#### Step 4 — Execute Data Pipeline CI Pipeline

Execute the CI pipelines and verify by checking the image registry updated with the image tag.

```bash
az acr repository list --name <acr-name>
```

---

#### Step 5 — Configure Data Pipeline CD Pipeline

Prepare new Azure DevOPS Pipelines by reading the CD pipeline yaml files from the below location under cd-pipelines.

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dsi-data-pipelines-cd.yaml
 
```

**Note** Organizations need to decide which data template will they require to process. The pipelines are made generic to process specific type (producer or consumer), integration pathway (file, topic, api), cloud provider type (azure, aws,gcp) and based on consumer ID.


---

#### Step 6 — Execute Data Pipeline CD Pipeline

Execute the CD pipelines and verify the containers are deployed on the Azure Kubernetes platform. There should be following 2 containers running per data product file produced of template DL, EQ , EQBD or SSH at each integration pathway level in producer side. The convention to be as followed.
  
  a) producer-{integration type}-adaptor-{dataproducttype}-xxxxxxxx <br>
  b) producer-{integration type}-mapper-{dataproducttype}-yyyyyyyy

Similarly the following containers will be deployed in consumer side at each data product consumer ID subscribed for a spcific data product type 

  a) consumer-{integration type}-extractor-{dataproducttype}-{consumer ID}-xxxxxxxx <br>
  b) consumer-{integration type}-mapper-{dataproducttype}-{consumer ID}-xxxxxxxx

Example container post deployment:

- producer-file-adaptor-eqbd-xxxxxxxx
- producer-file-mapper-eqbd-xxxxxxxx
- consumer-file-extractor-xxxxxxxx
- consumer-file-mapper-xxxxxxxx

---
#### Step 7 - Deployment Verification

Once a succesful deployment happens, the DPN Kubernetes cluster should show an example of list of containers like below. This example is taken only selective eq and dl producer sample data product in producer side and an Organization receiving the two data products using the schema type and org name.

```text
- product type - eq-sample-1, dl-sample-1
- schema type - eq and dl
- cloud type - azure
- process type - file
```

![DPN Reference Implementation](/Docs/04-dpn-architecture/images/reference_implementation.png)

```bash
kubectl get pods -n <namespace>
```

Verify clean logs inside the container

```bash
kubectl logs <pod-name> -n <namespace>
```

---

### PART 5 — DPN Federator Gateway Installation
<Anik>


Federator deployment includes the following components and shown as individual containers when deployed.

| Component | Purpose |
|----------|---------|
| Zookeeper Src | Coordination service for Kafka producer cluster |
| Zookeeper Dest | Coordination service for Kafka consumer cluster |
| Kafka Src | Source Kafka cluster |
| Kafka Dest | Target Kafka cluster |
| Kafka UI | Kafka monitoring interface |
| Redis | Stores Kafka offsets |
| Kafka Topic Creator | Optional topic creation job |
| Kafka Topic Populator | Optional sample data loader |
| Federator Server | Sends data via gRPC |
| Federator Client | Receives data and writes to Kafka |
| Vault Service    | Secret Store |

---

#### Step 1 — Configure Maven Settings

Ensure the following credential are set in the pipeline variable to pull from Maven Central.

```
Root-Repository/
└── .m2/
    └── settings.xml
```

Add credentials.

```
GITHUB_MAVEN_USERNAME=<GitHub username>
GITHUB_MAVEN_TOKEN=<GitHub PAT token>
```

---

#### Step 2 — Setup Keystore and Truststore locations

Place the following files in a secure location (TBD) that is created above in the certificate generation step.

```
keystore.jks
truststore.jks
```

---

#### Step 3 — Configure Federator CI Pipelines

The following CI pipelines are present in the dpn-federator repository. Prepare new Azure DevOPS Pipelines by reading the CI pipeline yaml files from the below location under ci-pipelines.

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            ├── DPN-Federator-CI.yaml
            ├── DPN-Kafka-Common-CI.yaml
            ├── DPN-Kafka-Topic-Creator-CI.yaml
            ├── DPN-Kafka-Topic-Populator-CI.yaml
            ├── DPN-Redis-Common-CI.yaml
            └── DPN-Zookeeper-Common-CI.yaml
```

---

#### Step 4 — Execute Federator CI Pipelines

Execute the CI pipelines and verify by checking the image registry updated with the image tag.

```bash
az acr repository list --name <acr-name>
```

```bash
az acr repository show-tags --name <acr-name> --repository <image-name>
```

---

#### Step 5 — Configure Federator CD Pipeline

Prepare new Azure DevOPS Pipeline by reading the CD pipeline yaml file from the below location under cd-pipelines. 

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── azure-dpn-cd.yaml
```

---

#### Step 6 — Configure Vault
---
In progress
---


#### Step 7 — Execute Federator CD Pipeline

Execute the CD pipeline and verify the containers are deployed on the Azure Kubernetes platform.

---

#### Post Deployment Verification

```bash
kubectl get pods -n <namespace>
```

```bash
kubectl get svc -n <namespace>
```

```bash
kubectl get deployments -n <namespace>
```

View logs.

```bash
kubectl logs <pod-name> -n <namespace>
```

---

#### Kafka UI Verification
To verify Kafka topics, DPN deployment is provided with a User Interface.To access this UI, the Windows Azure Virtual Machine mentioned in the prerequisites will be required as it is only accessible inside the Azure Network and not outside.

```
http://kafka-ui:8085
```

This interface allows the following capabilities:

- viewing Kafka clusters deployed in DPN
- inspecting topics in the clusters
- publishing test messages to verify
- verifying data transmission between organizations

---

#### Troubleshooting

##### CI Pipeline Failure

Possible causes:

- Incorrect GitHub PAT token
- Maven repository authentication failure
- Docker login failure

Verify pipeline logs and ensure credentials are correct.

---

##### Container Image Not Found

Check whether CI pipeline pushed images.

```bash
az acr repository list --name <acr-name>
```

---

##### Pods Not Starting

Check pod events.

```bash
kubectl describe pod <pod-name> -n <namespace>
```

---

##### Container CrashLoopBackOff

Check logs.

```bash
kubectl logs <pod-name> -n <namespace>
```

Common causes:

- invalid environment variables
- missing secrets or incorrect SAS Token for Blob storage
- Kafka topic is not pre populated

---

##### Kafka Topic Issues

Verify Kafka topics using Kafka UI.

```
http://kafka-ui:8085
```

---
##### Certificate Renewaljob Failing

<Anuran>

```
<Anuran to provide>
```

---
##### Certificate Sync job Failing

<Anuran>

```
<Anuran to provide>
```

---
##### Federator Connection Failing

<Anik - Please update title with the error message, I forgot the message>

```
<Anik to provide>
```

---
##### Invalid Client Credential

<Anuran - Please mention about incorrect client secret >

```
<Anuran to provide>
```

---
## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| 15-Mar-2026 | DSI Assurance   | Draft  | V0.1.0 |

---