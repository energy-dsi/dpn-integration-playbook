# 05 — File Scan Service (AWS, GuardDuty Malware Protection)

Deploys the **DPN File Scan Service** on AWS. Unlike the Azure deployment (which uses Microsoft Defender for Storage), the AWS path uses **Amazon GuardDuty Malware Protection for S3** to scan inbound files, and the service consumes GuardDuty's scan-result events from an **SNS → SQS** fan-out rather than polling a scan API directly.

Apply `00-shared-prerequisites` before this component.

### Files in this folder

| File | Contents |
|---|---|
| `manifests/01-file-scan-service.yaml` | ConfigMap, Deployment, Service |

---

## 1. How it works

1. GuardDuty Malware Protection scans every object landed in the inbound ("raw"/quarantine) S3 bucket.
2. On completion, GuardDuty publishes a scan-result event (`scanStatus`, `scanResultDetails.scanResultStatus`) to an SNS topic, which fans out to an SQS queue.
3. The service long-polls that SQS queue. For each message:
   - `NO_THREATS_FOUND` → the object is copied to the outbound ("stage") bucket and deleted from the inbound bucket.
   - `THREATS_FOUND` → the object is deleted from the inbound bucket (a quarantine-copy code path exists but is not enabled by default) and a `malicious_files` metric is incremented.
4. `GET /health` reports liveness; the service exposes no scan-triggering endpoint of its own — GuardDuty scans automatically on object upload.

---

## 2. Prerequisites

- `00-shared-prerequisites` applied.
- An S3 bucket organisations scan inbound files into (referred to below as `<inbound-bucket>`), and a destination bucket for clean files (`<outbound-bucket>`).
- **Amazon GuardDuty enabled** in the account/region, with a **Malware Protection for S3** protection plan covering `<inbound-bucket>`. GuardDuty's own console/CLI walks you through this — the object prefix you choose to protect should match where producers land files.
- **soft delete / object retention on the malicious-object handling** should be decided at the bucket/lifecycle level per your organisation's policy — the service itself does not enable bucket versioning or retention.
- An IAM role (via IRSA — IAM Roles for Service Accounts) for the pod, granting only what the service needs:

| Action | Resource | Purpose |
|---|---|---|
| `s3:GetObject`, `s3:CopyObject` (as source) | `<inbound-bucket>/*` | Read the scanned object to copy it out |
| `s3:PutObject` (as target of `CopyObject`) | `<outbound-bucket>/*` | Write the clean copy |
| `s3:DeleteObject` | `<inbound-bucket>/*` | Remove the object from inbound once handled |
| `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` | the scan-results SQS queue | Long-poll and acknowledge scan-result events |

## 3. AWS resource setup

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

Then configure the GuardDuty Malware Protection for S3 protection plan (console or `aws guardduty create-malware-protection-plan`) to publish its scan-result events to `$TOPIC_ARN`.

## 4. Configuration

Edit `manifests/01-file-scan-service.yaml` and fill in these placeholders before applying:

| Placeholder | What it is |
|---|---|
| `<AWS_REGION>` | Region the S3/SNS/SQS resources live in, e.g. `eu-west-2` |
| `<INBOUND_BUCKET>` | S3 bucket GuardDuty scans (`S3_BUCKET_INBOUND`) |
| `<OUTBOUND_BUCKET>` | S3 bucket clean files are copied to (`S3_BUCKET_OUTBOUND`) |
| `<SQS_QUEUE_URL>` | The queue URL from Step 3 (`SQS_QUEUE`) |
| `<SNS_TOPIC_ARN>` | The topic ARN from Step 3 (`SNS_TOPIC`) |
| `<IRSA_ROLE_ARN>` | ARN of the IAM role granting the S3/SQS permissions above |

No AWS access key/secret is configured directly — the container relies on the IRSA role attached to its ServiceAccount, falling back to boto3's default credential chain.

## 5. Installation

```bash
kubectl apply -f manifests/01-file-scan-service.yaml
kubectl rollout status deployment/dpn-file-scan-service -n ns-dpn-01
```

### Healthcheck

```bash
kubectl get pods -n ns-dpn-01 -l app=dpn-file-scan-service
kubectl logs -n ns-dpn-01 -l app=dpn-file-scan-service --tail=100
```

**Healthy:** pod `Running 1/1`; logs show `AWS SQS listener started.`; uploading a clean test file to `<inbound-bucket>` results in it appearing in `<outbound-bucket>` and disappearing from `<inbound-bucket>` once GuardDuty completes its scan (scan time is asynchronous and outside this service's control).

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No SQS messages ever arrive | GuardDuty Malware Protection plan not covering the upload prefix, or not wired to the SNS topic | Check the protection plan's status and event destination in the GuardDuty console |
| `AccessDenied` on S3 copy/delete | IRSA role missing a required action, or bucket policy blocking cross-account access | Confirm the role ARN is on the pod's ServiceAccount annotation and the IAM policy matches [Section 2](#2-prerequisites) |
| Files disappear from inbound but never appear outbound | `s3:PutObject` missing on `<outbound-bucket>` for the copy destination | Add the permission and retry — GuardDuty does not re-scan, so re-drive by re-uploading the source object if it was already deleted |
| Messages received but not deleted, queue backs up | Exception during `process_message` before `delete_message` runs | Check pod logs for the stack trace; the message becomes visible again after the queue's visibility timeout and is retried |
