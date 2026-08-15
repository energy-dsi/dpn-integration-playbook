# 01 - Prerequisites

This section introduces the prerequisites for infrastructure deployment.

- [01 - Prerequisites](#01---prerequisites)
  - [Purpose](#purpose)
  - [1. Overview](#1-overview)
    - [What You'll Deploy](#what-youll-deploy)
    - [Deployment Architecture](#deployment-architecture)
  - [2. AWS Account Requirements](#2-aws-account-requirements)
  - [3. Identity Requirements](#3-identity-requirements)
  - [4. Tooling Requirements](#4-tooling-requirements)
    - [Required](#required-tools)
  - [5. Planning Inputs](#5-planning-inputs)
  - [6. Naming Convention](#6-naming-convention)
  - [7. Pre-Deployment Decisions](#7-pre-deployment-decisions)
  - [8. Access and Authentication](#9-access-and-authentication)
  

## Purpose

This document lists the prerequisites and pre-deployment checks for DPN participant infrastructure deployment in AWS.

---

## 1. Overview

You will deploy the DPN reference architecture in phases to reduce deployment risk and simplify validation.

Infrastructure as Code (IaC) repository for the DPN platform running on AWS.

The platform is implemented using OpenTofu and provides a repeatable, secure deployment of Kubernetes infrastructure across multiple AWS accounts. All environments are deployed using the same codebase and follow a consistent architecture and security baseline.

### What You'll Deploy

The following core infrastructure components are included in this deployment scope.

- Amazon VPC networking
- Public, private and Transit Gateway subnets
- Amazon EKS clusters
- Private worker nodes
- Management host
- AWS Load Balancer Controller
- Network Load Balancer (NLB) support with static public IPs
- Amazon ECR repositories
- Amazon S3 buckets
- AWS IAM roles and IRSA for Kubernetes workloads
- AWS Secrets Manager integration
- Amazon CloudTrail with KMS encryption
- AWS Config
- Amazon GuardDuty
- AWS Security Hub
- GuardDuty Malware Protection for S3
- Amazon EventBridge
- Amazon SNS notifications
- Amazon CloudWatch log groups
- VPC Flow Logs
- Bootstrap infrastructure for remote OpenTofu state


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
│  │  Core Infrastructure (Phase 2)               │   │
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

- IAM Permissions: Administrator or equivalent permissions
- Account ID captured (`xxxxxxxxxxxx`)
- Regional quota available: Examples
  - EKS Clusters: >= 1
  - EC2 Instances: >= 10 (for Auto Scaling Group)
  - RDS Instances >= 1
  - VPC/Security Groups: Standard Limits
  - Public IP requirement depends on your organisation network architecture; private deployments may require none
- Region selected: <aws-region>
- Existing VPC details 

## 3. Identity Requirements

Confirm the required identity and access capabilities are available before deployment.

- Infrastructure deployments use AWS IAM Identity Center (AWS SSO)
- No long-lived IAM users or access keys are required 
- Make sure required AWS SSO profiles are created
- Verify the active identity using get-caller-identity

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
| AWS Account ID                 | _________________ | `xxxxxxxxxxxx`                             |
| Environment Name               | _________________ | `dev-01`, `dev-02`,`prod-01`,`prod-02`     |
| Instance Number                | _________________ | `01`, `02`, `03`                           |
| VPC CIDR                       | _________________ | `10.x.x.x/20`                              |
| Connectivity Sub ID (optional) | _________________ | For Private DNS zones                      |

## 6. Naming Convention

Use the following naming patterns to keep deployed resources consistent.

[Place Holder]

## 7. Pre-Deployment Decisions

Agree the following deployment choices with stakeholders before proceeding.

- Target AWS region and naming standard for the environment
- organisation network architecture and private DNS ownership model
- Change approval, deployment window, and rollback ownership

### Minimum Identity Requirements

The security module establishes the foundational security infrastructure for the AWS deployment, including:

- KMS Key - AWS Key Management Service key for encrypting sensitive data across all services
- EKS Cluster IAM Role - Service role that allows EKS control plane to manage AWS resources
- EKS Node IAM Role - Service role for EC2 instances running as Kubernetes nodes
- IAM Policies - Managed and custom policies for least-privilege access

### Why this matters:

- Keeps deployment identity non-human and auditable
- Separates developer access from runtime deployment permissions
- Supports controlled least-privilege access

## 9. Access and Authentication

Complete the following access and authentication steps before running deployment commands.

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

---

Continue with [02-configuration-parameters.md](02-configuration-parameters.md)