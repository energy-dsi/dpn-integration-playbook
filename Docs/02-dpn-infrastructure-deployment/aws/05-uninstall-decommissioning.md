# 05 - Uninstall & Decommissioning

This section explains how to uninstall and decommission the deployed infrastructure.

## Table of Contents

- [Purpose](#purpose)
- [1. Prerequisites](#1-prerequisites)
- [2. Backup State (Recommended)](#2-backup-state-recommended)
- [3. Review Destroy Plan](#3-review-destroy-plan)
- [4. Destroy Managed Infrastructure](#4-destroy-managed-infrastructure)
- [5. Verify Cleanup](#5-verify-cleanup)
- [6. Restore Previous State (If Required)](#6-restore-previous-state-if-required)
- [7. Decommissioning Checklist](#7-decommissioning-checklist)
- [8. References](#8-references)

## Purpose

This document describes how to safely remove DPN participant infrastructure and complete decommissioning activities.

---

## 1. Prerequisites

Confirm the following prerequisites before starting any uninstall or decommissioning activity.

- OpenTofu 1.0+
- AWS CLI access to target account
- Permissions to delete resources
- Approved decommissioning window and change record

## 2. Backup State (Recommended)

Run the following command to back up the current OpenTofu state before any removal actions.

```bash
cd infrastructure/opentofu
tofu state pull > opentofu.tfstate.backup
```

## 3. Review Destroy Plan

Run the following command to review the proposed destroy actions before execution.

```bash
tofu plan -destroy -var-file=environments/<env>.tfvars
```

## 4. Destroy Managed Infrastructure

Run the following commands to remove OpenTofu-managed infrastructure resources.

Warning: This action is irreversible.

```bash
tofu destroy -var-file=environments/<env>.tfvars
```

## 5. Verify Cleanup

Run the following command to confirm resources have been removed from AWS.

```bash
aws resource-explorer-2 search --query-string "arn" --query "Resources[*].Arn" --output text
```

Also verify all S3 buckets are handled as expected:

- OpenTofu state S3 bucket (backend)
- Application/workload S3 buckets
- Observability logging S3 buckets

Verify AWS EFS cleanup:

```bash
# Confirm file share is removed
aws efs describe-file-systems \
  --query "FileSystems[?Name=='<efs-name>'].FileSystemId" \
  --output table

# Confirm all specific S3 buckets are removed (if not retained) including observability S3 buckets.
aws s3 ls s3://<bucket-name>
```

perform manual cleanup if needed. 

## 6. Restore Previous State (If Required)

Run the following command only if the previous OpenTofu state must be restored.

```bash
tofu state push opentofu.tfstate.backup
```

## 7. Decommissioning Checklist

Use the following checklist to verify the decommissioning process is fully complete.

- Resources reviewed and approved for removal
- OpenTofu state backup captured
- `tofu destroy` completed successfully
- Backend and residual manual resources removed
- Access roles, service principals, and secrets rotated or retired
- Internal documentation and CMDB/asset records updated

## 8. References

Refer to the following documentation for detailed product guidance.

- [OpenTofu Destroy Documentation](https://opentofu.org/docs/cli/commands/destroy/)
- [AWS CLI Documentation](//https://docs.aws.amazon.com/cli/)

Deployment Complete! 🎉