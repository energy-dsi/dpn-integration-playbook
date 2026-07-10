- [DPN Data Pipeline Architecture](#dpn-data-pipeline-architecture)

- [Installation Prerequisites](#installation-prerequisites)
  - [Clone and Prepare Source Repository](#1-clone-and-prepare-source-repository)
  - [Prepare Infrastructure and Application Prerequisites](#2-prepare-infrastructure-and-application-prerequisites)
  - [Identify Pipeline Repository Structure](#3-identify-pipeline-repository-structure)

- [DPN Data Pipeline Installation](#dpn-data-pipeline-installation)
  - [Step 1 — Configure Data Pipeline CI Pipeline](#step-1--configure-data-pipeline-ci-pipeline)
  - [Step 2 — Execute Data Pipeline CI Pipeline](#step-2--execute-data-pipeline-ci-pipeline)
    - [Common Parameters (Required for Both Producer and Consumer)](#common-parameters-required-for-both-producer-and-consumer)
    - [Consumer Configuration](#consumer-configuration)
    - [Producer Configuration](#producer-configuration)
  - [Step 3 — Validate Data Pipeline CI Pipeline](#step-3--validate-data-pipeline-ci-pipeline)
  - [Step 4 — Configure Data Pipeline CD Pipeline](#step-4--configure-data-pipeline-cd-pipeline)
  - [Step 5 — Execute Data Pipeline CD Pipeline](#step-5--execute-data-pipeline-cd-pipeline)
  - [Step 6 — Verify Data Pipeline CD Pipeline](#step-6--verify-data-pipeline-cd-pipeline)
  - [Step 7 — (Optional) Deploy the Scheduling Backend](#step-7--optional-deploy-the-scheduling-backend)

- [Troubleshooting](#troubleshooting)
  - [CI Pipeline Failure](#ci-pipeline-failure)
  - [Container Image Not Found](#container-image-not-found)
  - [Pods Not Starting](#pods-not-starting)
  - [Container CrashLoopBackOff](#container-crashloopbackoff)
  - [Kafka Topic Issues](#kafka-topic-issues)
  - [Certificate Renewal Job Failing](#certificate-renewal-job-failing)
  - [Emergency certificate rotation process](#emergency-certificate-rotation-process)
  - [Certificate Sync Job Failing](#certificate-sync-job-failing)
  - [Federator Connection Failing](#federator-connection-failing)
  - [Invalid Client Credential](#invalid-client-credential)

- [Review Notes](#review-notes)

---

## Overview

This document provides step-by-step instructions for installing and deploying **DPN Data Pipeline component** using **Azure DevOps (ADO) pipelines**.

The deployment uses the following repositories:

- https://github.com/energy-dsi/dpn-data-pipelines.git

The deployment process consists of:

- **Continuous Integration (CI)** — builds container images
- **Continuous Deployment (CD)** — deploys images into **Azure Kubernetes Service (AKS)**

---

## DPN Containerized Deployment Architecture

The following diagram illustrates the reference DPN deployment architecture for the **DPN Data Exchange platform**. It consists of the following containerised components:

![DPN Architecture Blocks](/Docs/04-dpn-architecture/images/dpn_deployment_architecture.png)

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

---

## Installation Prerequisites

The following prerequisites must be completed before beginning the installation process.

### 1. Clone and Prepare Source Repositories

Clone the official repositories from GitHub.

```bash
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

- Kubernetes secrets provisioned for producer/consumer storage connection strings (see [Secrets Configuration](02-configuration-parameters.md#secrets-configuration-data-pipelines))
- Network and firewall rules applied as described in [Network and Ports Configuration](02-configuration-parameters.md#network-and-ports-configuration)
- Software prerequisites

[Refer to the **Prerequisites** and **Configuration** documentation for details](01-prerequisites.md)

> **Note:** Certificate/CSR generation is **not** required for the Data Pipeline — that prerequisite applies only to the DPN Vault, Federator Certificate Manager, and Federator Gateway, which are covered in their own installation guides.
---

### 3. Identify Pipeline Repository Structure

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

The installation steps for each component are outlined separately.

---

### DPN Data Pipeline Installation

The DPN Data Pipeline is a series of data validation stages processed through the adaptor and mapper components as outlined in the architecture overview above.

The following diagram represents an overview of DPN Producer Data Pipeline CI/CD architecture. 

![DPN Data Pipeline Producer DevOPS Architecture](/Docs/04-dpn-architecture/images/dpn_data_pipeline_producer.png)

The following diagram represents an overview of DPN Consumer Data Pipeline CI/CD architecture. 

![DPN Data Pipeline Consumer DevOPS Architecture](/Docs/04-dpn-architecture/images/dpn_data_pipeline_consumer.png)


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
- **Schema Type** — Mandatory. Remove 'Default' before providing currently supported values: `eq`, `dl`, `eqbd`, `ssh`. (This list is extensible in future releases.)
- **Product Type** — Mandatory. Remove 'Default' before providing supoorted values. Must be provided to correctly parameterise the producer pipeline.

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

> **Repo note:** before running this pipeline, confirm the `SCHEDULER_BACKEND` value set on each product's `values.yaml` (`kafka-trigger` for automated, software-triggered scheduling, or `airflow` for orchestrator-driven scheduling — see [Scheduling Configuration](02-configuration-parameters.md#scheduling-configuration) in the Configuration Guide). If `airflow` is used for any product, complete [Step 7](#step-7--optional-deploy-the-scheduling-backend) below as part of this installation.
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

![DPN Reference Implementation](/Docs/04-dpn-architecture/images/dpn_ref_implementation.png)

```bash
kubectl get pods -n <namespace>
```

Verify clean logs inside the container:

```bash
kubectl logs <pod-name> -n <namespace>
```

---

### Step 7 — (Optional) Deploy the Scheduling Backend

If any deployed data product uses `SCHEDULER_BACKEND: airflow` (manual/orchestrator-driven scheduling) rather than `kafka-trigger` (automated, software-triggered scheduling), the Airflow chart must also be deployed — it is not installed as part of Step 5.

```
Root-Repository/
└── charts/
    └── airflow/
        ├── values-<env>-dpn01.yaml   <- Environment-specific Airflow overrides
        └── dags/
              └── {product_type}.py   <- One DAG per data product using the airflow backend
```

1. Confirm a DAG file exists under `charts/airflow/dags/` for every product using `SCHEDULER_BACKEND: airflow` — see [Onboarding a New Data Product — Scheduling Setup](02-configuration-parameters.md#onboarding-a-new-data-product--scheduling-setup) in the Configuration Guide if one needs to be created.
2. Deploy the Airflow chart using the same Helm/CD approach as the other components, pointing at `values-<env>-dpn01.yaml`.
3. Verify the webserver, scheduler, triggerer, worker, Postgres, and Redis pods are all `Running`:
   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/part-of=airflow
   ```
4. Confirm each product's DAG is visible and unpaused in the Airflow UI/webserver before relying on it for production runs.

Products using `SCHEDULER_BACKEND: kafka-trigger` do not require this step — they are triggered automatically via `PIPELINE_CONTROL_TOPIC`, deployed as part of Step 5.

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

### Emergency certificate rotation process

In case we need to rotate/renew the certificate adhoc forcefully using new certificate bundle received from DSI DSM, we need to perform the cleanup and rollback process listed [here](04-rollback-procedures.md#vault-certificate-bundle-rollback) using the new certificate bundle. 

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
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
