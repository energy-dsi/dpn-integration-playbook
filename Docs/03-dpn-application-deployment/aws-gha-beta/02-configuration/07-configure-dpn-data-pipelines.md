Release : 2.1.0 - Oct 2026

# DPN Data Pipeline Configuration

---

## Table of Contents

- [Overview](#overview)
- [STEP-01: Configuration Table](#step-01-configuration-table)
- [STEP-02: Secrets Table](#step-02-secrets-table)
- [STEP-03: IAM Role for S3 Access (IRSA)](#step-03-iam-role-for-s3-access-irsa)
- [Review Notes](#review-notes)

---

## Overview

This guide lists **only what a participant organisation must set** to run the DPN Data Pipeline on AWS. Everything not listed here is preconfigured or handled by the platform and must be left at its default.

| Action | Where |
|--------|-------|
| **Required participant action:** update the values in the Configuration Table | [STEP-01](#step-01-configuration-table) |
| **Required participant action:** create the secrets in the Secrets Table | [STEP-02](#step-02-secrets-table) |

> **Informational (no action required):**
> - Pipeline images, registry and tag are set by the CI/CD workflows.
> - Kafka connection and security (`SASL_SSL` with `OAUTHBEARER`), scheduling (`interval`) and autoscaling (off) are preconfigured; keep the defaults.
> - S3 buckets and Kafka topics are created automatically by the pipeline. Their names must not already exist.
> - Files keep their original name in the target bucket.

---

## STEP-01: Configuration Table

Set the parameters below in the `values.yaml` file of each chart. Make the changes in **your own copy** of the `dpn-data-pipelines` repository, then commit and push to the branch the CD workflow runs from. The workflow deploys what is in that branch.

The `values.yaml` files are in the `blueprints` folder of the repository:

```text
Root-Repository
└── blueprints
    ├── producer
    │   ├── file
    │   │   └── adaptor
    │   │       └── charts
    │   │           └── values.yaml   <- Edit: orgName, cloudProviderType
    │   └── topic
    │       └── adaptor
    │           └── charts
    │               └── values.yaml   <- Edit: orgName
    └── consumer
        ├── file
        │   └── extractor
        │       └── charts
        │           └── values.yaml   <- Edit: cloudProviderType
        └── topic
            └── extractor
                └── charts
                    └── values.yaml   <- No change needed
```

| Parameter | Purpose | Required value |
|-----------|---------|----------------|
| `orgName` | Your organisation name abbreviation, with no space in between. **Required: the default `example-org` must be changed** | `<your-org-abbreviation>` |
| `cloudProviderType` | This value provides which cloud environment the data pipeline is going to run | `aws` |

**Available values for the cloud provider** (`cloudProviderType`): `azure`, `aws`, `gcp` (lowercase). Use `aws` for this AWS deployment.

> **GCP is not supported yet.** GCP support is planned for a future release.

**Environment-specific values for the Self-Service Data Pipelines service.** Set them before you run `dpn-gha-data-pipelines-cd.yaml` or `dpn-gha-self-service-cd.yaml`:

| Key | Where | Description | Example (placeholder) |
|-----|-------|-------------|-----------------------|
| `IMAGE_REGISTRY` | `env:` block of `.github/workflows/dpn-gha-data-pipelines-cd.yaml` | Base container registry the data pipeline images are pulled from | `ghcr.io/energy-dsi` (or your own, for example `<account-id>.dkr.ecr.<region>.amazonaws.com`) |
| `imageRegistry` | `service/charts/values/aws/<environment>-<cluster>.yaml` | Registry the self-service application image is pulled from | `ghcr.io/energy-dsi` |
| `env.DPN_IMAGE_REGISTRY` | `service/charts/values/aws/<environment>-<cluster>.yaml` | Registry path (including the `/dsi` namespace) the service uses for the pipeline images it deploys | `ghcr.io/energy-dsi/dsi` |
| `env.DPN_REGISTRY_BACKUP_CONTAINER` | `service/charts/values/aws/<environment>-<cluster>.yaml` | S3 bucket that `service/registry_backup.py` mirrors the self-service registry to for disaster recovery | `<registry-backup-bucket-name>` |
| `serviceAccount.irsaRoleArn` | `service/charts/values/aws/<environment>-<cluster>.yaml` | IAM role ARN the self-service `ServiceAccount` assumes through IRSA, with access to the data pipeline S3 buckets | `arn:aws:iam::<account-id>:role/<irsa-role-name>` |
| `loadBalancer.loadBalancerIP` | `service/charts/values.yaml` | Optional static IP for the internal LoadBalancer in front of the self-service UI. Leave it empty on EKS to let AWS allocate the address | `<static-ip>` |

---

## STEP-02: Secrets Table

The secrets below are required in the data pipeline namespace (`ns-dpn-dp-01`) **before** you run the CD workflow. The containers do not start without them.

> **Required: these secrets must exist in the `ns-dpn-01` namespace first.** Kubernetes secrets cannot be shared across namespaces, so the secrets are sourced from `ns-dpn-01` and copied into `ns-dpn-dp-01`. Follow this order for **each** secret in the table:
> 1. **Verify** it exists in `ns-dpn-01` (command below).
> 2. **If it exists**, **copy** it into `ns-dpn-dp-01` with the copy commands below.
> 3. **If it does not exist**, **create** it directly in `ns-dpn-dp-01`. `dpn-tls` and `dpn-keycloak-secrets` are platform-provided and must not be created by hand: if either is missing from `ns-dpn-01`, complete the DPN Certificate Manager / Authentication Service installation first.

| Secret | Keys | Value | Used by |
|--------|------|-------|---------|
| `dpn-tls` | `ca.crt`, `keystore.jks`, `truststore.jks` | Copy from `ns-dpn-01`. Do not change the contents | All pipeline containers (Kafka TLS trust) |
| `dpn-keycloak-secrets` | `KC_SERVICE_CLIENT_SECRET` | Copy from `ns-dpn-01`. Do not change the contents | All pipeline containers (Kafka OAuth) |
| `ghcr-pull-secret` | Docker registry credentials for `ghcr.io` | A GitHub PAT with `read:packages` scope. Not needed if the images are mirrored to ECR and the EKS nodes can pull from it | All pipeline containers (image pull) |
| `aws-access-secret` (optional) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Needed only if you use static access keys for S3 instead of IRSA. The IAM identity needs `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` and `s3:CreateBucket` on the buckets used by data products | Self-Service UI, producer file products, consumer file extractor |

> **S3 access normally uses IRSA** (an IAM role bound to the pod's ServiceAccount), so no AWS key secret is needed. Skip `aws-access-secret` unless you choose static keys.

**Verify the secrets in `ns-dpn-01`:**

```bash
kubectl get secret dpn-tls dpn-keycloak-secrets ghcr-pull-secret aws-access-secret -n ns-dpn-01
```

Any secret reported as `NotFound` does not exist in `ns-dpn-01`; create it in `ns-dpn-dp-01` (`ghcr-pull-secret`, and `aws-access-secret` if you use it, see below).

**Copy the secrets into `ns-dpn-dp-01`** (for each secret that exists in `ns-dpn-01`). Run each command below (PowerShell) for that secret:

```powershell
# dpn-tls
kubectl get secret dpn-tls -n ns-dpn-01 -o json | ConvertFrom-Json | ForEach-Object { @{apiVersion="v1";kind="Secret";type=$_.type;data=$_.data;metadata=@{name=$_.metadata.name;namespace="ns-dpn-dp-01"}} } | ConvertTo-Json -Depth 10 | kubectl apply -f -

# dpn-keycloak-secrets
kubectl get secret dpn-keycloak-secrets -n ns-dpn-01 -o json | ConvertFrom-Json | ForEach-Object { @{apiVersion="v1";kind="Secret";type=$_.type;data=$_.data;metadata=@{name=$_.metadata.name;namespace="ns-dpn-dp-01"}} } | ConvertTo-Json -Depth 10 | kubectl apply -f -

# ghcr-pull-secret
kubectl get secret ghcr-pull-secret -n ns-dpn-01 -o json | ConvertFrom-Json | ForEach-Object { @{apiVersion="v1";kind="Secret";type=$_.type;data=$_.data;metadata=@{name=$_.metadata.name;namespace="ns-dpn-dp-01"}} } | ConvertTo-Json -Depth 10 | kubectl apply -f -

# aws-access-secret
kubectl get secret aws-access-secret -n ns-dpn-01 -o json | ConvertFrom-Json | ForEach-Object { @{apiVersion="v1";kind="Secret";type=$_.type;data=$_.data;metadata=@{name=$_.metadata.name;namespace="ns-dpn-dp-01"}} } | ConvertTo-Json -Depth 10 | kubectl apply -f -
```

Repeat the copy for `dpn-tls` and `dpn-keycloak-secrets` whenever either is rotated in `ns-dpn-01`.

**Create the image pull secret and, if used, the AWS key secret (only if they do not exist in `ns-dpn-01`):**

```bash
kubectl create secret docker-registry ghcr-pull-secret   --docker-server=ghcr.io   --docker-username=<github-username>   --docker-password=<PAT with read:packages>   -n ns-dpn-dp-01

kubectl create secret generic aws-access-secret   --from-literal=AWS_ACCESS_KEY_ID=<access key id>   --from-literal=AWS_SECRET_ACCESS_KEY=<secret access key>   -n ns-dpn-dp-01
```

**Confirm the result:**

```bash
kubectl get secret dpn-tls dpn-keycloak-secrets ghcr-pull-secret -n ns-dpn-dp-01
```

> **Informational (no action required):** The secrets `tls-auth-secret` and `dpn-health-ca` are provided by the DPN Certificate Manager and Health Monitoring services. Verify that they exist in `ns-dpn-dp-01`.

> **Note:** The topic pathway needs no storage secret. The Azure storage connection-string secrets (`producer-file-dp-secret`, `consumer-file-dp-secret`) are not used on AWS.

---

## STEP-03: IAM Role for S3 Access (IRSA)

The data pipeline ServiceAccounts reach S3 through one shared IRSA role, `dpn-data-pipeline-s3-role`. Create it manually, once per account/cluster, and set its ARN as `serviceAccount.irsaRoleArn` (see [STEP-01](#step-01-configuration-table)). Reference policy files are kept in the `dpn-iam` export under `template/roles/dpn-data-pipeline-s3-role/`.

**Trust policy** (`trust-policy.json`). Every ServiceAccount in `ns-dpn-dp-01` is trusted (the Self-Service UI creates pipeline ServiceAccounts dynamically), plus the consumer file extractor in `ns-dpn-01`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<oidc-provider-id>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.<region>.amazonaws.com/id/<oidc-provider-id>:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "oidc.eks.<region>.amazonaws.com/id/<oidc-provider-id>:sub": [
            "system:serviceaccount:ns-dpn-dp-01:*",
            "system:serviceaccount:ns-dpn-01:dpn-consumer-file-extractor"
          ]
        }
      }
    }
  ]
}
```

**Permission policy** (`dpn-data-pipeline-s3-permissions.json`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:DeleteObject",
        "s3:CreateBucket"
      ],
      "Resource": "arn:aws:s3:::*"
    }
  ]
}
```

> **Scope.** `arn:aws:s3:::*` is needed because data-product bucket names are chosen by users at run time and `s3:CreateBucket` has no resource to narrow. If your organisation requires tighter scoping, restrict the `Resource` to a bucket-name prefix (for example `arn:aws:s3:::dpn-<env>-*`) and agree that naming convention with data-product owners.

```bash
aws iam create-role \
  --role-name dpn-data-pipeline-s3-role \
  --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \
  --role-name dpn-data-pipeline-s3-role \
  --policy-name dpn-data-pipeline-s3-permissions \
  --policy-document file://dpn-data-pipeline-s3-permissions.json
```

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
