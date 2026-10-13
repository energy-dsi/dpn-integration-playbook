# DPN File Scan Service Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Step1: Validate the Prerequisites](#step1-validate-the-prerequisites)
- [Step2: AWS Resource Setup (SNS/SQS/GuardDuty)](#step2-aws-resource-setup-snssqsguardduty)
- [Step3: Execute CI/CD](#step3-execute-cicd)
  - [Step3a. CI (component source repository)](#step3a-ci-component-source-repository)
  - [Step3b. Configure GHCR Image Access](#step3b-configure-ghcr-image-access)
  - [Step3c. Execute CD Workflow](#step3c-execute-cd-workflow)
  - [Step3d. Verify CD Workflow](#step3d-verify-cd-workflow)
  - [Step3e. Verify Scanning Service Execution](#step3e-verify-scanning-service-execution)
- [Step4: Troubleshooting](#step4-troubleshooting)
  - [No SQS Messages Ever Arrive](#no-sqs-messages-ever-arrive)
  - [AccessDenied on S3 Copy/Delete](#accessdenied-on-s3-copydelete)
  - [AccessDenied Reading Secrets Manager](#accessdenied-reading-secrets-manager)
  - [Files Disappear From Inbound But Never Appear Outbound](#files-disappear-from-inbound-but-never-appear-outbound)
  - [Messages Received But Not Deleted, Queue Backs Up](#messages-received-but-not-deleted-queue-backs-up)
- [Reference: Container Images Used](#reference-container-images-used)
- [Review Notes](#review-notes)

---

## Overview

This document describes the installation process for the DPN File Scanning Service on AWS, which inserts a malware-scanning gate in front of the existing DPN Data Pipeline Consumer Extractor. It depends on the DPN Data Pipeline already being installed, since it writes into the same inbound/outbound S3 buckets that component reads from. This path uses **Amazon GuardDuty Malware Protection for S3** with scan results delivered via an **SNS → SQS** fan-out.

---

## Step1: Validate the Prerequisites

The following prerequisites must be met.

- Amazon GuardDuty is enabled in the account/region, with a Malware Protection for S3 protection plan available to configure
- The source (inbound) and destination (outbound) S3 buckets are provisioned
- An EKS cluster reachable via the GitHub Actions OIDC federated credential (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role))
- Sufficient IAM permissions to create an SNS topic, an SQS queue, and an IRSA role for the service's ServiceAccount
- If sourcing `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` from AWS Secrets Manager (`secretsManager.enabled: true`), both secrets already exist under `secretsManager.secretPrefix`, and the IRSA role also grants `secretsmanager:GetSecretValue` on that prefix — see [Configure DPN File Scan Service, Step5](../02-configuration/08-configure-dpn-file-scan-service.md#step5-configure-secrets). When OTLP OAuth is enabled (`keyvault.otelOauthClientSecretName: KC_SERVICE_CLIENT_SECRET`, as in the provided AWS values files), `KC_SERVICE_CLIENT_SECRET` must also exist under that prefix
- The `dpn-tls` and `tls-auth-secret` Kubernetes secrets exist in the target namespace — both created by **DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1** (`dpn-tls-cd.yaml`)
- `.github/config/aws/<environment>-<cluster>.json` in the central `dpn-containerised-deployment-service` repository is populated, including the `FILESCAN_*` keys (see [Configure DPN File Scan Service, Step3a](../02-configuration/08-configure-dpn-file-scan-service.md#step3a-configure-environment-json-file))
- DPN Health monitoring service is up and running. OTEL log aggregator container is healthy

**Note:** Organisations must review the CI/CD workflow code for the following. 

- If running your own CI, keep only the relevant build, unit test, and image-push steps — DSI's own CI examples include tool usage such as CheckMarx, SonarQube, and JFrog Xray that your organisation may not need
- The container image is appropriate and referred from GHCR repository unless Organisation plans to use a separate image repository on their own
- The config JSON's environment parameters are pointing to correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- Both CI and CD are verified for the above prerequisites before execution

---

## Step2: AWS Resource Setup (SNS/SQS/GuardDuty)

**The SNS topic, SQS queue, and GuardDuty Malware Protection plan themselves must still be provisioned manually** — see [Configure DPN File Scan Service, Step2](../02-configuration/08-configure-dpn-file-scan-service.md#step2-aws-resource-setup-snssqsguardduty) for the exact commands. `dpn-file-scan-prerequisites-cd.yml` (**DPN CD - File Scan Prerequisites**) does have an AWS branch (`cloud: aws`), but it only creates the IRSA role and seeds the `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` Secrets Manager entries, and verifies the SNS/SQS/GuardDuty wiring — it does not create the SNS topic, SQS queue, or GuardDuty plan.

Once complete, validate:

- The SNS topic and SQS queue exist and the queue is subscribed to the topic
- The GuardDuty Malware Protection plan is active and covers the inbound bucket's upload prefix
- Optionally, run **Actions → DPN CD - File Scan Prerequisites → Run workflow** (`dpn-file-scan-prerequisites-cd.yml`) with `environment`, `cluster` and `cloud: aws` (leave the Azure-only inputs at their defaults and `serviceBusNamespace` blank) to have it verify this wiring, and to create the IRSA role and seed the Secrets Manager entries if you haven't already (see [Configure DPN File Scan Service, Step1](../02-configuration/08-configure-dpn-file-scan-service.md#step1-prepare-iam-role-for-the-service) and [Step5](../02-configuration/08-configure-dpn-file-scan-service.md#step5-configure-secrets))

---

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

Go to **Actions → DPN CD - File Scan Service → Run workflow**, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02` (default `dpn01`) |
| `cloud` | `aws` |
| `imageTag` | Required — the image tag from Step3a |

There is no image-repository input — the repository comes from `image.repository` in the values file (`ghcr.io/energy-dsi/1.0.1/dpn-file-scan-service`).

Workflow file: `.github/workflows/dpn-file-scan-cd.yml` in the central `dpn-containerised-deployment-service` repository. It loads `.github/config/aws/<environment>-<cluster>.json`, logs in via the `.github/actions/cloud-login` composite action, runs `helm lint` and a `--dry-run`, then `helm upgrade --install dpn-file-scan-service dpn-file-scan/charts/file-scan-service` with `dpn-file-scan/charts/file-scan-service/values/aws/<environment>-<cluster>.yaml` (no `--wait`; it polls `kubectl rollout status` up to 5 times instead), and finally publishes the deployed image digest as the `deployed-image-digest` workflow artifact.

To roll back, run **DPN Rollback - All Components Pipelines** (`dpn-rollback-all-components.yml`) with `releaseName: dpn-file-scan-service`; to remove it, run **DPN Uninstall - All components Pipelines** (`dpn-uninstall-all-components.yml`) with `componentType: file-scan-service`.

---

### Step3d. Verify CD Workflow

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begins. 

```bash
kubectl get pods -n <namespace> # check for dpn-file-scan-service-XXXXXXXXX
kubectl logs -f dpn-file-scan-service-XXXXXXXXX -n <namespace>
```
The kubectl logs should show `AWS SQS listener started.` and no `[error]` messages if the deployment is successful. 

---

### Step3e. Verify Scanning Service Execution

- Upload a clean test file into the inbound bucket and confirm it lands in the outbound bucket once GuardDuty completes its scan (scan time is asynchronous and outside this service's control)
- Verify a corresponding log entry in the OTEL aggregator is arrived on file scan
- Upload an [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) into the inbound bucket and confirm GuardDuty flags it and the service deletes it from the inbound bucket
- The malicious file should never appear in the outbound bucket
- The OTEL Collector logs the malicious-file event (`malicious_files` metric) appropriately

---

## Step4: Troubleshooting

### No SQS Messages Ever Arrive

GuardDuty Malware Protection plan not covering the upload prefix, or not wired to the SNS topic — check the protection plan's status and event destination in the GuardDuty console.

### AccessDenied on S3 Copy/Delete

IRSA role missing a required action, or bucket policy blocking access — confirm the role ARN is on the pod's ServiceAccount annotation and the IAM policy matches [Configure DPN File Scan Service, Step1](../02-configuration/08-configure-dpn-file-scan-service.md#step1-prepare-iam-role-for-the-service).

### AccessDenied Reading Secrets Manager

If the pod fails to start with a Secrets Store CSI mount error, confirm `secretsManager.secretPrefix` matches where `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` actually live, and that the IRSA role has `secretsmanager:GetSecretValue` scoped to that prefix (see [Configure DPN File Scan Service, Step5](../02-configuration/08-configure-dpn-file-scan-service.md#step5-configure-secrets)).

### Files Disappear From Inbound But Never Appear Outbound

`s3:PutObject` missing on the outbound bucket for the copy destination — add the permission and retry. GuardDuty does not re-scan, so re-drive by re-uploading the source object if it was already deleted.

### Messages Received But Not Deleted, Queue Backs Up

Exception during message processing before acknowledgement runs — check pod logs for the stack trace; the message becomes visible again after the queue's visibility timeout and is retried.

### HPA Not Scaling

If `kubectl get hpa` shows `<unknown>` under `TARGETS`, confirm metrics-server is running (`kubectl get deployment metrics-server -n kube-system`) and that the pod has CPU/memory `requests` set in its Deployment spec.

---

## Reference: Container Images Used

File scan service image found in GHCR with following name

| Image Name | GHCR Path | Tag |
|---|---|---|
| dpn-file-scan-service | `ghcr.io/energy-dsi/1.0.1/dpn-file-scan-service` | `e.g. 1.0.0` |

Image access setup and the workflow trigger are covered in [Step3](#step3-execute-cicd) above — there is no separate GHCR-specific workflow to run, `dpn-file-scan-cd.yml` already deploys from this image by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
