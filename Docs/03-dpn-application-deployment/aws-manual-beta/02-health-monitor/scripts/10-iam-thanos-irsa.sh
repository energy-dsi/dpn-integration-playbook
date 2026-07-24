#!/bin/sh
# Creates the IAM role Thanos's sidecar uses (via IRSA) to read/write S3.
# Run this BEFORE applying manifests/05-prometheus-thanos.yaml, then paste
# the printed role ARN into that file's ServiceAccount annotation
# (eks.amazonaws.com/role-arn) and the printed bucket name into its Secret.
#
# Requires: an identity with iam:CreateRole / iam:PutRolePolicy permissions.
# Note: if your org blocks iam:CreateUser via SCP but allows iam:CreateRole,
# that is itself the signal that IRSA — not a static-key Secret — is your
# account's sanctioned pattern here.
set -eu

: "${AWS_REGION:=<AWS_REGION>}"   # e.g. eu-west-2 — the region your EKS cluster runs in
: "${CLUSTER_NAME:?Set CLUSTER_NAME to your EKS cluster name, e.g. <EKS_CLUSTER_NAME>}"
: "${NAMESPACE:=ns-dpn-health-01}"
: "${SERVICE_ACCOUNT:=dpn-thanos-health}"
: "${ROLE_NAME:=dpn-thanos-health-irsa}"
: "${S3_BUCKET:?Set S3_BUCKET to the bucket Thanos should use for long-term metric storage}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=${OIDC_ISSUER##*/id/}
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"

echo "=== Ensure the cluster's OIDC provider is registered with IAM ==="
aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text \
  | tr '\t' '\n' | grep -qx "$OIDC_PROVIDER_ARN" || {
    echo "OIDC provider not registered — associate it first:"
    echo "  eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $AWS_REGION --approve"
    exit 1
  }

TRUST_POLICY=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"${OIDC_PROVIDER_ARN}"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub":"system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}","oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud":"sts.amazonaws.com"}}}]}
JSON
)

echo "=== Create the IAM role ==="
# NOTE (Windows/Git-Bash only): if you hit "No such file or directory" using
# --assume-role-policy-document file://..., that's MSYS auto-translating the
# path before aws.exe (a native binary) sees it. Pass the JSON inline as
# shown here — do not use file:// on Windows/Git-Bash.
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --region "$AWS_REGION" 2>&1 || echo "(role may already exist — continuing)"

S3_POLICY=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"ThanosBucketList","Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":"arn:aws:s3:::${S3_BUCKET}"},{"Sid":"ThanosObjectRW","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::${S3_BUCKET}/*"}]}
JSON
)

echo "=== Attach the scoped S3 policy (this bucket only) ==="
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${ROLE_NAME}-s3-access" \
  --policy-document "$S3_POLICY" \
  --region "$AWS_REGION"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "=== Done. Use these values in manifests/05-prometheus-thanos.yaml ==="
echo "eks.amazonaws.com/role-arn: ${ROLE_ARN}"
echo "bucket: ${S3_BUCKET}"
echo ""
echo "To remove everything this script created:"
echo "  aws iam delete-role-policy --role-name $ROLE_NAME --policy-name ${ROLE_NAME}-s3-access --region $AWS_REGION"
echo "  aws iam delete-role --role-name $ROLE_NAME --region $AWS_REGION"
