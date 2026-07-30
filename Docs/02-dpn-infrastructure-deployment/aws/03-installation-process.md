# 03 - Installation Process

This section describes the end-to-end infrastructure installation process.

## Table of Contents

- [Purpose](#purpose)
- [Phase 0: Preflight (Required)](#phase-0-preflight-required)
  - [Step 0.1 AWS Account and Environment](#step-01-aws-account-and-environment)
  - [Step 0.2 Authenticate and Select Account](#step-02-authenticate-and-select-account)  
  - [Step 0.3 Validate Tooling and Required Files](#step-03-validate-tooling-and-required-files)
- [Phase 1: Bootstrap Infrastructure](#phase-1-bootstrap-infrastructure)
  - [Step 1.0 Check Bootstrap State](#step-10-check-bootstrap-state)  
  - [Step 1.1 Deploy Bootstrap](#step-11-deploy-bootstrap)
  - [Step 1.2 State Management](#step-12-state-management)
- [Phase 2: Infrastructure Deployment](#phase-2-infrastructure-deployment)
  - [Step 2.1 Prepare Environment tfvars](#step-21-prepare-environment-tfvars)
  - [Step 2.2 Initialize OpenTofu](#step-22-initialize-opentofu)
  - [Step 2.3 Deploy Infrastructure](#step-23-deploy-infrastructure)
  - [Step 2.4 Manual Deployment](#step-24-manual-deployment)
- [Phase 3: Infrastructure Validation](#phase-3-infrastructure-validation)  
  - [Step 3.1 Management Host](#step-31-management-host)
  - [Step 3.2 Validate Compute Components](#step-32-validate-compute-components)
  - [Step 3.3 S3 Buckets](#step-33-s3-buckets)
  - [Step 3.4 Validate Security Module Components](#step-34-validate-security-module-components)
  - [Step 3.5 AWS EFS Details](#step-35-aws-efs-details)
  - [Step 3.6 Observability Logging resources](#step-36-observability-logging-resources)
- [Post-Deployment Configuration](#post-deployment-configuration)
  - [10.1 Configure Monitoring Alerts](#101-configure-monitoring-alerts)
  - [10.2 Maintainance Operations](#102-maintainance-operations)
  - [10.3 Document Deployment](#103-document-deployment)
  - [10.4 Prepare for Application Deployment](#104-prepare-for-application-deployment)

## Purpose

This document contains the deployment sequence for the DPN participant AWS environment.

The platform is managed using OpenTofu and deployed through AWS IAM Identity Center (AWS SSO).
All environments are deployed from the same codebase using environment-specific backend and variable files.

This guide assumes a Bash-compatible shell (Linux/macOS terminal or WSL).
Replace all placeholder values before running commands.

---

## Phase 0: Preflight (Required)

### Step 0.1 AWS Account and Environment

Gather all the required information before any deployment activity:

- `AWS_ACCOUNT_ID` — AWS Account ID where DPN infrastructure will be deployed. Example: `<your-aws-account-id>`
- `AWS_REGION` — AWS region agreed with DSI for this environment. Example: `<aws-region>` (e.g. `eu-central-1`)
- `ENVIRONMENT` — Short label matching the tfvars filename prefix. Example: `<env-name>` (e.g. `dev-01`)
- `TFSTATE_BUCKET_NAME` — S3 Bucket name for OpenTofu remote state 
  - Pattern: `dpn-tfstate-<env>-01`
- `TFSTATE_KEY` — Name for the state file inside the `tfstate` S3 key. Must be unique per environment and never change across runs.
  - Pattern: `dpn.<env>.tfstate`
- `TFSTATE_DYNAMODB_TABLE` — DynamoDB Lock table used for locking the state.
  - Pattern: `dpn.tfstate.lock`
- `EXISTING_VPC_ID` — Id of the pre-existing VPC. Example: `<vpc-xxxxxxxxxxxxxx>`
- `TF_WORKING_DIR` — Repo-relative path to the environment folder containing `main.tf` and `environments/`. Use the folder name at the repository root that matches the target environment. Example: `<repo-environment-folder-name>`
- `TFVARS_FILE` — Exact `.tfvars` filename under `$(TF_WORKING_DIR)/environments/`. The file must exist before the pipeline runs. Example: `<env-name>.tfvars`
- `OPENTOFU_VERSION` — OpenTofu CLI version pinned for all pipeline tasks. Do not change without regression testing. Recommended: `1.9.0`


## Step 0.2 Authenticate and Select Account

Authentication is performed using AWS IAM Identity Center (AWS SSO).

The platform does not use:

- Static credentials
- Client certificates
- Long-lived IAM access keys

Authorization is managed through AWS IAM and EKS Access Entries.

Add the following secrets to your client environment:

```bash
AWS_ACCOUNT_ID           - Your AWS account ID
AWS_ACCESS_KEY_ID        - AWS IAM user access key
AWS_SECRET_ACCESS_KEY    - AWS IAM user secret key
AWS_REGION               - Target AWS region (e.g., eu-west-2)
Recommended: Use AWS IAM roles with OIDC instead of access keys for better security.
```

Use this command to validate the AWS Identity and Account. 

```bash
aws sts get-caller-identity
```

### Step 0.3 Validate Tooling and Required Files

Use the following task checks to verify tooling and required files are available.

```bash
aws --version
tofu version

cd $(TF_WORKING_DIR)
test -f "environments/$(TFVARS_FILE)"
```

If the tfvars file check fails, create `environments/$(TFVARS_FILE)` before running the any commands. 

## Phase 1: Bootstrap Infrastructure
This section contains instructions for deploying AWS Bootstrap Infrastructure

Always deploy the bootstrap first for a new environment, or whenever backend/state pre-requisites are missing.

### Step 1.0 Check Bootstrap State

- Check if bootstrap already exists ( S3 state bucket + DynamoDB state lock table ).
- Use it to create or validate the backend S3 state bucket, DynamoDB state lock table, kms key, CloudTrail and CloudWatch Logs.- 
- Skips deployment if resources are present.
- Deploy bootstrap if resources are missing. 
- Bootstrap is only required once per AWS environment.
- If bootstrap resources already exist, you can proceed to deploying the core k8s infrastructure.

### Step 1.1 Deploy Bootstrap

- Navigate to Bootstrap
```bash
cd infrastructure/Tofu/bootstrap
pwd  # Verify: .../infrastructure/Tofu/bootstrap
```

- Initialize Bootstrap
```bash
# Initialize OpenTofu (uses local backend initially)
tofu init

# Output should show:
# Initializing the backend...
# Terraform has been successfully configured!
```

- Review Bootstrap Plan
```bash
  # Review what will be created
  tofu plan -var-file=environments/<environment>.tfvars

  # Output shows:
  #   aws_s3_bucket (state bucket)
  #   aws_dynamodb_table (lock table)
  #   aws_kms_key (encryption key)
  #   aws_cloudtrail (audit logging)
  #   ~15 resources total
```

- Apply Bootstrap
```bash
  # Create S3 bucket, DynamoDB table, KMS key
  tofu apply -var-file=environments/<environment>.tfvars

  # Type: yes to confirm

  # Output shows:
  #   Outputs:
  #   state_bucket_name = "dpn-state-{account-id}"
  #   lock_table_name = "dpn-lock-{account-id}"
  #   backend_config = "..."
```

- Save Bootstrap Outputs
```bash
  # Save outputs for next phase
  tofu output -raw backend_config > backend_config.txt

  # Display backend config
  cat backend_config.txt
  # Output:
  #   bucket="dpn-state-..."
  #   dynamodb_table="dpn-lock-..."
  #   key="part"
  #   region="eu-west-2"
```

- (Optional) Bootstrap Validation
```bash
  # Verify S3 bucket was created
  aws s3 ls | grep dpn-state

  # Verify DynamoDB table was created
  aws dynamodb list-tables | grep dpn-lock

  # Verify KMS key was created
  aws kms describe-key --key-id alias/dpn-state
```

---

### Step 1.2 State Management

- During the initial bootstrap, state is stored locally in bootstrap.tfstate file. This ensures bootstrap can create the S3 state backend without circular dependencies.

- After the initial bootstrap is deployed:
    1. Verify S3 state bucket and DynamoDB lock table are created.
    2. Uncomment the below s3 backend code block in backend-bootstrap-tf
        ```
        # terraform {
        #   backend "s3" {
        #     bucket         = "dpn-tfstate-bootstrap"
        #     key            = "bootstrap/terraform.tfstate"
        #     region         = "eu-west-2"
        #     dynamodb_table = "dpn-tfstate-lock"
        #     encrypt        = true
        #   }
        # }
    3. Run terraform init to migrate
      ```
      cd infrastructure/Tofu/bootstrap
      tofu init  # Select "yes" to migrate state
    4. Verify state migration to S3
      ```
      tofu state list       

- Migrating bootstrap state to S3 provides
  - Centralized state management
  - Automated backups via S3 versioning
  - Remote backup
  - Team collaboration
  - Audit trail via CloudTrail

## Phase 2: Infrastructure Deployment

This phase is executed after the bootstrap backend is deployed. 

### Step 2.1 Prepare Environment tfvars

Verify tfvars file existence in working directory.

```bash
cd $(TF_WORKING_DIR)
test -f "environments/$(TFVARS_FILE)"
```

### Step 2.2 Initialize OpenTofu

Use the following command to initialize OpenTofu with the configured backend.

Get backend configuration from outputs:
  tofu output backend_config_hcl

Then copy the output and update infrastructure/Tofu/backend.tf.

# Initialize with remote backend
Create infrastructure/Tofu/backend.tf:

Uncomment the S3 backend block in backend-bootstrap.tf and update it with correct values
```bash
terraform {
  backend "s3" {
    bucket         = "dpn-tfstate-part-001"
    key            = "part/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "dpn-tfstate-lock"
    encrypt        = true
  }
}
```

Run terraform init to migrate:
```bash
  cd infrastructure/Tofu/bootstrap
  tofu init

  Type: yes to confirm backend migration
  Output: Successfully configured backend
```

Verify migration:
```bash
  tofu state list
```

---

### Step 2.3 Deploy Infrastructure

The repository provides a deployment helper script located at:

```bash
infrastructure/Tofu/scripts/deploy.sh
```
Supported environments:

```bash
dev-01
dev-02
test-01
test-02
```

Supported actions:

```bash
init
fmt
validate
plan
apply
```

Example sequence to deploy dev-01 environment

Initialize an environment:
```bash
./scripts/deploy.sh dev-01 init
```

Validate::
```bash
./scripts/deploy.sh dev-01 validate
```

Generate a deployment plan:
```bash
./scripts/deploy.sh dev-01 plan
```

Apply the previously reviewed plan:
```bash
./scripts/deploy.sh dev-01 apply
```

The deployment script automatically:

- selects the correct AWS SSO profile
- validates the AWS account ID
- initializes the correct backend
- uses the matching environment .tfvars
- stores the execution plan in an environment-specific .tfplan file
- prevents accidental deployment to the wrong AWS account

### Step 2.4 Manual Deployment

For troubleshooting or advanced scenarios, deployments can also be performed manually.

Move to the infrastructure directory:

```bash
cd infrastructure/Tofu
```

Initialize the backend
```bash
tofu init \
    -reconfigure \
    -backend-config=backends/dev-01.hcl
```

Generate a plan:
```bash
tofu plan \
    -var-file=environments/dev-01.tfvars \
    -out=dev-01.tfplan
```

Review the execution plan before applying.
Apply th plan:
```bash
tofu apply dev-01.tfplan
```

## Phase 3: Infrastructure Validation

Use the following steps to verify the deployed services.

### Step 3.1 Management Host

Each environment deploys a dedicated EC2 management host.

The management host is intended for:

- OpenTofu administration
- Kubernetes administration
- AWS CLI operations
- kubectl
- Helm
- Platform troubleshooting and diagnostics

Access is performed using AWS Systems Manager Session Manager.
Example:
```bash
aws ssm start-session \
    --target <instance-id> \
    --profile dev-01
```
Create AWS profiles as required. 

The management host instance ID can be obtained from OpenTofu:
```bash
tofu output management_host_instance_id
```
or from the AWS Console

---

### Step 3.2 Validate Compute Components

Validate cluster access and node readiness.

Example:
```
aws eks update-kubeconfig \
    --name <cluster-name> \
    --region eu-west-2
```

```bash
# EKS Cluster
kubectl get cluster-info
kubectl get nodes
kubectl get pods -A
kubectl get nodes -o wide
kubectl get namespaces

# Database
psql -h {database-endpoint} -U admin -d postgres -c "SELECT version();"

# Container Registry
aws ecr describe-repositories

# Load Balancer
aws elbv2 describe-load-balancers \
  --names dpn-alb-part

# WAF
aws wafv2 list-web-acls --region eu-west-2
```
---

### Step 3.3 S3 Buckets

If application s3 buckets are defined in your stack, verify after full apply:

- application s3 bucket (workload data)

```bash
BUCKET=<application_bucket_arn>
echo "--- Region ---"
aws s3api get-bucket-location --bucket $BUCKET --output text
echo "--- Versioning ---"
aws s3api get-bucket-versioning --bucket $BUCKET --query "Status" --output text 2>/dev/null || echo "Disabled"
echo "--- Encryption ---"
aws s3api get-bucket-encryption --bucket $BUCKET --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" --output text 2>/dev/null || echo "None"

```

Expected output examples:

```text
--- Region ---
us-east-2
--- Versioning ---
Enabled
--- Encryption ---
AES256
```
---

### Step 3.4 Validate Security Module Components

If your deployment completed successfully in Phase 2, verify key security services are present and healthy.

Validation:

```bash
aws kms describe-key --key-id <your-key-id-or-arn-or-alias>
aws iam get-role --role-name $(echo "arn:aws:iam::123456789012:role/eks_cluster_role" | awk -F'/' '{print $NF}')
aws iam get-role --role-name $(echo "arn:aws:iam::123456789012:role/eks_node_role" | awk -F'/' '{print $NF}')
```
---

### Step 3.5 AWS EFS Details

This deployment uses AWS EFS storage for application storage, with the file share secured through a private endpoint.

### What is created

- AWS EFS

### Key configuration values

The following variables are used in the deployment:

- `enable_efs_csi_driver` – The Amazon EFS Container Storage Interface (CSI) driver allows Kubernetes clusters running on AWS to mount Amazon EFS file systems as persistent volumes.

### Why this matters

- Ensures developer storage is provided as a managed EFS file system
- Keeps the EFS traffic private inside the VPC
- Supports secure access to developer storage without exposing the file share over the public internet

---

### Step 3.6. Observability Logging resources 

This deployment includes Cloudwatch log groups and dedicated S3 buckets for observability logging, used to centralize log and diagnostic export separately from application and file scanning storage.

### What is created

- New S3 buckets for alb_logs, firewall_logs and ssm_logs used to store exported logs/diagnostics
- New CloudWatch log groups created for waf, ssm_sessions, eks_control_plane, firewall_alert, firewall_flowlog and vpc_flow_logs.
- A private endpoint to access the s3 service privately from VPC.

### Key configuration values

The following variables are used in the deployment:

- `create_log_s3_buckets` – new storage account identity
- `kms_key_arn` – key used for encryption
- `log_retention_in_days` – number of days logs should be stored
- `environment` – dev or test or preprod or prod etc.
- `project_name` - Project Name

### Deployment behavior

- The Observability S3 buckets are deployed isolated from the core application and file scanning subnets (the reference dev environment reuses the file scanning storage subnet — confirm whether your environment should instead provision a dedicated subnet). The S3 log buckets are accessed through private endpoints, provided the s3 endpoints are in place, isolated from the core application and file scanning subnets 
- RBAC role assignments follow least-privilege data-plane roles (Reader, Contributor) rather than granting broad control-plane access.


## Post-Deployment Configuration

Use the following post-deployment steps to complete operational setup.
These actions are not part of the current base infrastructure deployment.
Use them only through a separate operations pipeline or controlled runbook if your organisation requires them.

### 10.1 Configure Monitoring Alerts

Create required CloudWatch alerts for monitoring

```bash
# Create CloudWatch alarm for high CPU
aws cloudwatch put-metric-alarm \
  --alarm-name dpn-high-cpu \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold

# Create alarm for RDS connections
aws cloudwatch put-metric-alarm \
  --alarm-name dpn-db-connections \
  --metric-name DatabaseConnections \
  --namespace AWS/RDS \
  --threshold 80
```

### 10.2 Maintainance Operations

Perform maintainance operations as required.

```bash
# Update EKS cluster version (monthly)
aws eks update-cluster-version \
  --name dpn-eks-part \
  --kubernetes-version 1.34

# Update node AMI (monthly)
aws eks update-nodegroup-version \
  --cluster-name dpn-eks-part \
  --nodegroup-name system

# Rotate RDS master password (quarterly)
aws secretsmanager rotate-secret \
  --secret-id dpn/part/rds/password

# Review Security Hub findings (weekly)
aws securityhub get-insights

# Analyze costs (monthly)
# AWS Cost Management Console
```

### 10.3 Document Deployment

Example commands to capture the deployed resource inventory for operational handover.

```bash
aws resource-explorer-2 search --query-string "arn" --query "Resources[*].Arn" --output text
tofu show -json | jq '.values.root_module.resources[] | {type, name}' > tofu-resources.json
```

### 10.4 Prepare for Application Deployment

After infrastructure deployment completes successfully, prepare handoff documentation for the application deployment team.

**Export Infrastructure Outputs:**

OpenTofu outputs contain critical information needed for application deployment configuration. Export these values:

```bash
# Retrieve OpenTofu outputs for application team
tofu output -json > infrastructure-outputs.json
```

**Document Infrastructure Details:**

Create a handoff document for the application deployment team with:

- Deployed resource names (EKS cluster, ECR, Keys, S3 Buckets)
- Node pool configurations and capacity
- Network topology and security group rules
- IAM roles and service principal information
- Key Vault endpoint and secret naming conventions
- Observability logging S3 Buckets and Cloudwatch log groups.

**Next Steps:**

Transition to your application deployment guide or platform runbook.

---

Continue with [04-rollback-procedures.md](04-rollback-procedures.md)