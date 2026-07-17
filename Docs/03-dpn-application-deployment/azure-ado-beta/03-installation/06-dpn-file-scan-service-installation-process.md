# DPN File Scan Service Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Step1: Validate the Prerequisites](#step1-validate-the-prerequisites)
- [Step2: Execute Prerequisite CD Pipeline](#step2-execute-prerequisite-cd-pipeline)
  - [Step2a: Validate Prerequisite Pipeline Execution](#step2a-validate-prerequisite-pipeline-execution)
- [Step3: Execute CI Pipeline](#step3-execute-ci-pipeline)
  - [Step3a. Validate CI Pipeline Execution](#step3a-validate-ci-pipeline-execution)
  - [Step3b. Execute CD Pipeline](#step3b-execute-cd-pipeline)
  - [Step3c. Verify CD Pipeline](#step3c-verify-cd-pipeline)
  - [Step3d. Verify Scanning Service Execution](#step3d-verify-scanning-service-execution)
- [Step4: Troubleshooting](#step4-troubleshooting)
  - [Scan-Result Events Not Reaching the Verification Service](#scan-result-events-not-reaching-the-verification-service)
  - [Verification Service Cannot Read or delete from `dp-consumer-raw`](#verification-service-cannot-read-or-delete-from-dp-consumer-raw)
  - [Verified Files Not Appearing in `dp-consumer-stage`](#verified-files-not-appearing-in-dp-consumer-stage)
  - [Authentication Issue to Storage Account](#authentication-issue-to-storage-account)
  - [HPA Not Scaling](#hpa-not-scaling)
- [Step5: Containerized Deployment Using DSI Provided Container Images](#step5-containerized-deployment-using-dsi-provided-container-images)
  - [Step 6 — Configure GHCR Image Access](#step-6--configure-ghcr-image-access)
- [Review Notes](#review-notes)

---

## Overview

This document describes the planned installation process for the DPN File Scanning Service (the ADR's "DPN File Verification Service"), which inserts a malware-scanning gate in front of the existing DPN Data Pipeline Consumer Extractor. It depends on the DPN Data Pipeline already being installed, since it writes into the same `dp-consumer-stage` container that component already reads from.

---

## Step1: Validate the Prerequisites

The following prerequisites must be met.

- Defender for Cloud Storage is enabled at the subscription level or more
- The source and target storage accounts are provisioned
- The target storage account contains a container named `dp-consumer-stage` or other names if modifed
- An AKS cluster with service connection access to deploy new workloads
- Azure subscription access sufficient to enable Microsoft Defender for Storage
- Service connection required roles to create an Event Grid System Topic and provision a Service Bus namespace/topic
- Service Bus user access administrator permission to create and assign Managed Identities and RBAC role assignments
- DPN Health monitoring service is up and running. OTEL log aggregator container is healthy

---

## Step2: Execute Prerequisite CD Pipeline

The file scan prerequisite pipeline yaml file is placed in this location.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-file-scan-service-prerequisites-cd.yaml
```
Prepare a new pipeline from this yaml file and run. This pipeline will require a set of runtime parameters as defined in [File Scan Service Prerequisite Pipeline Run Parameters](../02-configuration/06-configure-dpn-file-scan-service.md)

### Step2a: Validate Prerequisite Pipeline Execution

Once the pipeline runs successfully then validate the following. 

- A new service bus topic is created
- A new container named `dp-consumer-raw` is created in source container storage account unless renamed to something else

## Step3: Execute CI Pipeline

The File Scan service CI pipeline yaml file is placed in this location to set up the CI pipeline.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── dpn-file-scan-service-ci.yaml
```

The CI pipeline requires the following paramters to be passed.

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |


Execute the CI pipeline to build the image and push to image registry.

### Step3a. Validate CI Pipeline Execution

Once the CI pipeline executes successfully a new image is pushed in the image registry mentioned in the configuration file. 

The image tag is mentioned in the pipeline clean up stage with a random numeric value as build id. The image registry to be checked if the following images are pushed. 

```text
dpn-file-scan-service:`<image tag>`
```

### Step3b. Execute CD Pipeline

Create a CD pipeline from the following yaml file. 

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-file-scan-service-cd.yaml
```
The CD Pipeline would require the following run time parameters. 

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |
|`image tag` | The same image tag created from CI pipeline during pushing the image | 

---

### Step3c. Verify CD Pipeline

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begins. 

```bash
kubectl get pods -n <namespace> # check for dpn-file-scan-service-XXXXXXXXX
kubectl logs -f dpn-file-scan-service-XXXXXXXXX
```
The kubectl logs should not showcase any [error] message if the deployment is successful. 

---

### Step3d. Verify Scanning Service Execution

- Upload a clean test file into `dp-consumer-raw` container on source storage account and confirm it lands in `dp-consumer-stage` container on destination storage account after scanning
- Verify a corresponding log entry in the OTEL aggregator is arrived on file scan
- Upload an [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) into `dp-consumer-raw` and confirm Defender for Storage flags it as malicious and deletes it from `dp-consumer-raw`
- The malicious file should never appears in `dp-consumer-stage`.
- The OTEL Collector logs the malicious-file event appropriately.

---

## Step4: Troubleshooting

### Scan-Result Events Not Reaching the Verification Service

Check the Event Grid subscription's delivery status and the Service Bus Topic/Subscription for dead-lettered messages. Confirm the Event Grid System Topic's Managed Identity has the **Azure Service Bus Data Sender** role on the topic.

### Verification Service Cannot Read or delete from `dp-consumer-raw`

Confirm the Verification Service's Managed Identity has the **Storage Blob Data Contributor** role scoped to the `dp-consumer-raw` container, and that Managed Identity (not a connection string) is actually being used at runtime.

### Verified Files Not Appearing in `dp-consumer-stage`

Confirm the Verification Service's Managed Identity has the **Storage Blob Data Contributor** role scoped to `dp-consumer-stage` target storage account, and check the service's logs (via the OTEL aggregator) for write failures.

### Authentication Issue to Storage Account

Verify the Service Principal Client ID and Client Secret are correct. Secert is not expired and the connection string has correct storage container name.

### HPA Not Scaling

If `kubectl get hpa` shows `<unknown>` under `TARGETS`, confirm metrics-server is running (`kubectl get deployment metrics-server -n kube-system`) and that the pod has CPU/memory `requests` set in its Deployment spec.

---

## Step5: Containerized Deployment Using DSI Provided Container Images

`<<Tamanna to update>>`


### Step 6 — Configure GHCR Image Access

The service pulls a single image, `ghcr.io/energy-dsi/dpn-file-scan-service:1.0.0`, at deploy time. This is the **only** image AKS pulls for this service — the Python build base (`python:3.12.11-slim-bookworm`) used to build it is a build-stage-only dependency pulled directly from Docker Hub by the CI pipeline, never by AKS, and is not mirrored to GHCR (see Third-Party / Build-Base Image — this differs from the DPN Data Pipeline, which does mirror its third-party runtime images).

1. Confirm whether the `energy-dsi/dpn-file-scan-service` GHCR package is public or private.
2. If private, create an `imagePullSecrets`-referenced Kubernetes secret in the target namespace **before** running the CD pipeline:
   ```bash
   kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
   ```
3. Ensure the CI pipeline's service connection/credentials have `write:packages` scope if this deployment will also be building and publishing the image, not just pulling a pre-built one.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
