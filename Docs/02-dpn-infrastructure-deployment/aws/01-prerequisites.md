# 01 - Prerequisites

This section introduces the prerequisites for infrastructure deployment.

- [01 - Prerequisites](#01---prerequisites)
  - [Purpose](#purpose)
  - [1. Overview](#1-overview)
    - [What You'll Deploy](#what-youll-deploy)
    - [Deployment Architecture](#deployment-architecture)
  - [2. Azure Subscription Requirements](#2-azure-subscription-requirements)
  - [3. Entra ID / Identity Requirements](#3-entra-id--identity-requirements)
  - [4. Tooling Requirements](#4-tooling-requirements)
    - [Required](#required-tools)
    - [Optional](#optional)
  - [5. Planning Inputs](#5-planning-inputs)
  - [6. Naming Convention](#6-naming-convention)
  - [7. Pre-Deployment Decisions](#7-pre-deployment-decisions)
  - [8. Service Principal and Pipeline Trust Model](#8-service-principal-and-pipeline-trust-model)
    - [Recommended Model](#recommended-model)
    - [Minimum Identity Requirements](#minimum-identity-requirements)
    - [Why this matters](#why-this-matters)
  - [9. Access and Authentication](#9-access-and-authentication)
  - [10. Self-Hosted Agent Requirements](#10-self-hosted-agent-requirements)
    - [Self-Hosted Agent Setup](#self-hosted-agent-setup)
    - [Agent Pool Configuration](#agent-pool-configuration)
  - [11. Azure File Share Details](#11-azure-file-share-details)
    - [What is created](#what-is-created)
    - [Key configuration values](#key-configuration-values)
    - [Deployment behavior](#deployment-behavior)
    - [Why this matters](#why-this-matters-1)
  - [12. Observability Logging Storage Account](#13-observability-logging-storage-account)
    - [What is created](#what-is-created-2)
    - [Key configuration values](#key-configuration-values-2)
    - [Deployment behavior](#deployment-behavior-2)
    - [Why this matters](#why-this-matters-3)

## Purpose

This document lists the prerequisites and pre-deployment checks for DPN participant infrastructure deployment in AWS.

---

## 1. Overview

You will deploy the DPN reference architecture in phases to reduce deployment risk and simplify validation.

### What You'll Deploy

The following core infrastructure components are included in this deployment scope.

- Virtual Private Network (VPC) with segmented subnets
- Elastic Kubernetes Service (EKS) Clusters
- Elastic Container Registry (ECR)
- Private worker nodes (optional)
- Management Host
- AWS Load Balancer Controller
- NLB support with static public IPs
- S3 buckets for tf state storage and application use
- IAM roles and IRSA for kubernetes workloads
- Secrets Manager secrets
- GuardDuty findings integration
- GuardDuty Malware protection for S3
- EventBridge and SNS Notifications
- VPC Flowlogs
- CloudWatch Log Groups
- Dev and Test backend state configuration
- Observability Logging S3 buckets (dedicated S3 buckets for centralized log/diagnostic export)


### Deployment Architecture

The following diagram shows the high-level deployment architecture for the target environment.

```text
┌─────────────────────────────────────────────────────┐
│           Your AWS Account                          │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  Bootstrap (Phase 1)                         │   │
│  │  • S3 Bucket for storing OpenTofu state files│   │
│  │  • DynamoDB state lock table (OpenTofu State)│   │
│  │  • KMS Key for encrypting state files        |   |
|  |  • IAM policies for state access             |   |
|  |  • CloudWatch Logs                           |   |
│  │                                              |   |
│  └──────────────────────────────────────────────┘   │
│                      ↓                              │
│  ┌──────────────────────────────────────────────┐   │
│  │  Core Infrastructure (Phases 2-5)            │   │
│  │  • VPC with segmented subnets                │   │
│  │  • Network Security Groups                   │   │
│  │  • EKS Cluster                               │   │
│  │  • Elastic Container Registry (ECR)          │   │
│  │  • Secrets Manager                           │   │
│  │  • Log Groups Workspace                      │   │
│  │  • Application/Developer S3 Accounts         │   │
│  │  • IAM Role for Service Accounts (IRSA)      │   │
│  │  • AWS Load Balancer Controller              │   │
│  │  • AWS DB Instance (PostGreSQL)              │   │
│  │  • Elastic File Service (AWS EFS)            │   │
│  │  • Management Host                           │   │
│  │  • Observability Logging S3 Buckets          │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

---

## 2. AWS Account Requirements

Ensure the AWS Account is ready and validated against the following requirements.

- Target AWS Account
- IAM Permissions: Administrator or equivalent permissions
- Account ID captured (`xxxxxxxxxxxx`)
- Regional quota available:
  - EKS Clusters: >= 1
  - EC2 Instances: >= 10 (for Auto Scaling Group)
  - RDS Instances >= 1
  - VPC/Security Groups: Standard Limits
  - Public IP requirement depends on your organisation network architecture; private deployments may require none
- Region selected: <aws-region>
- No conflicting IP ranges; use customer-safe example CIDR such as `10.x.x.x/27`

## 3. Identity Requirements

Confirm the required identity and access capabilities are available before deployment.

- Infrastructure deployments use AWS IAM Identity Center (AWS SSO)
- No long-lived IAM users or access keys are required. 
- Make sure required profiles are created. Expected AWS CLI profiles
  - dpn-dev
  - dpn-test
- Verify the active identity using get-caller-identity.

## 4. Tooling Requirements

Use the following tooling guidance to prepare the deployment workstation.

### Required Tools

The following software must be installed before running deployment and application pipelines:

- Git v2.48+  
- Python 3.10 or 3.11  
- OpenSSL (latest version)  
- AWS CLI v2 latest version  
- kubectl (latest version)
- Helm (latest version)  
- Infrastructure-as-code tool: OpenTofu
- jq (JSON processing - optional but recommended)

## 5. Planning Inputs

Capture the following planning inputs before deployment begins.

| Parameter                      | Your Value        | Example                                    |
|--------------------------------|-------------------|--------------------------------------------|
| AWS Account ID                | _________________ | `000000000000`     |
| Environment Name               | _________________ | `dev`, `test`, `preprod`, `prod`           |
| Instance Number                | _________________ | `01`, `02`, `03`                           |
| VPC CIDR                      | _________________ | `10.x.x.x/27`                              |
| Connectivity Sub ID (optional) | _________________ | For Private DNS zones                      |

## 6. Naming Convention

Use the following naming patterns to keep deployed resources consistent.

Common pattern used is: `{resource-type-abbreviation}-dpn-{env}-{instance}`. Following table is the example.

| Resource Type   | Pattern                     | Example                |
|-----------------|-----------------------------|------------------------|
| VPC             | `vpc-dpn-{env}-{instance}`  | `vpc-dpn-preprod-01`   |
| EKS Cluster     | `eks-dpn-{env}-{instance}`  | `eks-dpn-preprod-01`   |
| Key Vault       | `kv-dpn-{env}-{instance}`   | `kv-dpn-preprod-01`    |

## 7. Pre-Deployment Decisions

Agree the following deployment choices with stakeholders before proceeding.

- Target AWS region and naming standard for the environment
- organisation network architecture and private DNS ownership model
- Whether service mesh / Istio is required for the platform
- Change approval, deployment window, and rollback ownership

## 8. Service Principal and Pipeline Trust Model ( check if this is required )

Define how deployment identity and pipeline execution are connected before first run.

### Recommended Model

```text
Self-Hosted Agent
  → Azure DevOps Repo
  → Azure DevOps Pipeline
  → Service Connection (Service Principal)
  → AWS Account (target AWS Account)
```

### Minimum Identity Requirements

The security module establishes the foundational security infrastructure for the AWS deployment, including:

- KMS Key - AWS Key Management Service key for encrypting sensitive data across all services
- EKS Cluster IAM Role - Service role that allows EKS control plane to manage AWS resources
- EKS Node IAM Role - Service role for EC2 instances running as Kubernetes nodes
- IAM Policies - Managed and custom policies for least-privilege access

### Why this matters

- Keeps deployment identity non-human and auditable
- Separates developer access from runtime deployment permissions
- Supports controlled least-privilege access

## 9. Access and Authentication

Complete the following access and authentication steps before running deployment commands.

- create a GitHub account user id and PAT token with minimal capability to pull from repo

- Clone repo:
   ```bash
  git clone https://github.com/energy-dsi/dpn-infrastructure-aws
  cd NESO-DSI-DPN-INFRA-PART_AWS
  ls -la
  # You should see:
    #   infrastructure/
    #   README.md (this file)
    #   .github/
    #   .azure-pipelines/
   ```
- Configure AWS Credentials:
   ```bash
    # Method 1: AWS CLI (interactive)
    aws configure

    # Verify credentials work
    aws sts get-caller-identity
    # Output should show your Account ID and ARN

    # Verify region is set
    aws configure get region  # Should output: eu-west-2
   ```

- Verify Repository Structure:
   ```bash
    # Navigate to Tofu directory
    cd infrastructure/Tofu

    # List Modules
    ls -la modules/
    # Output should show compliance, container_registry, database, eks, ingress, 
    # networking, observability, security, workload_identity

    # Check environment config exists
    ls -la environments/part.tfvars
   ```


## 10. Bootstrap AWS State Management

The bootstrap phase creates S3 bucket and DynamoDB table for managing OpenTofu state remotely.

### Navigate to Bootstrap
  cd infrastructure/Tofu/bootstrap
  pwd  # Verify: .../infrastructure/Tofu/bootstrap

### Initialize Bootstrap

- Initialize OpenTofu (uses local backend initially)
  ```bash
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

## 11. AWS EFS Details

This deployment uses AWS EFS storage for application storage, with the file share secured through a private endpoint.

### What is created

- AWS EFS
- AWS EFS private endpoint for secure access from the VPC

### Key configuration values

The following variables are used in the deployment:

- `enable_efs_csi_driver` – The Amazon EFS Container Storage Interface (CSI) driver allows Kubernetes clusters running on AWS to mount Amazon EFS file systems as persistent volumes.

### Why this matters

- Ensures developer storage is provided as a managed EFS file system
- Keeps the EFS traffic private inside the VPC
- Supports secure access to developer storage without exposing the file share over the public internet

## 12. Observability Logging 

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

### Why this matters

- Keeps observability/log data separate from application, developer, and file scanning storage, reducing blast radius and simplifying retention/lifecycle policy per data type
- Keeps log export traffic private inside the VPC via private endpoint
- Supports least-privilege access for log producers and consumers through scoped role assignments

---

Continue with [02-configuration-parameters.md](02-configuration-parameters.md)