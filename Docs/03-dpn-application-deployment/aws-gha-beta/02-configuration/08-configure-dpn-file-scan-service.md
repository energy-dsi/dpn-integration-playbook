# DPN File Scan Service Configuration 

This section describes how to configure and deploy the **DPN File Scan Service** on AWS. The AWS path uses **Amazon GuardDuty Malware Protection for S3** to scan inbound files, and the service consumes GuardDuty's scan-result events from an **SNS → SQS** fan-out rather than polling a scan API directly.

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

**Deployment and part of the AWS prerequisite setup both use pipelines.** `dpn-gha-file-scan-cd.yml`  deploys this service via Helm. `dpn-gha-file-scan-prerequisites-cd.yml` also runs on `cloud: aws`: it creates the IRSA role (`dpn-file-scan-service-secrets-role`) and seeds the two Secrets Manager entries (`FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET`, with a `REPLACE_ME` placeholder value on first creation) and verifies the SNS→SQS→GuardDuty wiring — but it does **not** create the SNS topic, SQS queue, or GuardDuty Malware Protection plan themselves. The SNS/SQS/GuardDuty setup in [Step2](#step2-aws-resource-setup-snssqsguardduty) stays a required manual step regardless.

**CD Workflow**

Both workflows, and the service's Helm chart:

| Workflow | Display name | File | Purpose |
|---|---|---|---|
| Main deploy | **DPN CD - File Scan Service** | `.github/workflows/dpn-gha-file-scan-cd.yml` | Builds nothing itself — deploys the already-built container image via Helm (release `dpn-file-scan-service`, chart `dpn-file-scan/charts/file-scan-service`) |
| Prerequisites | **DPN CD - File Scan Prerequisites** | `.github/workflows/dpn-gha-file-scan-prerequisites-cd.yml` | On `cloud: aws`, creates the IRSA role and seeds the Secrets Manager entries above, and verifies (but does not create) the SNS/SQS/GuardDuty wiring |

Both take the `environment` (`dev`/`test`, default `test`), `cluster` (`dpn01`/`dpn02`, default `dpn01`) and `cloud` (default `aws`) inputs, run under the GitHub Environment `<environment>-<cluster>`, and log in through the `.github/actions/cloud-login` composite action. The prerequisites workflow's remaining inputs (`containerName`, `serviceBusNamespace`, `serviceBusResourceGroup`, `serviceBusTopicName`, `eventGridResourceGroup`, `eventGridTopicResourceGroup`, `eventGridCustomTopicName`) are Azure-only — leave them at their defaults (and `serviceBusNamespace` blank) for `cloud: aws`.

---

## Step1: Prepare IAM Role for the Service

The File Scan Service requires an IAM role (via IRSA — IAM Roles for Service Accounts) for its pod, granting only what it needs:

| Action | Resource | Purpose |
|---|---|---|
| `s3:GetObject`, `s3:GetObjectTagging`, `s3:DeleteObject`, `s3:ListBucket` | `<inbound-bucket>` and `<inbound-bucket>/*` | Read the scanned object (and its GuardDuty scan-result tag) to copy it out, then remove it from inbound once handled |
| `s3:GetObject`, `s3:PutObject`, `s3:PutObjectTagging`, `s3:ListBucket` | `<outbound-bucket>` and `<outbound-bucket>/*` | Write the clean copy |
| `sqs:GetQueueUrl`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` | the scan-results SQS queue | Resolve the queue URL, long-poll and acknowledge scan-result events |
| `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` | `arn:aws:secretsmanager:<region>:<account-id>:secret:dpn/<environment>-<cluster>/file-scan-service/*` | Lets the AWS Secrets Store CSI driver read `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` (and `KC_SERVICE_CLIENT_SECRET`, see [Step5](#step5-configure-secrets)) for this ServiceAccount |

The role's trust policy must allow `sts:AssumeRoleWithWebIdentity` from the EKS cluster's OIDC provider, scoped to `system:serviceaccount:<namespace>:dpn-file-scan-service`.

No AWS access key/secret is configured directly — the container relies on the IRSA role attached to its ServiceAccount, falling back to boto3's default credential chain.

> **Note:** `dpn-gha-file-scan-prerequisites-cd.yml` (run with `cloud: aws`) can create this role for you — idempotently, under the fixed name `dpn-file-scan-service-secrets-role`, with the inline policy `dpn-file-scan-service-permissions` — with the trust policy and permissions above already attached (bucket and queue names come from `FILESCAN_SOURCE_BUCKET`, `FILESCAN_DEST_BUCKET` and `FILESCAN_SQS_QUEUE_NAME` in the config JSON). On re-run it updates the trust policy and permissions of the existing role. Set `serviceAccount.irsaRoleArn` in [Step4](#step4-configure-helm-chart-files) to the resulting ARN (printed at the end of the step) either way.

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

> **Note:** Once this is provisioned, `dpn-gha-file-scan-prerequisites-cd.yml` (run with `cloud: aws`) can verify the topic, subscription, queue policy, and GuardDuty detector/plan against the `FILESCAN_SNS_TOPIC_NAME`/`FILESCAN_SQS_QUEUE_NAME` values in the config JSON below — it only checks this wiring, it does not create it. Its "Verify SNS Topic and Subscription" step fails if there is no **confirmed** subscription from the topic to the queue; the GuardDuty step only reports the Malware Protection plans and does not fail on their content.

---

## Step3: Configure File Scan Deployment Workflow

Organisations should prepare a `.github/config/aws/<environment>-<cluster>.json` file per environment/cluster where the file scan service is deployed. Both workflows read this file (`PARAMETERS_FILE`) and export every key into the job environment.

```text
.pipelines/
└── .github-actions-pipelines/
    └── config/
        └── aws/
            └── <environment>-<cluster>.json     # e.g. dev-dpn01.json
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

> The four `FILESCAN_*` keys are used only by `dpn-gha-file-scan-prerequisites-cd.yml` (its "Validate Required Values (AWS)" step fails if any is empty). The deploy workflow `dpn-gha-file-scan-cd.yml` uses `AWS_REGION`, `AWS_ACCOUNT_ID`, `EKS_CLUSTER` and `NAMESPACE`; the bucket and queue names the running service uses come from the Helm values file ([Step4](#step4-configure-helm-chart-files)), so keep the two in sync.

> **No `KEY_VAULT_NAME` or IRSA-role-ARN key in this JSON file.** The IAM permissions come entirely from the IRSA role already attached to the ServiceAccount ([Step1](#step1-prepare-iam-role-for-the-service)), which this config file does not need to reference — there is no `FILESCAN_IRSA_ROLE_ARN`-style key. This component's real AWS config file also carries no `KEY_VAULT_NAME` entry at all: nothing in its GitHub Actions workflow reads one.

---

## Step4: Configure Helm Chart Files

Set the parameters below in your environment/cluster's values file. The CD workflow sets `CHART_LOCATION=dpn-file-scan/charts/file-scan-service` and resolves `VALUES_FILE=dpn-file-scan/charts/file-scan-service/values/aws/<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
.pipelines/
└── .github-actions-pipelines/
  └── charts/
        └── file-scan-service/
              ├── values.yaml                              <- Reference file; do not edit directly
              └── values/aws/<environment>-<cluster>.yaml <- Your environment overrides
```

The following values to be modified in that file

| Item | Value |
|---|---|
| cloudProvider | Must be `aws` (the chart default is `azure`) — selects the AWS SecretProviderClass and the AWS-only environment variables below |
| image:repository | `ghcr.io/energy-dsi/1.0.1/dpn-file-scan-service` |
| image:tag | Leave `""` — the workflow sets it from its required `imageTag` input (`--set image.tag=<imageTag>`); the workflow also sets `namespace` from `NAMESPACE` in the config JSON |
| serviceAccount.create | Whether to create the IRSA ServiceAccount — set `true` on AWS | `true` |
| serviceAccount.name | ServiceAccount name, also set as the Deployment's `serviceAccountName` | `dpn-file-scan-service` |
| serviceAccount.irsaRoleArn | ARN of the IRSA role from [Step1](#step1-prepare-iam-role-for-the-service) |
| env.awsRegion | AWS region the S3/SQS resources live in |
| env.sourceBucket | S3 bucket GuardDuty scans (inbound). Passed to the container as `S3_BUCKET_INBOUND` |
| env.destBucket | S3 bucket clean files are copied to (outbound). Passed to the container as `S3_BUCKET_OUTBOUND` |
| env.sqsQueueName | The **plain queue name** (not the queue URL) from [Step2](#step2-aws-resource-setup-snssqsguardduty) — the app resolves the URL itself via `boto3`'s `get_queue_url`. Passed to the container as `SQS_QUEUE` |
| env.cloudprovidertype | `AWS`. Passed to the container as `CLOUD_PROVIDER_TYPE` |
| env.otelEndpoint | OTel collector's OTLP endpoint (passed as `OTEL_EXPORTER_OTLP_ENDPOINT`), e.g. `https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` |
| env.otelOauthTokenEndpointUrl | Keycloak token endpoint used to authenticate OTLP exports as `dpn-service-client`, e.g. `https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| keyvault.otelOauthClientSecretName | Set to `KC_SERVICE_CLIENT_SECRET` (as in the provided AWS values files) to mount `dpn-service-client`'s secret from `secretsManager.secretPrefix/KC_SERVICE_CLIENT_SECRET`; leave empty to disable OTLP OAuth |

> Optionally, `env.truststorePath` gates whether the chart mounts the `dpn-tls` OTLP truststore volume at all — leave it unset for an environment with no `dpn-tls` secret provisioned. The provided AWS values files set it (and `env.otelExporterCertificate`) to `/etc/secrets/truststore.jks`. Independently of this, the Deployment always reads `TRUSTSTORE_PASSWORD` from the shared `tls-auth-secret` (key `TRUSTSTORE_PASSWORD`), created by **DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1** (`dpn-gha-tls-cd.yaml`), so that secret must exist in the namespace.

---

## Step5: Configure Secrets

The service's OAuth client credentials can now be sourced from **AWS Secrets Manager** instead, via the AWS Secrets Store CSI driver:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| secretsManager.enabled | Use the AWS Secrets Store CSI driver instead of Key Vault | `true` |
| secretsManager.secretPrefix | Secrets Manager path prefix holding `FILESCAN_CLIENT_ID` and `FILESCAN_CLIENT_SECRET` | `dpn/<environment>-<cluster>/file-scan-service` |

When `secretsManager.enabled: true`, both `FILESCAN_CLIENT_ID` and `FILESCAN_CLIENT_SECRET` must already exist under `secretsManager.secretPrefix` before the first deploy, and the IRSA role from [Step1](#step1-prepare-iam-role-for-the-service) must additionally grant `secretsmanager:GetSecretValue` on that prefix. When `keyvault.otelOauthClientSecretName` is set, `KC_SERVICE_CLIENT_SECRET` (the same `dpn-service-client` value held under `dpn/<environment>-<cluster>/keycloak/`) must also exist under this prefix; the CSI driver syncs it into the `dpn-file-scan-service-otel-truststore` secret (key `oauth-client-secret`) for `OTEL_OAUTH_CLIENT_SECRET`. All provided AWS values files set `secretsManager.enabled: true`; the Deployment always mounts the `dpn-file-scan-service-kv-secrets` SecretProviderClass, which on `cloudProvider: aws` is only rendered when `secretsManager.enabled: true`, so do not leave it at the chart default `false` on AWS.

> **Note:** `dpn-gha-file-scan-prerequisites-cd.yml` (run with `cloud: aws`) can create both `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` entries under `dpn/<environment>-<cluster>/file-scan-service/` for you if they don't already exist — it seeds each with a `REPLACE_ME` placeholder value, which must be updated with the real credential before the service relies on it. It leaves an existing secret's value untouched. It does **not** create `KC_SERVICE_CLIENT_SECRET` under that prefix — create that one manually.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
