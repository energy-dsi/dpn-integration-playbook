# 04 - Rollback Procedures

This section explains how to roll back failed or partial infrastructure deployments.

## Table of Contents

- [Purpose](#purpose)
- [1. Rollback Principles](#1-rollback-principles)
- [2. Immediate Safety Actions](#2-immediate-safety-actions)
- [3. Module-Level Rollback](#3-module-level-rollback)
- [4. Commit-Based Rollback (Recommended for Bad IaC Changes)](#4-commit-based-rollback-recommended-for-bad-iac-changes)
- [5. Common Issues](#5-common-issues)
  - [Issue: OpenTofu State Lock](#issue-opentofu-state-lock)
  - [Issue: EKS Deployment Fails](#issue-eks-deployment-fails)
  - [Issue: S3 Bucket Already Exists](#issue-s3-bucket-already-exists)
  - [Issue: Nodes Not Joining Cluster](#issue-nodes-not-joining-cluster)
  - [Issue: Pipeline Fails with Authorization Errors](#issue-pipeline-fails-with-authorization-errors)
  - [Issue: File Scanning Service Component Fails to Provision](#issue-file-scanning-service-component-fails-to-provision)
  - [Issue: Observability Logging Storage Account Fails to Provision](#issue-observability-logging-storage-account-fails-to-provision)
- [6. Full Environment Rollback (Last Resort)](#6-full-environment-rollback-last-resort)
- [7. Post-Rollback Validation](#7-post-rollback-validation)
- [8. Rollback Checklist](#8-rollback-checklist)

## Purpose

This document provides rollback and recovery actions for failed or partially successful deployments.

---

## 1. Rollback Principles

Use the following principles to guide safe and controlled rollback decisions.

- Prefer OpenTofu-managed rollback over manual deletion.
- Roll back only the failed module first; avoid broad destructive actions.
- Capture current state and plan output before remediation.
- Use maintenance windows for production rollback.

---

## 2. Immediate Safety Actions

Take the following immediate actions as soon as a deployment issue is detected.

- Pause further pipeline or manual applies.
- Export current OpenTofu state snapshot.
- Save current `tofu plan` output for audit trail.

```bash
cd infrastructure/Tofu
tofu state pull > opentofu.tfstate.rollback.backup
tofu plan -var-file="environments/<env>.tfvars" -out=tfplan-investigation
```

## 3. Module-Level Rollback

Use the following approach to roll back a single affected module.

If a specific module introduces invalid resources, perform a targeted destroy for that module only.

```bash
tofu plan \
  -var-file="environments/<env>.tfvars" \
  -destroy \
  -target=module.<module_name> \
  -out=tfplan-rollback-module

tofu apply tfplan-rollback-module
```

Re-apply with corrected parameters:

```bash
tofu plan -var-file="environments/<env>.tfvars" -target=module.<module_name> -out=tfplan-redeploy-module
tofu apply tfplan-redeploy-module
```

## 4. Commit-Based Rollback (Recommended for Bad IaC Changes)

Use this rollback path when the failure is caused by a recent code/configuration commit.

If you revert to the previous known-good commit (or revert commit) and run the deployment pipeline again with `apply`, OpenTofu reconciles resources back to that previous desired state.

Typical flow:

1. Identify the commit that introduced the issue.
2. Revert it in source control (or restore the previous known-good commit).
3. Push the change and trigger the infrastructure pipeline.
4. Run pipeline `plan` first, then `apply` after review/approval.

Example (Git):

```bash
git log --oneline
git revert <bad-commit-sha>
git push
```

Important:

- `tofu apply` does not "undo" by itself; it applies the current code in the repo.
- To roll back infrastructure behavior, the desired state in Git must first be rolled back.
- Always review the rollback `plan` output before `apply`.

---

## 5. Common Issues

Review the following common issues and their suggested remediation steps.

### Issue: OpenTofu State Lock

Symptom: `Error acquiring state lock`

- Check if another pipeline is running
- Use force unlock option (with caution)
- Verify DynamoDB table exists and is accessible

Use the following commands if OpenTofu reports a locked state file.

```bash
tofu force-unlock <LOCK-ID>
```

### Issue: EKS Deployment Fails

Use the following checks when EKS deployment fails because of quota or timeout issues.

Symptom: `InsufficientQuota` or timeout errors

AWS Service Quota Exceeded (Infrastructure Level)
- EC2 Fleet Requests Quota (Most Common)
- Network Interface (ENI) or Security Group Limits

Scenario B: Kubernetes ResourceQuotas (Cluster Level)
- Pods Exceed Namespace Quota Limits
- Missing CPU / Memory Limit Definitions

Mitigation:
- Request quota increase.
- Temporarily reduce node count / VM SKU.

### Issue: S3 Bucket Already Exists

If you get an error that the bucket name is taken:

Error: Error creating S3 bucket: BucketAlreadyOwnedByYou
1. Update tfstate_bucket_name in environments/<env>.tfvars
2. Use a globally unique name (S3 bucket names must be globally unique)


### Issue: Nodes Not Joining Cluster

Use the following checks from the management host.

```bash
# Check node status
kubectl get nodes -o wide

# Describe node for events
kubectl describe node {node-name}

# Check node logs
aws ssm start-session --target {instance-id}
tail -f /var/log/cloud-init-output.log
```

## 6. Full Environment Rollback (Last Resort)

Use the following steps only when targeted rollback is not sufficient.

Use only when module rollback is not sufficient.

```bash
tofu plan -destroy -var-file="environments/<env>.tfvars" -out=tfplan-destroy-all
tofu apply tfplan-destroy-all
```

## 7. Post-Rollback Validation

Perform the following checks to confirm the environment is stable after rollback.

- Validate resource inventory in affected resource groups.
- Confirm OpenTofu state is consistent.
- Re-run plan and verify no unexpected drift.

```bash
aws resource-explorer-2 search --query-string "arn" --query "Resources[*].Arn" --output text
tofu plan -var-file="environments/<env>.tfvars"
```

## 8. Rollback Checklist

Use the following checklist to confirm all rollback activities have been completed.

- Captured state backup before rollback
- Identified root cause and impacted module
- Executed least-destructive rollback path
- Revalidated networking, identity, and critical data services
- Logged actions and outcomes for post-incident review

---

Continue with [05-uninstall-decommissioning.md](05-uninstall-decommissioning.md)