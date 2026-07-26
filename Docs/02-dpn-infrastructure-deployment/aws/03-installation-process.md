# 03 - Installation Process

This section describes the end-to-end infrastructure installation process.

## Table of Contents

- [Purpose](#purpose)
- [GitHub Action Workflows](#github-action-workflows)
- [Phase 0: Preflight (Required)](#phase-0-preflight-required)
- [GitHub Actions Workflow Stage Sequence](#github-actions-workflow-stage-sequence)
  - [Step 0.1 GitHub Actions Setup](#github-actions-setup)
    - [A. Create GitHub Deployment Variables](#create-github-deployment-variables)
    - [B. Create GitHub Secrets](#create-github-secrets)
    - [C. Create GitHub Environments](#create-github-environments)
- [Azure DevOps Pipelines](#azure-devops-pipelines)
- [Phase 0: Preflight](#phase-0-preflight-required-1)
- [Current ADO Pipeline Stage Sequence](#current-ado-pipeline-stage-sequence-authoritative)
  - [Step 0.1 Set Deployment Variables](#step-01-set-deployment-variables)
    - [How to Create the Library Variable Group](#how-to-create-the-library-variable-group)
    - [A. AWS Account & Environment](#a-aws-account--environment)
    - [B. Agent Pool & Service Connection](#b-agent-pool--service-connection)
    - [C. OpenTofu Backend State Storage](#c-opentofu-backend-state-storage)
    - [D. VPC](#d-vpc)
    - [E. Private DNS](#e-private-dns)
    - [F. Pipeline YAML-Defined Variables](#f-pipeline-yaml-defined-variables)
  - [Step 0.2 Authenticate and Select Account](#step-02-authenticate-and-select-account)
  - [Step 0.3 Validate Tooling and Required Files](#step-03-validate-tooling-and-required-files)
- [Phase 1: Bootstrap Infrastructure](#phase-1-bootstrap-infrastructure)
  - [Step 1.0 Use the Bootstrap Pipeline](#step-10-use-the-bootstrap-pipeline)
  - [Step 1.1 Check Bootstrap State](#step-11-check-bootstrap-state)
  - [Step 1.2 Deploy Bootstrap via Subscription-Scope Bicep](#step-12-deploy-bootstrap-via-subscription-scope-bicep)
  - [Step 1.4 Validate Backend Storage Redundancy](#step-14-validate-backend-storage-redundancy)
- [Phase 2: Initialize and Plan](#phase-2-initialize-and-plan)
  - [Step 2.1 Prepare Environment tfvars](#step-21-prepare-environment-tfvars)
  - [Step 2.2 Initialize OpenTofu](#step-22-initialize-opentofu)
  - [Step 2.3 Plan Infrastructure](#step-23-plan-infrastructure)
- [Phase 3: Validate Core Services](#phase-3-validate-core-services)
  - [Step 3.1 Validate Security and Monitoring Components](#step-31-validate-security-and-monitoring-components)
- [Phase 4: Compute Platform](#phase-4-compute-platform)
  - [Step 4.1 Validate Compute Components](#step-41-validate-compute-components)
  - [Step 4.2 VM Validation](#step-42-vm-validation)
- [Phase 5: Storage & Messaging Services](#phase-5-storage--messaging-services)
  - [Step 5.1 Deploy Storage Accounts](#step-51-deploy-storage-accounts)
  - [Step 5.2 Deploy Azure File Share](#step-52-deploy-azure-file-share)
  - [Step 5.3 Validate Event Grid Topic (File Scanning Service)](#step-53-validate-event-grid-topic-file-scanning-service)
  - [Step 5.4 Validate Service Bus Namespace (File Scanning Service)](#step-54-validate-service-bus-namespace-file-scanning-service)
  - [Step 5.5 Validate File Scanning Storage Account](#step-55-validate-file-scanning-storage-account)
  - [Step 5.6 Validate Observability Logging Storage Account](#step-56-validate-observability-logging-storage-account)
- [Phase 6: Validation and Testing](#phase-6-validation-and-testing)
  - [Step 6.1 Complete Remaining Deployments](#step-61-complete-remaining-deployments)
  - [Step 6.2 Infrastructure Validation](#step-62-infrastructure-validation)
- [Post-Deployment Configuration](#post-deployment-configuration)
  - [10.1 Configure Monitoring](#101-configure-monitoring)
  - [10.2 Configure Alerts](#102-configure-alerts)
  - [10.3 Configure Backup](#103-configure-backup)
  - [10.4 Document Deployment](#104-document-deployment)
  - [10.5 Prepare for Application Deployment](#105-prepare-for-application-deployment)
  - [10.6 Pipeline Execution and Connectivity Validation](#106-pipeline-execution-and-connectivity-validation)

## Purpose

This document contains the deployment sequence for the DPN participant environment.

This guide assumes a Bash-compatible shell (Linux/macOS terminal or WSL).
It is written for GitHub actions Workflows and Azure DevOps pipeline execution (not manual/local runs).
Replace all placeholder values before running commands.

> ⚠️ **EXECUTION RULE FOR THIS DOCUMENT**
>
> - **Commands shown below are pipeline task commands executed by GitHub runners or Azure DevOps agents.**
> - **Do not run these commands manually unless a step explicitly says manual troubleshooting or marks the command as an optional operational example.**
> - **Ensure variables/service connections are configured in pipeline/library settings before command execution.**

---

## GitHub Action Workflows

## Phase 0: Preflight (Required)

Complete the following preflight steps before starting any deployment activity.

### GitHub Actions workflow stage Sequence

Use this stage sequence to understand the current GitHub Actions deployment workflow before triggering any workflow run.  

1. **Bootstrap workflow** (`bootstrap-aws-*.yml`)
  - `check-bootstrap`
  - `deploy-bootstrap` (runs only when bootstrap resources are missing)

2. **Main infrastructure pipeline** (`part-aws-*.yml`)
  - `validate-bootstrap`
  - `quality-checks`
  - `plan`
  - `apply`
    - `OpenTofu Apply` (only when `-auto-approve` is used, otherwise manual approval is needed)
    - `OpenTofu Destroy` (only when `-auto-approve` is used, otherwise manual approval is needed)

### Step 0.1 GitHub Actions Setup

#### A. Set GitHub Deployment Variables
Add the following repository or environment variables:

```bash
OPENTOFU_VERSION         - OpenTofu version (e.g., 1.9.0)
TFSTATE_BUCKET_NAME      - S3 bucket name (e.g., dpn-tfstate-part-001)
TFSTATE_DYNAMODB_TABLE   - DynamoDB table name (e.g., dpn-tfstate-lock)
TFSTATE_KEY              - State file key (e.g., part/terraform.tfstate)
PROJECT_NAME             - Project name (e.g., dpn)
ENVIRONMENT              - Environment name (e.g., part)
```

#### B. Create GitHub Secrets
Add the following secrets to your GitHub repository:

```bash
AWS_ACCOUNT_ID           - Your AWS account ID
AWS_ACCESS_KEY_ID        - AWS IAM user access key
AWS_SECRET_ACCESS_KEY    - AWS IAM user secret key
AWS_REGION               - Target AWS region (e.g., eu-west-2)
Recommended: Use AWS IAM roles with OIDC instead of access keys for better security.
```

#### C. Create GitHub Environments
Create two environments in your GitHub repository:

bootstrap-aws-001 (for bootstrap workflow)
  - No additional configuration needed

part-aws-001-deploy (for main infrastructure)
 - Add required reviewers for manual approval
 - Set deployment branches to: main, development

### Step 0.2 Authenticate and Select Account

Authentication is provided by the AWS Credentials configured as GitHub Secrets
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

If the tfvars file check fails, create `environments/$(TFVARS_FILE)` before running the deployment pipeline.

## Phase 1: Bootstrap Infrastructure
This section contains CICD pipeline definitions for deploying AWS Bootstrap Infrastructure

- GitHub Actions Workflow
  Located in .github/workflows
    - bootstrap-aws-001.yml - GitHub actions workflow for Bootstrap

### Step 1.0 Use the Bootstrap Pipeline

Always run the bootstrap pipeline first for a new environment, or whenever backend/state prerequisites are missing.

Bootstrap pipeline usage:

- Use `aws-pipeline-bootstrap-*.yml` workflow if using GitHub Actions for the target environment.
- Use it to create or validate the backend S3 state bucket, DynamoDB state lock table, kms key, CloudTrail and CloudWatch Logs. 
- Bootstrap is only required once per AWS environment.
- If bootstrap resources already exist, the pipeline should complete through the bootstrap check/skip path.

### Step 1.1 Check Bootstrap State

The pipeline automatically handles bootsrap deployment

- Check if bootstrap already exists ( S3 state bucket + DynamoDB state lock table ).
- Skips deployment if resources are present.
- Deploys bootstrap if resources are missing. 

### Step 1.2 Running Bootstrap Workflow

  Go to Actions → Bootstrap Infrastructure (bootstrap-aws-001)
  Click Run workflow
  Choose what_if: true for preview (default)
    - This runs tofu plan from infrastructure/Tofu/bootstrap/
  Re-run with what_if: false to actually deploy
    - This runs tofu apply with environments/part.tfvars
  Copy backend output from workflow logs
  Update infrastructure/Tofu/backend.tf with the backend configuration

### Step 1.3 State Management

- During the initial bootstrap, state is stored locally in bootstrap.tfstate file (chicken-and-egg problem). This ensures bootstrap can create the S3 state backend without circular dependencies.

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

### Step 1.4 Deploy Bootstrap from command line

- Navigate to Bootstrap
```bash
cd infrastructure/Tofu/bootstrap
pwd  # Verify: .../infrastructure/Tofu/bootstrap

- Initialize Bootstrap
```bash
# Initialize OpenTofu (uses local backend initially)
tofu init

# Output should show:
# Initializing the backend...
# Terraform has been successfully configured!

- Review Bootstrap Plan
```bash
  # Review what will be created
  tofu plan -var-file=environments/part.tfvars

  # Output shows:
  #   aws_s3_bucket (state bucket)
  #   aws_dynamodb_table (lock table)
  #   aws_kms_key (encryption key)
  #   aws_cloudtrail (audit logging)
  #   ~15 resources total

- Apply Bootstrap
```bash
  # Create S3 bucket, DynamoDB table, KMS key
  tofu apply -var-file=environments/part.tfvars

  # Type: yes to confirm

  # Output shows:
  #   Outputs:
  #   state_bucket_name = "dpn-state-{account-id}"
  #   lock_table_name = "dpn-lock-{account-id}"
  #   backend_config = "..."

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

- (Optional) Bootstrap Validation
```bash
  # Verify S3 bucket was created
  aws s3 ls | grep dpn-state

  # Verify DynamoDB table was created
  aws dynamodb list-tables | grep dpn-lock

  # Verify KMS key was created
  aws kms describe-key --key-id alias/dpn-state

## Phase 2: Initialize and Plan

This phase is executed in the main infrastructure workflow.

### Step 2.1 Prepare Environment tfvars

Verify tfvars file existence in pipeline working directory.

```bash
cd $(TF_WORKING_DIR)
test -f "environments/$(TFVARS_FILE)"
```

### Step 2.2 Initialize OpenTofu

Use the following pipeline task command to initialize OpenTofu with the configured backend.

```
Get backend configuration from outputs:

  tofu output backend_config_hcl
Then copy the output and update infrastructure/Tofu/backend.tf.

# Initialize with remote backend
Create infrastructure/Tofu/backend.tf:

Uncomment the S3 backend block in backend-bootstrap.tf

terraform {
  backend "s3" {
    bucket         = "dpn-tfstate-part-001"
    key            = "part/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "dpn-tfstate-lock"
    encrypt        = true
  }
}

Run terraform init to migrate:
  cd infrastructure/Tofu/bootstrap
  tofu init  # Select "yes" to migrate state
Verify migration:
  tofu state list

# Type: yes to confirm backend migration
# Output: Successfully configured backend
```

### Step 2.3 Plan Infrastructure

Main pipeline behavior is controlled by `action` parameter:

- `plan` → runs OpenTofu plan and publishes plan artifact
- `apply` → runs plan, optional manual approval, then apply
- `destroy` → routed through destroy path/pipeline

- Main Infrastructure:

  Go to Actions → Infrastructure Deployment (part-aws-001)
  Click Run workflow
  Choose action: plan, apply, or destroy
  For PRs: Automatically runs plan on changes to infrastructure/

-----------------------

## Azure DevOps Pipelines

## Phase 0: Preflight (Required)

Complete the following preflight steps before starting any deployment activity.

### Current ADO Pipeline Stage Sequence (Authoritative)

Use this stage sequence to understand the current Azure DevOps deployment flow before triggering any pipeline run.  

1. **Bootstrap pipeline** (`aws-pipeline-bootstrap-*.yml`)
  - `CheckBootstrap`
  - `DeployBootstrap` (runs only when bootstrap resources are missing)

2. **Main infrastructure pipeline** (`aws-pipeline-part-*.yml`)
  - `ValidateBootstrap`
  - `QualityChecks`
  - `Plan`
  - `Deploy`
    - `OpenTofuApply` (only when `-auto-approve` is used, otherwise manual approval is needed)
    - `OpenTofuDestroy` (only when `-auto-approve` is used, otherwise manual approval is needed)
  - `Verification` (only after successful apply)

### Step 0.1 Set Deployment Variables

Create one **Azure DevOps Library Variable Group** per environment and assign it to the relevant pipeline. In pipeline YAML, all variables are referenced as `$(VARIABLE_NAME)`.

**Variable group naming:**

- DPN-001 pipelines → `dpn-<env>-vars-001`

> Example for `devtest01`: `dpn-devtest01-vars-001`

---

#### How to Create the Library Variable Group

1. In Azure DevOps, go to **Pipelines > Library**.
2. Select **+ Variable group**.
3. Enter the name following the pattern above (e.g. `dpn-devtest01-vars-001`).
4. Add each variable below as a key–value pair.
5. Mark sensitive values as **secret** using the padlock icon.
6. Select **Save**.
7. In the pipeline YAML, confirm the `- group:` entry matches the group name exactly.

---

#### A. AWS Account & Environment

> Get `AWS_ACCOUNT_ID` from **AWS Console**. `ENVIRONMENT` must match the prefix of the tfvars filename (e.g. `devtest01`).

- `AWS_ACCOUNT_ID` — AWS Account ID where DPN infrastructure will be deployed. Example: `<your-aws-account-id>`
- `AWS_REGION` — AWS region agreed with DSI for this environment. Example: `<aws-region>` (e.g. `eu-central-1`)
- `ENVIRONMENT` — Short label matching the tfvars filename prefix. Example: `<env-name>` (e.g. `test01`)

---

#### B. Agent Pool & Service Connection

> `AGENT_POOL` is provided by the platform team. `SERVICE_CONNECTION` is created in **Project Settings > Service Connections**.

- `AGENT_POOL` — Name of the self-hosted Azure DevOps agent pool registered for this project. Example: `<agent-pool-name>`
- `SERVICE_CONNECTION` — Name of the Azure DevOps service connection scoped to the deployment subscription. Example: `<service-connection-name>`
- `SERVICE_CONNECTION_NAME` — Alias used by pipeline tasks that reference the connection by name. Set to the same value as `SERVICE_CONNECTION`. Example: `<service-connection-name>`

---

#### C. OpenTofu Backend State Storage

> All values below are created by the **bootstrap pipeline**. Run bootstrap first, then read the values from AWS Console or pipeline logs.

- `TFSTATE_BUCKET_NAME` — S3 Bucket name for OpenTofu remote state 
  - Pattern: `dpn-tfstate-part-001`
- `TFSTATE_KEY` — Name for the state file inside the `tfstate` S3 key. Must be unique per environment and never change across runs.
  - Pattern: `dpn.<env>.tfstate`
- `TFSTATE_DYNAMODB_TABLE` — DynamoDB Lock table used for locking the state.
  - Pattern: `dpn.tfstate.lock`
---

#### D. Virtual Private Cloud (VPC)

> Obtain from the connectivity/networking team. These resources must exist before the bootstrap pipeline runs.

- `EXISTING_VPC_ID` — Id of the pre-existing VPC. Example: `<vpc-xxxxxxxxxxxxxx>`

---

#### F. Pipeline YAML-Defined Variables

> Set directly in the pipeline YAML file — **not** in the Library Variable Group.

- `TF_WORKING_DIR` — Repo-relative path to the environment folder containing `main.tf` and `environments/`. Use the folder name at the repository root that matches the target environment. Example: `<repo-environment-folder-name>`
- `TFVARS_FILE` — Exact `.tfvars` filename under `$(TF_WORKING_DIR)/environments/`. The file must exist before the pipeline runs. Example: `<env-name>.tfvars`
- `OPENTOFU_VERSION` — OpenTofu CLI version pinned for all pipeline tasks. Do not change without regression testing. Recommended: `1.9.0`
- `Environment.Name` — This is the environment value. Example  `part-001`

### Step 0.2 Authenticate and Select Account

Authentication is provided by the Azure DevOps service connection.
Use this pipeline task command to validate the AWS Identity and Account. 

```bash
aws sts get-caller-identity
```

### Step 0.3 Validate Tooling and Required Files

Use the following pipeline task checks to verify tooling and required files are available.

```bash
aws --version
tofu version

cd $(TF_WORKING_DIR)
test -f "environments/$(TFVARS_FILE)"
```

If the tfvars file check fails, create `environments/$(TFVARS_FILE)` before running the deployment pipeline.

---

## Phase 1: Bootstrap Infrastructure
This section contains CICD pipeline definitions for deploying AWS Bootstrap Infrastructure

- Azure DevOps Pipelines
  Located in .azure-pipelines
    - aws-pipeline-bootstrap-001.yml - Bootstrap pipeline for Azure DevOps

### Step 1.0 Use the Bootstrap Pipeline

Always run the bootstrap pipeline first for a new environment, or whenever backend/state prerequisites are missing.

Bootstrap pipeline usage:

- Use `aws-pipeline-bootstrap-*.yml` pipeline if using Azure DevOps and `aws-pipeline-bootstrap-*.yml` workflow if using GitHub Actions for the target environment.
- Use it to create or validate the backend S3 state bucket, DynamoDB state lock table, kms key, CloudTrail and CloudWatch Logs. 
- Bootstrap is only required once per AWS environment.
- If bootstrap resources already exist, the pipeline should complete through the bootstrap check/skip path.

### Step 1.1 Check Bootstrap State

The pipeline automatically handles bootsrap deployment

- Check if bootstrap already exists ( S3 state bucket + DynamoDB state lock table ).
- Skips deployment if resources are present.
- Deploys bootstrap if resources are missing. 

### Step 1.2 State Management

- During the initial bootstrap, state is stored locally in bootstrap.tfstate file (chicken-and-egg problem). This ensures bootstrap can create the S3 state backend without circular dependencies.

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

### Step 1.3 Deploy Bootstrap from command line

- Navigate to Bootstrap
```bash
cd infrastructure/Tofu/bootstrap
pwd  # Verify: .../infrastructure/Tofu/bootstrap

- Initialize Bootstrap
```bash
# Initialize OpenTofu (uses local backend initially)
tofu init

# Output should show:
# Initializing the backend...
# Terraform has been successfully configured!

- Review Bootstrap Plan
```bash
  # Review what will be created
  tofu plan -var-file=environments/part.tfvars

  # Output shows:
  #   aws_s3_bucket (state bucket)
  #   aws_dynamodb_table (lock table)
  #   aws_kms_key (encryption key)
  #   aws_cloudtrail (audit logging)
  #   ~15 resources total

- Apply Bootstrap
```bash
  # Create S3 bucket, DynamoDB table, KMS key
  tofu apply -var-file=environments/part.tfvars

  # Type: yes to confirm

  # Output shows:
  #   Outputs:
  #   state_bucket_name = "dpn-state-{account-id}"
  #   lock_table_name = "dpn-lock-{account-id}"
  #   backend_config = "..."

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

- (Optional) Bootstrap Validation
```bash
  # Verify S3 bucket was created
  aws s3 ls | grep dpn-state

  # Verify DynamoDB table was created
  aws dynamodb list-tables | grep dpn-lock

  # Verify KMS key was created
  aws kms describe-key --key-id alias/dpn-state


## Phase 2: Initialize and Plan

This phase is executed in the main infrastructure pipeline.

### Step 2.1 Prepare Environment tfvars

Verify tfvars file existence in pipeline working directory.

```bash
cd $(TF_WORKING_DIR)
test -f "environments/$(TFVARS_FILE)"
```

### Step 2.2 Initialize OpenTofu

Use the following pipeline task command to initialize OpenTofu with the configured backend.

```
# Read bootstrap outputs
cat bootstrap/backend_config.txt

# Extract values (or copy from bootstrap output)
# Example:
export BUCKET="dpn-state-123456789012"
export TABLE="dpn-lock-123456789012"

# Initialize with remote backend
tofu init \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="dynamodb_table=${TABLE}" \
  -backend-config="key=part" \
  -backend-config="region=eu-west-2"

# Type: yes to confirm backend migration
# Output: Successfully configured backend
```

### Step 2.3 Plan Infrastructure

Main pipeline behavior is controlled by `action` parameter:

- `plan` → runs OpenTofu plan and publishes plan artifact
- `apply` → runs plan, optional manual approval, then apply
- `destroy` → routed through destroy path/pipeline

Plan command in pipeline:

```bash
tofu plan \
  -var-file=environments/$(TFVARS_FILE) \
  -out=tfplan \
  -parallelism=4
```

Optional (advanced): If troubleshooting, you can target a specific module with
`-target=module.<module_name>` only after you confirm the module name in your root `main.tf`.

Apply workflow behavior:

- Temporarily removes CanNotDelete lock on `$(VNET_RESOURCE_GROUP)`
- Runs `tofu apply -var-file=environments/$(TFVARS_FILE) -auto-approve`
- Restores the CanNotDelete lock after apply (always)

Validation:

```bash
az network vnet show -g "$(VNET_RESOURCE_GROUP)" -n "$(VNET_NAME)" --output table
az network vnet subnet list -g "$(VNET_RESOURCE_GROUP)" --vnet-name "$(VNET_NAME)" --output table
az network nsg list -g "$(VNET_RESOURCE_GROUP)" --output table
```

---

## Phase 3: Validate Core Services

Use the following steps to deploy the shared security services.

### Step 3.1 Validate Security Module Components

If your deployment completed successfully in Phase 2, verify key security services are present and healthy.

Validation:

```bash
aws kms describe-key --key-id <your-key-id-or-arn-or-alias>
aws iam get-role --role-name $(echo "arn:aws:iam::123456789012:role/eks_cluster_role" | awk -F'/' '{print $NF}')
aws iam get-role --role-name $(echo "arn:aws:iam::123456789012:role/eks_node_role" | awk -F'/' '{print $NF}')

```

---

## Phase 4: Compute Platform

Use the following steps to deploy the compute platform components.

### Step 4.1 Validate Compute Components

If ECR and EKS are part of your stack, validate cluster access and node readiness.

Validation:

```bash
# Get kubeconfig
aws eks update-kubeconfig --name dpn-part --region eu-west-2

# Verify connection
kubectl cluster-info
kubectl get nodes
```

### Step 4.2 VM Validation

Validate provisioning and access posture for the management/jump VM.

```bash
aws ec2 describe-instances --instance-ids <management-host-id>
aws ec2 describe-instances --instance-ids <management-host-id> --query "Reservations[*].Instances[*].<${var.project_name}-mgmt-host-${var.environment}>"

```

---

## Phase 5: Storage & Messaging Services

Use the following steps to deploy the required storage and file scanning messaging services.

### Step 5.1 Deploy S3 Buckets

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

### Step 5.2 Deploy Azure File Share

If developer storage components are defined in your stack, verify the Azure Files share is created and accessible via private endpoint.

Validation:

```bash
# List file shares in the developer storage account
az storage share list \
  --account-name "<application-storage-account-name>" \
  --account-key "<storage-key>" \
  --output table

# Verify private endpoint connectivity
az network private-endpoint list \
  --resource-group "<application-storage-resource-group>" \
  --query "[?contains(name, 'file-pe')].name" -o table

# Test file share access (requires storage account key or SAS token)
az storage file list \
  --share-name "<file-share-name>" \
  --account-name "<application-storage-account-name>" \
  --account-key "<storage-key>"
```

Expected output: File share exists and is accessible through private endpoint.

### Step 5.6 Validate Observability Logging Storage Account

If the observability logging storage account is part of your stack, verify it and its private endpoint(s) after full apply.

```bash
az storage account show \
  --name "<observability-logging-storage-account-name>" \
  --resource-group "<observability-logging-storage-resource-group>" \
  --query "{name:name, sku:sku.name, publicNetworkAccess:publicNetworkAccess}" -o table

az network private-endpoint list \
  --resource-group "<observability-logging-storage-resource-group>" \
  --query "[?contains(name, 'pe-') || contains(name, '-blob-pe') || contains(name, '-file')].name" -o table

az role assignment list --scope "$(az storage account show --name "<observability-logging-storage-account-name>" --resource-group "<observability-logging-storage-resource-group>" --query id -o tsv)" -o table
```

Expected output: storage account exists with public network access disabled, the blob private endpoint (and file endpoint if enabled) is connected, and any expected `Storage Blob Data Reader` / `Storage Blob Data Contributor` role assignments (if principal IDs were configured) are present.

---

## Phase 6: Validation and Testing

Use the following steps to validate the completed infrastructure deployment.

### Step 6.1 Complete Remaining Deployments

Use the following pipeline task commands to apply any remaining unmanaged OpenTofu changes.

```bash
tofu plan -var-file=environments/$(TFVARS_FILE) -out=tfplan-complete
tofu apply tfplan-complete
```

Expected result: no changes (or only intentional drift remediation).

### Step 6.2 Infrastructure Validation

Use the following pipeline validation task commands to confirm the deployed services are healthy.

```bash
az network vnet show -g "$(VNET_RESOURCE_GROUP)" -n "$(VNET_NAME)" --query "addressSpace.addressPrefixes"
az network nsg list -g "$(VNET_RESOURCE_GROUP)" --query "[].name" -o table
az network private-endpoint list -g "$(VNET_RESOURCE_GROUP)" --query "[].name" -o table

kubectl get nodes
kubectl get pods -A
kubectl cluster-info

az keyvault secret list --vault-name "<keyvault-name>"
```


## Post-Deployment Configuration

Use the following post-deployment steps to complete operational setup.
These actions are not part of the current base infrastructure deployment pipeline.
Use them only through a separate operations pipeline or controlled runbook if your organisation requires them.

### 10.1 Configure Monitoring

Example Azure CLI command to enable monitoring for the AKS cluster.

```bash
az aks enable-addons \
  --resource-group "<aks-resource-group>" \
  --name "<aks-name>" \
  --addons monitoring \
  --workspace-resource-id "/subscriptions/$(ARM_SUBSCRIPTION_ID)/resourceGroups/<log-analytics-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<log-analytics-workspace>"
```

### 10.2 Configure Alerts

Example Azure CLI command to create a baseline operational alert.

```bash
az monitor metrics alert create \
  --name "AKS-High-CPU" \
  --resource-group "<aks-resource-group>" \
  --scopes "/subscriptions/$(ARM_SUBSCRIPTION_ID)/resourceGroups/<aks-resource-group>/providers/Microsoft.ContainerService/managedClusters/<aks-name>" \
  --condition "avg Percentage CPU > 80" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --description "Alert when AKS CPU exceeds 80%"
```

### 10.3 Configure Backup

Example Azure CLI command to provision the recovery services vault.

```bash
az backup vault create \
  --resource-group "<infra-resource-group>" \
  --name "<recovery-services-vault-name>" \
  --location "$(AZURE_LOCATION)"
```

### 10.4 Document Deployment

Example commands to capture the deployed resource inventory for operational handover.

```bash
aws resource-explorer-2 search --query-string "arn" --query "Resources[*].Arn" --output text
tofu show -json | jq '.values.root_module.resources[] | {type, name}' > tofu-resources.json
```

### 10.5 Prepare for Application Deployment

After infrastructure deployment completes successfully, prepare handoff documentation for the application deployment team.

**Export Infrastructure Outputs:**

OpenTofu outputs contain critical information needed for application deployment configuration. Export these values:

```bash
# Retrieve OpenTofu outputs for application team
tofu output -json > infrastructure-outputs.json
```

### 10.6 Pipeline Execution and Connectivity Validation

Validate that deployment connectivity works as expected:

```text
Agent --> ADO Repo --> Pipeline --> Service Principal --> AWS
Agent --> GitHub repo -> Workflow --> AWS Credentials --> AWS
```

Checklist:

- Self-hosted agent can access Azure DevOps/GitHub repository and fetch repository.
- Pipeline/workflow references the intended service connection
- Service principal has required RBAC scope.
- OpenTofu operations succeed without interactive login.

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

The application deployment guide references:

- Azure DevOps pipeline/GitHub actions workflows setup for CI/CD
- Self-hosted agent configuration for application builds
- Container registry configuration for image storage
- Helm chart customization for deployment to EKS

---

Continue with [04-rollback-procedures.md](04-rollback-procedures.md)