# DPN File Scan Service Configuration 

This section describes how to configure and deploy the **DPN File Scan Service** on AWS. Unlike the Azure deployment (which uses Microsoft Defender for Storage), the AWS path uses **Amazon GuardDuty Malware Protection for S3** to scan inbound files, and the service consumes GuardDuty's scan-result events from an **SNS → SQS** fan-out rather than polling a scan API directly.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Prepare IAM Role for the Service](#step1-prepare-iam-role-for-the-service)
- [Step2: AWS Resource Setup (SNS/SQS/GuardDuty)](#step2-aws-resource-setup-snssqsguardduty)
- [Step3: Configure File Scan Deployment Workflow](#step3-configure-file-scan-deployment-workflow)
  - [Step3a: Configure Environment JSON File](#step3a-configure-environment-json-file)
- [Step4: Configure Helm Chart Files](#step4-configure-helm-chart-files)
- [Step5: Configure Secrets](#step5-configure-secrets)
- [Review Notes](#review-notes)

---

## Overview

The DPN File Scan Service is a FastAPI application that runs as a single EKS Deployment. GuardDuty Malware Protection scans every object landed in the inbound ("raw"/quarantine) S3 bucket; on completion it publishes a scan-result event to an SNS topic, which fans out to an SQS queue the service long-polls. For files scanned clean, the service copies the object to the outbound ("stage") bucket and deletes it from the inbound bucket; for files flagged with threats, the object is deleted from inbound and a `malicious_files` metric is incremented.

**Deployment uses the pipeline; AWS resource setup does not — there's no workflow for that part yet.** `dpn-file-scan-cd.yml` in `dpn-containerised-deployment-service` deploys this service via Helm. But the Azure-only `dpn-file-scan-prerequisites-cd.yml` (which provisions Defender for Storage/Event Grid/Service Bus on the Azure side) has **no AWS counterpart** — the SNS/SQS/GuardDuty setup in [Step2](#step2-aws-resource-setup-snssqsguardduty) stays a required manual step regardless.

**CD Workflow**

| Workflow | File | Purpose |
|---|---|---|
| Main deploy | `.github/workflows/dpn-file-scan-cd.yml` | Builds nothing itself — deploys the already-built container image via Helm |

---

## Step1: Prepare IAM Role for the Service

The File Scan Service requires an IAM role (via IRSA — IAM Roles for Service Accounts) for its pod, granting only what it needs:

| Action | Resource | Purpose |
|---|---|---|
| `s3:GetObject`, `s3:CopyObject` (as source) | `<inbound-bucket>/*` | Read the scanned object to copy it out |
| `s3:PutObject` (as target of `CopyObject`) | `<outbound-bucket>/*` | Write the clean copy |
| `s3:DeleteObject` | `<inbound-bucket>/*` | Remove the object from inbound once handled |
| `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` | the scan-results SQS queue | Long-poll and acknowledge scan-result events |

No AWS access key/secret is configured directly — the container relies on the IRSA role attached to its ServiceAccount, falling back to boto3's default credential chain.

## Step2: AWS Resource Setup (SNS/SQS/GuardDuty)

Create the SNS topic and SQS queue GuardDuty publishes scan results to, and subscribe the queue to the topic:

```bash
TOPIC_ARN=$(aws sns create-topic --name dpn-fileupload-scan-results --query TopicArn --output text)

QUEUE_URL=$(aws sqs create-queue --queue-name dpn-fileupload-scan-results --query QueueUrl --output text)
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)

aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QUEUE_ARN"

# Allow SNS to publish to the queue
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes '{
  "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"'"$QUEUE_ARN"'\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"'"$TOPIC_ARN"'\"}}}]}"
}'
```

Then configure the GuardDuty Malware Protection for S3 protection plan (console or `aws guardduty create-malware-protection-plan`) to publish its scan-result events to `$TOPIC_ARN`, covering the inbound bucket's upload prefix.

> **Note:** Organisation must set up soft-delete/object retention on the malicious-object handling at the bucket/lifecycle level per your organisation's policy — the service itself does not enable bucket versioning or retention.

---

## Step3: Configure File Scan Deployment Workflow

Organisations should prepare a `.github/config/aws/<environment>-<cluster>.json` file per environment/cluster where the file scan service is deployed. This file will be read by the workflow during deployment.

```text
dpn-containerised-deployment-service/
└── .github/
    └── config/
        └── aws/
            └── <environment>-<cluster>.json
```

### Step3a: Configure Environment JSON File

| Key | Purpose | Example (`dev-dpn01`) |
|---|---|---|
| `AWS_REGION` | Region the S3/SNS/SQS resources live in | `eu-west-2` |
| `AWS_ACCOUNT_ID` | AWS account ID | `<account-id>` |
| `EKS_CLUSTER` | EKS cluster name | `eks-dpn-dev-eu-west-2` |
| `NAMESPACE` | Target namespace | `ns-dpn-01` |
| `IMAGE_REGISTRY` | Base registry URL | `ghcr.io` |
| `KEY_VAULT_NAME` | Azure Key Vault holding cross-cloud secrets (see [Step5](#step5-configure-secrets)) | `kv-dpn-<env>-<region>-<seq>` |
| `FILESCAN_INBOUND_BUCKET` | S3 bucket GuardDuty scans | `<inbound-bucket>` |
| `FILESCAN_OUTBOUND_BUCKET` | S3 bucket clean files are copied to | `<outbound-bucket>` |
| `FILESCAN_SQS_QUEUE_URL` | The queue URL from [Step2](#step2-aws-resource-setup-snssqsguardduty) | `https://sqs.<region>.amazonaws.com/<account-id>/dpn-fileupload-scan-results` |
| `FILESCAN_SNS_TOPIC_ARN` | The topic ARN from [Step2](#step2-aws-resource-setup-snssqsguardduty) | `arn:aws:sns:<region>:<account-id>:dpn-fileupload-scan-results` |
| `FILESCAN_IRSA_ROLE_ARN` | ARN of the IAM role granting the S3/SQS permissions above | `arn:aws:iam::<account-id>:role/dpn-file-scan-irsa` |
| OTEL_EXPORTER_OTLP_ENDPOINT | OTel collector's OTLP endpoint. Defaults to the HTTPS endpoint on port `4318` | `https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` |

---

## Step4: Configure Helm Chart Files

Set the parameters below in your environment/cluster's values file. The CD workflow resolves `values/aws/<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
dpn-file-scan/
  └── charts/
        └── file-scan-service/
              ├── values.yaml                              <- Reference file; do not edit directly
              └── values/aws/<environment>-<cluster>.yaml <- Your environment overrides
```

The following values to be modified in that file

| Item | Value |
|---|---|
| image:repository | `ghcr.io/energy-dsi/dpn-file-scan-service` |
| image:tag | Image tag to deploy |
| serviceAccount.irsaRoleArn | ARN of the IRSA role from [Step1](#step1-prepare-iam-role-for-the-service) |
| region | AWS region the S3/SQS resources live in |
| inboundBucket | S3 bucket GuardDuty scans |
| outboundBucket | S3 bucket clean files are copied to |
| sqsQueueUrl | The queue URL from [Step2](#step2-aws-resource-setup-snssqsguardduty) |
| snsTopicArn | The topic ARN from [Step2](#step2-aws-resource-setup-snssqsguardduty) |

---

## Step5: Configure Secrets

Unlike the Azure path, this service does not need Key Vault-sourced AWS credentials — the IRSA role attached to its ServiceAccount ([Step1](#step1-prepare-iam-role-for-the-service)) covers all S3/SQS access. `KEY_VAULT_NAME` is still referenced in the config JSON for other cross-cloud secrets the chart's OTel/observability wiring may need (see [Configure DPN Health Monitoring](02-configure-dpn-health-mon-service.md)) — no File Scan Service-specific secret needs to be created there.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
