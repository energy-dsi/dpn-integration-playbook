# DPN File Scan Service Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Step1: Validate the Prerequisites](#step1-validate-the-prerequisites)
- [Step2: Azure Resource Setup (Service Bus/Event Grid/Defender for Storage)](#step2-azure-resource-setup-service-buseventgriddefender-for-storage)
- [Step3: Execute CI/CD](#step3-execute-cicd)
  - [Step3a. Configure GHCR Image Access](#step3a-configure-ghcr-image-access)
  - [Step3b. Execute CD Workflow](#step3b-execute-cd-workflow)
  - [Step3c. Verify CD Workflow](#step3c-verify-cd-workflow)
  - [Step3d. Verify Scanning Service Execution](#step3d-verify-scanning-service-execution)
- [Step4: Troubleshooting](#step4-troubleshooting)
  - [No Service Bus Messages Ever Arrive](#no-service-bus-messages-ever-arrive)
  - [AccessDenied on Blob Copy/Delete](#accessdenied-on-blob-copydelete)
  - [AccessDenied Reading Key Vault](#accessdenied-reading-key-vault)
  - [Files Disappear From Inbound But Never Appear Outbound](#files-disappear-from-inbound-but-never-appear-outbound)
  - [Messages Received But Not Deleted, Queue Backs Up](#messages-received-but-not-deleted-queue-backs-up)
  - [HPA Not Scaling](#hpa-not-scaling)
- [Reference: Container Images Used](#reference-container-images-used)
- [Review Notes](#review-notes)

---

## Overview

This document describes the installation process for the DPN File Scanning Service on Azure, which inserts a malware-scanning gate in front of the existing DPN Data Pipeline Consumer Extractor. It depends on the DPN Data Pipeline already being installed, since it writes into the same inbound/outbound Storage Account containers that component reads from. This path uses **Microsoft Defender for Storage malware scanning** with scan results delivered via an **Event Grid → Service Bus** fan-out.

---

## Step1: Validate the Prerequisites

The following prerequisites must be met.

- Microsoft Defender for Storage is available to enable on the target Storage Account, with an Event Grid custom topic available to receive its malware-scan verdicts
- The source (inbound) and destination (outbound) containers on the Storage Account (`FILESCAN_STORAGE_ACCOUNT`, resource group `FILESCAN_STORAGE_RG`) are provisioned
- An AKS cluster reachable via the GitHub Actions OIDC federated credential (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#azure-ad-oidc-federated-credential))
- Sufficient Azure permissions to create a Service Bus topic/subscription, an Event Grid topic/event subscription, the related role assignment, and the workload identity for the service's ServiceAccount
- If sourcing `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` from Azure Key Vault (`secretsManager.enabled: true`), both secrets already exist in `KEY_VAULT_NAME`, and the service's workload identity also has `get` permission on that Key Vault's secrets — see [Configure DPN File Scan Service, Step5](../02-configuration/08-configure-dpn-file-scan-service.md#step5-configure-secrets)
- DPN Health monitoring service is up and running. OTEL log aggregator container is healthy

**Note:** Organisations must review the workflow code for the following. 

- The container image is appropriate and referred from GHCR repository unless Organisation plans to use a separate image repository on their own
- The config JSON's environment parameters are pointing to correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- The CD workflow is verified for the above prerequisites before execution

---

## Step2: Azure Resource Setup (Service Bus/Event Grid/Defender for Storage)

**`dpn-gha-file-scan-prerequisites-cd.yaml` provisions the full Azure wiring in one run** — see [Configure DPN File Scan Service, Step2](../02-configuration/08-configure-dpn-file-scan-service.md#step2-azure-resource-setup-service-buseventgriddefender-for-storage) for the exact commands. With `cloud: azure` it:

- creates the Service Bus topic/subscription (`FILESCAN_SB_SUBSCRIPTION_NAME`) if not already present
- enables Defender for Storage malware scanning (on-upload) on `FILESCAN_STORAGE_ACCOUNT`, wired to the Event Grid custom topic
- enables that Event Grid topic's system-assigned identity and grants it **Azure Service Bus Data Sender** on the Service Bus topic
- creates the Event Grid → Service Bus event subscription (`FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME`) and verifies it
- creates the raw (inbound) storage container if it does not already exist

Once complete, validate:

- The Service Bus topic and subscription exist (`FILESCAN_SB_SUBSCRIPTION_NAME`)
- Defender for Storage malware scanning is enabled on `FILESCAN_STORAGE_ACCOUNT` and its scan-results Event Grid topic is wired to the Service Bus topic via `FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME`
- Run `dpn-gha-file-scan-prerequisites-cd.yml` with `cloud: azure` to (re-)provision and verify this wiring, and to create the workload identity and seed the Key Vault entries if you haven't already (see [Configure DPN File Scan Service, Step1](../02-configuration/08-configure-dpn-file-scan-service.md#step1-prepare-identity-for-the-service) and [Step5](../02-configuration/08-configure-dpn-file-scan-service.md#step5-configure-secrets))

---

## Step3: Execute CI/CD

### Step3a. Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`. Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably.

Create a GitHub Personal Access Token with `read:packages` scope, then create a Kubernetes secret from it:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

### Step3b. Execute CD Workflow

Go to following CD pipeline:

```text
root/
└── .pipelines/
  └── github-actions-pipelines/
      └── workflows/
          └── dpn-gha-file-scan-cd.yaml
```
Provide the runtime parameters:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `imageTag` | The image tag from Step3a |
| `imageRepository` | Optional. Image path after `ghcr.io/energy-dsi/` (e.g. `dpn-file-scan-service`) — leave blank to use the environment's configured repository |

---

### Step3c. Verify CD Workflow

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begins. 

```bash
kubectl get pods -n <namespace> # check for dpn-file-scan-service-XXXXXXXXX
kubectl logs -f dpn-file-scan-service-XXXXXXXXX
```
The kubectl logs should show the Service Bus listener starting up and no `[error]` messages if the deployment is successful. 

---

### Step3d. Verify Scanning Service Execution

- Upload a clean test file into the inbound container and confirm it lands in the outbound container once Defender for Storage completes its scan (scan time is asynchronous and outside this service's control)
- Verify a corresponding log entry in the OTEL aggregator is arrived on file scan
- Upload an [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) into the inbound container and confirm Defender for Storage flags it and the service deletes it from the inbound container
- The malicious file should never appear in the outbound container
- The OTEL Collector logs the malicious-file event (`malicious_files` metric) appropriately

---

## Step4: Troubleshooting

### No Service Bus Messages Ever Arrive

Defender for Storage malware scanning not enabled/covering the upload prefix on `FILESCAN_STORAGE_ACCOUNT`, or the Event Grid custom topic's event subscription not wired to the Service Bus topic — check the Defender for Storage settings (`DefenderForStorageSettings`) and the Event Grid → Service Bus event subscription (`FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME`) status in the Azure Portal/CLI.

### AccessDenied on Blob Copy/Delete

Workload identity missing a required role assignment (e.g. Storage Blob Data Contributor), or a container access policy blocking access — confirm the identity federated to the pod's ServiceAccount and the role assignment matches [Configure DPN File Scan Service, Step1](../02-configuration/08-configure-dpn-file-scan-service.md#step1-prepare-identity-for-the-service).

### AccessDenied Reading Key Vault

If the pod fails to start with a Secrets Store CSI mount error, confirm `KEY_VAULT_NAME` matches where `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` actually live, and that the service's workload identity has `get` permission on that Key Vault's secrets (see [Configure DPN File Scan Service, Step5](../02-configuration/08-configure-dpn-file-scan-service.md#step5-configure-secrets)).

### Files Disappear From Inbound But Never Appear Outbound

Blob write permission missing on the outbound container for the copy destination — add the permission and retry. Defender for Storage does not re-scan, so re-drive by re-uploading the source object if it was already deleted.

### Messages Received But Not Deleted, Queue Backs Up

Exception during message processing before the message is completed/acknowledged — check pod logs for the stack trace; the message becomes available again after the Service Bus subscription's lock duration expires and is retried.

### HPA Not Scaling

If `kubectl get hpa` shows `<unknown>` under `TARGETS`, confirm metrics-server is running (`kubectl get deployment metrics-server -n kube-system`) and that the pod has CPU/memory `requests` set in its Deployment spec.

---

## Reference: Container Images Used

File scan service image found in GHCR with following name

| Image Name | GHCR Path | Tag |
|---|---|---|
| dpn-file-scan-service | `ghcr.io/energy-dsi/dpn-file-scan-service` | `e.g. 2.0.0` |

Image access setup and the workflow trigger are covered in [Step3](#step3-execute-cicd) above — there is no separate GHCR-specific workflow to run, `dpn-gha-file-scan-cd.yml` already deploys from this image by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
