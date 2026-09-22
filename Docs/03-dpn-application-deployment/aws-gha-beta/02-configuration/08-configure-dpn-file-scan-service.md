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

**Deployment and part of the AWS prerequisite setup both use pipelines.** `dpn-file-scan-cd.yml` in `dpn-containerised-deployment-service` deploys this service via Helm. `dpn-file-scan-prerequisites-cd.yml` also runs on `cloud: aws`: it creates the IRSA role (`dpn-file-scan-service-secrets-role`) and seeds the two Secrets Manager entries (`FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET`, with a `REPLACE_ME` placeholder value on first creation) and verifies the SNS→SQS→GuardDuty wiring — but it does **not** create the SNS topic, SQS queue, or GuardDuty Malware Protection plan themselves. The SNS/SQS/GuardDuty setup in [Step2](#step2-aws-resource-setup-snssqsguardduty) stays a required manual step regardless.

**CD Workflow**

| Workflow | File | Purpose |
|---|---|---|
| Main deploy | `.github/workflows/dpn-file-scan-cd.yml` | Builds nothing itself — deploys the already-built container image via Helm |
| Prerequisites | `.github/workflows/dpn-file-scan-prerequisites-cd.yml` | On `cloud: aws`, creates the IRSA role and seeds the Secrets Manager entries above, and verifies (but does not create) the SNS/SQS/GuardDuty wiring |

---

## Step1: Prepare IAM Role for the Service

The File Scan Service requires an IAM role (via IRSA — IAM Roles for Service Accounts) for its pod, granting only what it needs:

| Action | Resource | Purpose |
|---|---|---|
| `s3:GetObject`, `s3:CopyObject` (as source) | `<inbound-bucket>/*` | Read the scanned object to copy it out |
| `s3:PutObject` (as target of `CopyObject`) | `<outbound-bucket>/*` | Write the clean copy |
| `s3:DeleteObject` | `<inbound-bucket>/*` | Remove the object from inbound once handled |
| `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` | the scan-results SQS queue | Long-poll and acknowledge scan-result events |
| `secretsmanager:GetSecretValue` | `arn:aws:secretsmanager:<region>:<account-id>:secret:<secretPrefix>/*` | Only required when `secretsManager.enabled: true` (see [Step5](#step5-configure-secrets)) — lets the AWS Secrets Store CSI driver read `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` for this ServiceAccount |

No AWS access key/secret is configured directly — the container relies on the IRSA role attached to its ServiceAccount, falling back to boto3's default credential chain.

> **Note:** `dpn-file-scan-prerequisites-cd.yml` (run with `cloud: aws`) can create this role for you — idempotently, under the fixed name `dpn-file-scan-service-secrets-role` — with the trust policy and permissions above already attached. Set `serviceAccount.irsaRoleArn` in [Step4](#step4-configure-helm-chart-files) to the resulting ARN either way.

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

> **Note:** Once this is provisioned, `dpn-file-scan-prerequisites-cd.yml` (run with `cloud: aws`) can verify the topic, subscription, queue policy, and GuardDuty detector/plan against the `FILESCAN_SNS_TOPIC_NAME`/`FILESCAN_SQS_QUEUE_NAME` values in the config JSON below — it only checks this wiring, it does not create it.

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
| `EKS_CLUSTER` | EKS cluster name | `eks-dpn-dev-01-eu-west-2` |
| `NAMESPACE` | Target namespace | `ns-dpn-01` |
| `IMAGE_REGISTRY` | Base registry URL | `ghcr.io/energy-dsi/1.0.1` |
| `FILESCAN_SOURCE_BUCKET` | S3 bucket GuardDuty scans (source/raw uploads) | `dp-consumer-raw-dev-01-<account-id>-<region>` |
| `FILESCAN_DEST_BUCKET` | S3 bucket clean files are copied to | `dpn-dev-01-dp-consumer-stage-<account-id>-<region>` |
| `FILESCAN_SNS_TOPIC_NAME` | The SNS topic name from [Step2](#step2-aws-resource-setup-snssqsguardduty) — a **name**, not an ARN; the chart derives the ARN itself | `dpn-dev-01-guardduty-findings2` |
| `FILESCAN_SQS_QUEUE_NAME` | The SQS queue name from [Step2](#step2-aws-resource-setup-snssqsguardduty) — a **name**, not a URL | `dpn-dev-01-file-scan-results2` |

> **No `KEY_VAULT_NAME` or IRSA-role-ARN key in this JSON file.** The IAM permissions come entirely from the IRSA role already attached to the ServiceAccount ([Step1](#step1-prepare-iam-role-for-the-service)), which this config file does not need to reference — there is no `FILESCAN_IRSA_ROLE_ARN`-style key. This component's real AWS config file also carries no `KEY_VAULT_NAME` entry at all: nothing in its GitHub Actions workflow reads one.
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
| serviceAccount.create | Whether to create the IRSA ServiceAccount — set `true` on AWS | `true` |
| serviceAccount.name | ServiceAccount name, also set as the Deployment's `serviceAccountName` | `dpn-file-scan-service` |
| serviceAccount.irsaRoleArn | ARN of the IRSA role from [Step1](#step1-prepare-iam-role-for-the-service) |
| env.awsRegion | AWS region the S3/SQS resources live in |
| env.sourceBucket | S3 bucket GuardDuty scans (inbound). Passed to the container as `S3_BUCKET_INBOUND` |
| env.destBucket | S3 bucket clean files are copied to (outbound). Passed to the container as `S3_BUCKET_OUTBOUND` |
| env.sqsQueueName | The **plain queue name** (not the queue URL) from [Step2](#step2-aws-resource-setup-snssqsguardduty) — the app resolves the URL itself via `boto3`'s `get_queue_url`. Passed to the container as `SQS_QUEUE` |

> **Note:** there is no Helm value for the SNS topic ARN — the app only ever consumes from SQS; the SNS→SQS fan-out from [Step2](#step2-aws-resource-setup-snssqsguardduty) is wiring set up outside the application. `env.awsRegion`/`env.sourceBucket`/`env.destBucket`/`env.sqsQueueName` are AWS-only fields alongside the shared `env.*` block — leave them empty (their default) on Azure.
>
> Optionally, `env.truststorePath` gates whether the chart mounts the `dpn-tls` OTLP truststore volume at all — leave it unset for an environment with no `dpn-tls` secret provisioned.

---

## Step5: Configure Secrets

Unlike the Azure path, this service does not need Key Vault-sourced AWS credentials — the IRSA role attached to its ServiceAccount ([Step1](#step1-prepare-iam-role-for-the-service)) covers all S3/SQS access, and the config JSON carries no `KEY_VAULT_NAME` entry at all on this path (see the note under [Step3a](#step3a-configure-environment-json-file)).

The service's OAuth client credentials (`FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` — the same pair Azure sources from Key Vault) can now be sourced from **AWS Secrets Manager** instead, via the AWS Secrets Store CSI driver:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| secretsManager.enabled | Use the AWS Secrets Store CSI driver instead of Key Vault | `true` |
| secretsManager.secretPrefix | Secrets Manager path prefix holding `FILESCAN_CLIENT_ID` and `FILESCAN_CLIENT_SECRET` | `dpn/<environment>-<cluster>/file-scan-service` |

When `secretsManager.enabled: true`, both `FILESCAN_CLIENT_ID` and `FILESCAN_CLIENT_SECRET` must already exist under `secretsManager.secretPrefix` before the first deploy, and the IRSA role from [Step1](#step1-prepare-iam-role-for-the-service) must additionally grant `secretsmanager:GetSecretValue` on that prefix. Leave `secretsManager.enabled: false` (the default) for an environment that isn't provisioned for this yet.

> **Note:** `dpn-file-scan-prerequisites-cd.yml` (run with `cloud: aws`) can create both Secrets Manager entries for you if they don't already exist — it seeds each with a `REPLACE_ME` placeholder value, which must be updated with the real credential before the service relies on it. It leaves an existing secret's value untouched.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
