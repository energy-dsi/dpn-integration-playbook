#!/usr/bin/env bash
# ============================================================================
# 04-federator-gateway — AWS-native resource bootstrap
#
# Covers everything a disaster-recovery rebuild needs that CANNOT be expressed
# as a Kubernetes manifest (S3 buckets, IAM policy). Run this BEFORE applying
# manifests/ — the file-pipeline pods (producer-file-adaptor/mapper-bp-natural-gas,
# consumer-file-extractor/mapper) will CrashLoopBackOff on config validation
# without the S3 buckets + IAM access in place.
#
# Idempotent: safe to re-run. Every step checks current state before acting.
#
# Does NOT create: the EKS cluster itself, or an IAM user's access key
# (create/rotate that via IAM console/CLI separately — this script only
# manages the POLICY, not the user or its keys. See RUNBOOK.md 3.2 for the
# recommended dedicated least-privilege IAM user flow).
#
# Required env vars:
#   AWS_REGION            AWS region, e.g. eu-west-2
#   AWS_ACCOUNT_ID         AWS account ID that owns the buckets/policy
#   S3_IAM_USER            IAM user the S3Access policy should be attached to
#   S3_BUCKET_PREFIX        Prefix used for the account-scoped application bucket,
#                           e.g. dpn-dev-<AWS_ACCOUNT_ID>-<AWS_REGION>
#                           (bucket created: ${S3_BUCKET_PREFIX}-application)
# ============================================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:?set AWS_REGION}"  # placeholder: AWS region, e.g. eu-west-2
: "${AWS_ACCOUNT_ID:?set AWS_ACCOUNT_ID}"  # placeholder: <AWS_ACCOUNT_ID>
: "${S3_IAM_USER:?set S3_IAM_USER}"  # placeholder: <S3_IAM_USER_NAME>
: "${S3_BUCKET_PREFIX:?set S3_BUCKET_PREFIX (e.g. dpn-dev-\${AWS_ACCOUNT_ID}-\${AWS_REGION})}"  # placeholder: <S3_BUCKET_PREFIX>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_NAME="S3Access"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
POLICY_FILE="${SCRIPT_DIR}/s3-access-policy.json"

# 6 descriptive-name buckets (kept as sensible generic defaults) + the 7th,
# account-scoped "application" bucket (bug fix — this bucket was referenced by
# 4 Deployments' S3_BUCKET_NAME env var but was never created by this script
# in the source repo; added here so a fresh deploy doesn't hit NoSuchBucket).
BUCKETS=(
  bp-natural-gas-stage bp-natural-gas-raw bp-natural-gas-target
  dp-consumer-stage dp-consumer-trfm dp-consumer-target
  "${S3_BUCKET_PREFIX}-application"
)

log() { echo "[bootstrap] $*"; }

# ---------------------------------------------------------------------------
# 1. S3 buckets — create if missing (idempotent via head-bucket check)
# ---------------------------------------------------------------------------
log "Checking ${#BUCKETS[@]} S3 buckets in ${AWS_REGION}..."
for b in "${BUCKETS[@]}"; do
  if aws s3api head-bucket --bucket "$b" --region "$AWS_REGION" 2>/dev/null; then
    log "  bucket exists: $b"
  else
    log "  creating bucket: $b"
    if [ "$AWS_REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$b" --region "$AWS_REGION"
    else
      aws s3api create-bucket --bucket "$b" --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
  fi
done

# ---------------------------------------------------------------------------
# 2. IAM policy — create or update to the version in scripts/s3-access-policy.json
# ---------------------------------------------------------------------------
log "Reconciling IAM policy ${POLICY_NAME}..."
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  CURRENT_DOC=$(aws iam get-policy-version \
    --policy-arn "$POLICY_ARN" \
    --version-id "$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)" \
    --query 'PolicyVersion.Document' --output json)
  DESIRED_DOC=$(cat "$POLICY_FILE")
  if [ "$(echo "$CURRENT_DOC" | jq -S .)" = "$(echo "$DESIRED_DOC" | jq -S .)" ]; then
    log "  policy already up to date"
  else
    log "  policy exists but differs — publishing new version"
    VERSION_COUNT=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'length(Versions)' --output text)
    if [ "$VERSION_COUNT" -ge 5 ]; then
      OLDEST=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
        --query 'Versions[?IsDefaultVersion==`false`]|sort_by(@,&CreateDate)[0].VersionId' --output text)
      log "  at 5-version limit, deleting oldest non-default version: $OLDEST"
      aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
    fi
    aws iam create-policy-version --policy-arn "$POLICY_ARN" \
      --policy-document "file://${POLICY_FILE}" --set-as-default
  fi
else
  log "  policy does not exist — creating"
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${POLICY_FILE}"
fi

log "Attaching ${POLICY_NAME} to user ${S3_IAM_USER}..."
if aws iam list-attached-user-policies --user-name "$S3_IAM_USER" \
     --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}']" --output text | grep -q .; then
  log "  already attached"
else
  aws iam attach-user-policy --user-name "$S3_IAM_USER" --policy-arn "$POLICY_ARN"
  log "  attached"
fi

# ---------------------------------------------------------------------------
# 3. Verification
# ---------------------------------------------------------------------------
log "Verifying bucket access as ${S3_IAM_USER} would see it (using current AWS CLI identity)..."
for b in "${BUCKETS[@]}"; do
  if aws s3 ls "s3://${b}/" --region "$AWS_REGION" >/dev/null 2>&1; then
    log "  OK: $b"
  else
    log "  WARNING: cannot list $b — check credentials/policy propagation (can take a few seconds)"
  fi
done

log "Bootstrap complete. Next: create the aws-access-secret Secret (RUNBOOK.md 3.2), then apply manifests/."
