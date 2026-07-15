# DPN Installation Process

---

## Table of Contents

- [Overview](#overview)
- [DPN Containerized Deployment Architecture](#dpn-containerized-deployment-architecture)
- [Installation Prerequisites](#installation-prerequisites)
  - [1. Clone and Prepare Source Repositories](#1-clone-and-prepare-source-repositories)
  - [2. Prepare Infrastructure and Application Prerequisites](#2-prepare-infrastructure-and-application-prerequisites)
  - [3. Identify Pipeline Repository Structure](#3-identify-pipeline-repository-structure)
  - [4. Configure GHCR Image Access](#4-configure-ghcr-image-access)
  - [5. Configure Environment Approval Gates](#5-configure-environment-approval-gates)
- [Installation Steps](#installation-steps)
  - [DPN Data Pipeline Installation](#dpn-data-pipeline-installation)
  - [Step 7 — Verify Horizontal Pod Autoscalers](#step-7--verify-horizontal-pod-autoscalers)
  - [Step 8 — (Optional) Deploy the Scheduler Backend](#step-8--optional-deploy-the-scheduler-backend)
- [Troubleshooting](#troubleshooting)
  - [CI Pipeline Failure](#ci-pipeline-failure)
  - [Container Image Not Found](#container-image-not-found)
  - [GHCR Image Pull Failures](#ghcr-image-pull-failures)
  - [Data Pipeline Image Tag Malformed](#data-pipeline-image-tag-malformed)
  - [CD Pipeline Stuck Awaiting Approval](#cd-pipeline-stuck-awaiting-approval)
  - [Pods Not Starting](#pods-not-starting)
  - [Data Pipeline Pod Overwritten by Its Sibling Stage](#data-pipeline-pod-overwritten-by-its-sibling-stage)
  - [Container CrashLoopBackOff](#container-crashloopbackoff)
  - [HPA Not Scaling](#hpa-not-scaling)
  - [Kafka Topic Issues](#kafka-topic-issues)
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

Every component above runs as a container image pulled from **GHCR** — see [Container Image Configuration](02-configuration-parameters.md#container-image-configuration) in the Configuration Guide for the full image inventory.
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

- AKS cluster provisioned and accessible, with the **metrics-server** running (required for HPA — enabled by default on AKS)
- DPN Streaming Service (Kafka) deployed, with the required topics pre-created (see [DPN Streaming Service (Kafka)](02-configuration-parameters.md#dpn-streaming-service-kafka) in the Configuration Guide)
- Blob/S3 storage containers provisioned for the `file` integration pathway (see [Storage Blob / S3 Configuration](02-configuration-parameters.md#storage-blob--s3-configuration))
- Kubernetes secrets provisioned for producer/consumer storage connection strings (see [Secrets Configuration](02-configuration-parameters.md#secrets-configuration-data-pipelines))
- Network and firewall rules applied as described in [Network and Ports Configuration](02-configuration-parameters.md#network-and-ports-configuration), including outbound access to `ghcr.io`
- Software prerequisites (Azure DevOps access, GHCR access — see Step 4 below)

[Refer to the **Prerequisites** and **Configuration** documentation for details](01-prerequisites.md)

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

### 4. Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi` — see [Container Image Configuration](02-configuration-parameters.md#container-image-configuration) in the Configuration Guide for the full list.

1. Confirm whether the `energy-dsi` GHCR packages required for this deployment are public or private.
2. If private, create an `imagePullSecrets`-referenced Kubernetes secret in the target namespace **before** running the CD pipeline:
   ```bash
   kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
   ```
3. Ensure the CI pipeline's service connection/credentials have `write:packages` scope if this deployment will also be building and publishing images to GHCR, not just pulling pre-built ones.

--

### 5. Configure Environment Approval Gates

Before running the CD pipeline against any environment beyond Development, confirm the corresponding Azure DevOps Environment has its approval check configured — see [Environment-Specific Approval Gates](02-configuration-parameters.md#environment-specific-approval-gates) in the Configuration Guide for the proposed approver configuration per environment (Development: none; Test: single approver; Pre-Production: two approvers; Production: two approvers plus a defined deployment window).

Without this configured, the CD pipeline will either deploy immediately without the intended sign-off, or (if the Environment resource doesn't exist yet) fail to resolve the environment reference — confirm the Environment exists and is configured before proceeding to Step 4 of [DPN Data Pipeline Installation](#dpn-data-pipeline-installation) below.

--

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
> - On successful completion, the CI pipeline pushes the built image to `ghcr.io/energy-dsi/<image-name>:1.0.0` (or the current released version) — see [Custom Images (GHCR)](02-configuration-parameters.md#custom-images-ghcr) for the exact reference per product/schema combination.

---

#### Step 3 — Validate Data Pipeline CI Pipeline

Verify that GHCR has been updated with the expected image, using the exact reference from [Custom Images (GHCR)](02-configuration-parameters.md#custom-images-ghcr) — for example:

```bash
gh api /orgs/energy-dsi/packages/container/producer-file-adaptor-eq/versions
```

or check the package directly at `https://github.com/orgs/energy-dsi/packages/container/package/producer-file-adaptor-eq`.

> **Repo note:** the image name/tag is produced from the `imageName`/`imageTag`/`productType`/`schemaType` fields set in each product's `values.yaml` (see [Producer Setup](02-configuration-parameters.md#producer-setup)). If `productType` or `schemaType` is left blank in a product's `values.yaml`, the resulting reference will be malformed — see [Data Pipeline Image Tag Malformed](#data-pipeline-image-tag-malformed) in Troubleshooting.

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

> **Notes:**
> - Organisations must determine which data templates they require for processing. The pipelines are designed to be generic, processing a specific type (producer or consumer), integration pathway (file, topic, API), cloud provider type (Azure, AWS, GCP), and consumer ID.
> - before running this pipeline, confirm the `SCHEDULER_BACKEND` value set on each product's `values.yaml` (`kafka-trigger` for automated, software-triggered scheduling, or `airflow` for orchestrator-driven scheduling — see [Scheduling Configuration](02-configuration-parameters.md#scheduling-configuration) in the Configuration Guide). If `airflow` is used for any product, complete [Step 7](#step-7--optional-deploy-the-scheduling-backend) below as part of this installation.
> - confirm `IMAGE_REGISTRY` in the target environment's config JSON points at `ghcr.io/energy-dsi` (see [Azure Environment Configuration](02-configuration-parameters.md#azure-environment-configuration)), and that the Azure DevOps Environment for this target has its approval check configured per [Environment-Specific Approval Gates](02-configuration-parameters.md#environment-specific-approval-gates) — see [Prerequisite 5](#5-configure-environment-approval-gates) above.

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

### Step 7 — Verify Horizontal Pod Autoscalers

For any stage deployed with `hpa.enabled: true` (see [Horizontal Pod Autoscaler (HPA) Configuration](02-configuration-parameters.md#horizontal-pod-autoscaler-hpa-configuration)):

```bash
kubectl get hpa -n <namespace>
```

Confirm the `TARGETS` column shows real CPU/memory percentages (not `<unknown>`, which indicates metrics-server is not reachable), and that `MINPODS`/`MAXPODS` match the configured `hpa.minReplicas`/`hpa.maxReplicas`.

To confirm scaling behaviour under load, generate synthetic traffic against an adaptor or schema_mapper with HPA enabled, and watch:

```bash
kubectl get hpa -n <namespace> -w
```

Replica count should increase as the target metric exceeds the configured threshold, and scale back down once load subsides (subject to the default stabilisation window).

---

### Step 8 — (Optional) Deploy the Scheduler Backend

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

- GHCR authentication/push failure — verify the CI pipeline's credentials have `write:packages` scope on the `energy-dsi` GHCR namespace
- Missing or incorrect Process Type / Schema Type / Product Type parameters when triggering a producer run (see [Producer Configuration](#producer-configuration))

Verify pipeline logs and ensure all credentials and parameters are correct.

---

### Container Image Not Found

Check whether the CI pipeline pushed the image to GHCR (see [Step 3 — Validate Data Pipeline CI Pipeline](#step-3--validate-data-pipeline-ci-pipeline)).

If the expected package/tag is not listed, re-run the relevant CI pipeline and ensure it completes without errors before proceeding to the CD pipeline.

---

### GHCR Image Pull Failures

If pods show `ImagePullBackOff` or `ErrImagePull`:

- If the `energy-dsi` GHCR packages are private, confirm the `imagePullSecrets` referenced by the chart exists in the target namespace and contains a valid, non-expired GitHub PAT with `read:packages` scope — see [Configure GHCR Image Access](#4-configure-ghcr-image-access).
- Confirm the AKS node pool has outbound network access to `ghcr.io` and `pkg-containers.githubusercontent.com` — see [Network and Ports Configuration](02-configuration-parameters.md#network-and-ports-configuration).
- Confirm the image reference (`imageRegistry`/`imageName`/`imageTag`) matches an actual published GHCR package/tag exactly — a typo here produces the same failure as a genuine access issue.

---

### Data Pipeline Image Tag Malformed

If a data pipeline image tag or repository name is missing its schema/product segment (e.g. it ends in a trailing `-` or `:` instead of the expected `<buildId>-<productType>`), the product's `values.yaml` most likely has `productType` and/or `schemaType` left blank.

Check the affected product's `values.yaml` for both the adaptor and schema_mapper charts:

```bash
grep -E "^productType:|^schemaType:" producer/{file|topic}/<product_type>/{adaptor,schema_mapper}/charts/values.yaml
```

Both values must be populated (matching the schema types in [Data Pipeline Blueprints](02-configuration-parameters.md#data-pipeline-blueprints)) before re-running the CI pipeline in [Step 1 — Configure Data Pipeline CI Pipeline](#step-1--configure-data-pipeline-ci-pipeline).

---

### CD Pipeline Stuck Awaiting Approval

If a CD run for Test, Pre-Production, or Production doesn't progress past deployment, check **Pipelines → Runs → [run]** for a pending **Review** action. Confirm:

- The correct approver(s) for that environment are configured under **Pipelines → Environments → [environment] → Approvals and checks** (see [Environment-Specific Approval Gates](02-configuration-parameters.md#environment-specific-approval-gates)).
- The person expected to approve has been notified and has the necessary Azure DevOps permissions on that Environment.
- If self-approval is disabled for that environment, confirm the approver is not the same identity that triggered the run.

---

### Pods Not Starting

Check pod events to identify scheduling or image pull issues:

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Review the `Events` section at the bottom of the output. Common causes include insufficient node resources, missing Persistent Volume Claims, or image pull errors due to incorrect GHCR credentials (see [GHCR Image Pull Failures](#ghcr-image-pull-failures)).

---

### Data Pipeline Pod Overwritten by Its Sibling Stage

If only one pod appears for a product where two are expected (adaptor and schema_mapper), check whether both charts' `values.yaml` files use the same final `name`/`imageName`:

```bash
grep -E "^name:|^imageName:" producer/{file|topic}/<product_type>/{adaptor,schema_mapper}/charts/values.yaml
```

If they match, the two Helm releases are colliding on the same Kubernetes resource name and one is overwriting the other. Give the schema_mapper chart a distinct `-mapper`-suffixed `name`/`imageName` (see the naming convention in [Naming Conventions — Avoiding Resource Collisions](02-configuration-parameters.md#naming-conventions--avoiding-resource-collisions)) and re-run the CD pipeline for that product.

---

### Container CrashLoopBackOff

A `CrashLoopBackOff` status means the container starts, crashes, and Kubernetes repeatedly attempts to restart it. Check the logs to identify the root cause:

```bash
kubectl logs <pod-name> -n <namespace>
```

Common causes:

- Invalid or missing environment variables — check the Helm values file for typographical errors or missing entries
- Missing secrets or incorrect SAS Token for Blob storage — verify all required secrets exist as Kubernetes secrets with the correct names and values
- Kafka topic is not pre-populated — run the Kafka Topic Creator job or manually create topics via the Kafka UI

---

### HPA Not Scaling

If `kubectl get hpa` shows `<unknown>` under `TARGETS`:

- Confirm metrics-server is running: `kubectl get deployment metrics-server -n kube-system`.
- Confirm the affected pods have CPU/memory `requests` set in their Deployment spec — HPA cannot compute a percentage without a request baseline.

If metrics are available but replica count never changes, confirm `hpa.minReplicas`/`hpa.maxReplicas` allow room to scale, and that current load is actually crossing the configured `targetCPUUtilizationPercentage`/`targetMemoryUtilizationPercentage` threshold.

---

### Kafka Topic Issues

Verify Kafka topics using the Kafka UI:

```
http://kafka-ui:8085
```

Check that:

- The topic exists in both the source and destination Kafka clusters
- The topic name in the data pipeline configuration matches exactly (topic names are case-sensitive)
- There are no consumer group errors shown in the Kafka UI for the data pipeline's consumer group(s)
- For the `topic` pathway specifically, `srcGroupId` values are unique per product and free of stray environment/test suffixes

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
