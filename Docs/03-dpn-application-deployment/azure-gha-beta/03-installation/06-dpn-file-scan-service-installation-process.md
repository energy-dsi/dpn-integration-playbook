# DPN File Scan Service Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Step1: Validate the Prerequisites](#step1-validate-the-prerequisites)
- [Step2: Execute Prerequisite CD Workflow](#step2-execute-prerequisite-cd-workflow)
  - [Step2a: Validate Prerequisite Workflow Execution](#step2a-validate-prerequisite-workflow-execution)
- [Step3: Execute CI/CD](#step3-execute-cicd)
  - [Step3a. CI (component source repository)](#step3a-ci-component-source-repository)
  - [Step3b. Configure GHCR Image Access](#step3b-configure-ghcr-image-access)
  - [Step3c. Execute CD Workflow](#step3c-execute-cd-workflow)
  - [Step3d. Verify CD Workflow](#step3d-verify-cd-workflow)
  - [Step3e. Verify Scanning Service Execution](#step3e-verify-scanning-service-execution)
- [Step4: Troubleshooting](#step4-troubleshooting)
  - [Scan-Result Events Not Reaching the Verification Service](#scan-result-events-not-reaching-the-verification-service)
  - [Verification Service Cannot Read or delete from `dp-consumer-raw`](#verification-service-cannot-read-or-delete-from-dp-consumer-raw)
  - [Verified Files Not Appearing in `dp-consumer-stage`](#verified-files-not-appearing-in-dp-consumer-stage)
  - [Authentication Issue to Storage Account](#authentication-issue-to-storage-account)
  - [OTEL Truststore Password Errors](#otel-truststore-password-errors)
  - [HPA Not Scaling](#hpa-not-scaling)
- [Reference: Container Images Used](#reference-container-images-used)
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
- An AKS cluster reachable via the GitHub Actions OIDC federated credential (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#github-actions-oidc-federated-credential))
- Azure subscription access sufficient to enable Microsoft Defender for Storage
- Sufficient Azure role assignments to create an Event Grid System Topic and provision a Service Bus namespace/topic
- Service Bus user access administrator permission to create and assign Managed Identities and RBAC role assignments
- DPN Health monitoring service is up and running. OTEL log aggregator container is healthy

**Note:** Organisations must review the CI/CD workflow code for the following. 

- If running your own CI, keep only the relevant build, unit test, and image-push steps — DSI's own CI examples include tool usage such as CheckMarx, SonarQube, and JFrog Xray that your organisation may not need
- The container image is appropriate and referred from GHCR repository unless Organisation plans to use a separate image repository on their own
- The config JSON's environment parameters are pointing to correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- Both CI and CD are verified for the above prerequisites before execution

---

## Step2: Execute Prerequisite CD Workflow

Go to **Actions → DPN CD - File Scan Prerequisites → Run workflow** in `dpn-containerised-deployment-service`. This workflow is **Azure-specific by design** (Defender for Storage/Event Grid/Service Bus — no AWS/GCP equivalent exists yet), though it still exposes a `cloud` input for consistency. It requires the inputs defined in [File Scan Service Prerequisite Workflow Parameters](../02-configuration/06-configure-dpn-file-scan-service.md#step2a-setup-prerequisite-pipeline-parameters).

Workflow file: `.github/workflows/dpn-file-scan-prerequisites-cd.yml`

### Step2a: Validate Prerequisite Workflow Execution

Once the workflow runs successfully then validate the following. 

- A new service bus topic is created
- A new container named `dp-consumer-raw` is created in source container storage account unless renamed to something else

## Step3: Execute CI/CD

### Step3a. CI (component source repository)

CI (build, test, and image push to GHCR) isn't yet migrated to GitHub Actions in `dpn-file-scan-service` — build the image via your own CI process, or use the DSI-provided prebuilt GHCR image (see [Reference: Container Images Used](#reference-container-images-used)). Once you have a tag, note it for use as `imageTag` below.

```text
dpn-file-scan-service:<image tag>
```

### Step3b. Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`. Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably.

Create a GitHub Personal Access Token with `read:packages` scope, then create a Kubernetes secret from it:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

### Step3c. Execute CD Workflow

Go to **Actions → DPN CD - File Scan Service → Run workflow** in `dpn-containerised-deployment-service`, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `imageTag` | The image tag from Step3a |

Workflow file: `.github/workflows/dpn-file-scan-cd.yml`

---

### Step3d. Verify CD Workflow

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begins. 

```bash
kubectl get pods -n <namespace> # check for dpn-file-scan-service-XXXXXXXXX
kubectl logs -f dpn-file-scan-service-XXXXXXXXX
```
The kubectl logs should not showcase any [error] message if the deployment is successful. 

---

### Step3e. Verify Scanning Service Execution

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

### OTEL Truststore Password Errors

If OTel/telemetry export fails with a truststore password error, confirm `keyvault.truststorePasswordSecretName` in your environment's values file points at the correct Key Vault secret — the previous shared secret name, `UNIVERSAL-DPN-CERT-PASSWORD`, has been retired in favour of an environment-specific name (e.g. `KC-HTTPS-TRUST-STORE-PASSWORD` or `TRUSTSTORE-PASSWORD`); see [Configure DPN File Scan Service, Step5](../02-configuration/06-configure-dpn-file-scan-service.md#step5-configure-azure-key-vault--secrets).

### HPA Not Scaling

If `kubectl get hpa` shows `<unknown>` under `TARGETS`, confirm metrics-server is running (`kubectl get deployment metrics-server -n kube-system`) and that the pod has CPU/memory `requests` set in its Deployment spec.

---

## Reference: Container Images Used

File scan service image found in GHCR with following name

| Image Name | GHCR Path | Tag |
|---|---|---|
| dpn-file-scan-service | `ghcr.io/energy-dsi/dpn-file-scan-service` | `e.g. 1.0.0` |

Image access setup and the workflow trigger are covered in [Step3](#step3-execute-cicd) above — there is no separate GHCR-specific workflow to run, `dpn-file-scan-cd.yml` already deploys from this image by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
