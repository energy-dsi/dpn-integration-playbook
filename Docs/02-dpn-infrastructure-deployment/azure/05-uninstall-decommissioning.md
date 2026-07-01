# 05 - Uninstall & Decommissioning

This section explains how to uninstall and decommission the deployed infrastructure.

## Table of Contents

- [05 - Uninstall & Decommissioning](#05---uninstall--decommissioning)
  - [Purpose](#purpose)
  - [1. Prerequisites](#1-prerequisites)
  - [2. Backup State (Recommended)](#2-backup-state-recommended)
  - [3. Review Destroy Plan](#3-review-destroy-plan)
  - [4. Destroy Managed Infrastructure](#4-destroy-managed-infrastructure)
  - [5. Verify Cleanup](#5-verify-cleanup)
  - [6. Manual Cleanup (If Needed)](#6-manual-cleanup-if-needed)
  - [7. Restore Previous State (If Required)](#7-restore-previous-state-if-required)
  - [8. Decommissioning Checklist](#8-decommissioning-checklist)
  - [9. References](#9-references)

## Purpose

This document describes how to safely remove DPN participant infrastructure and complete decommissioning activities.

---

## 1. Prerequisites

Confirm the following prerequisites before starting any uninstall or decommissioning activity.

- OpenTofu 1.0+
- Azure CLI access to target subscription
- Permissions to delete resource groups and dependent resources
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

Run the following command to confirm resources have been removed from Azure.

```bash
az resource list --resource-group <resource-group-name>
```

Also verify all storage accounts are handled as expected:

- OpenTofu state storage account (backend)
- Application/workload storage account
- Developer storage account (Azure Files)
- File scanning service storage account

Verify Azure File Share cleanup:

```bash
# Confirm file share is removed
az storage share list --account-name <application-storage-account-name> --account-key <key>

# Confirm private endpoint is removed
az network private-endpoint list --resource-group <application-storage-resource-group>

# Confirm storage account is removed (if not retained)
az storage account list --query "[?name=='<application-storage-account-name>']"
```

Verify File Scanning Service component cleanup:

```bash
# Confirm Event Grid topic is removed
az eventgrid topic list --resource-group <event-grid-resource-group>

# Confirm Service Bus namespace is removed
az servicebus namespace list --resource-group <service-bus-resource-group>

# Confirm file scanning storage account and its private endpoints are removed
az storage account list --query "[?name=='<file-scanning-storage-account-name>']"
az network private-endpoint list --resource-group <file-scanning-storage-resource-group>
```

## 6. Manual Cleanup (If Needed)

Use the following steps to remove any remaining resources not handled automatically.

If resources were created outside OpenTofu or are retained by policies:

- Resource group deletion:
   ```bash
   az group delete --name <resource-group-name>
   ```
- Backend storage account deletion:
   ```bash
   az storage account delete --name <storage-account-name> --resource-group <rg-name>
   ```
- Key Vault deletion:
   ```bash
   az keyvault delete --name <keyvault-name>
   ```

## 7. Restore Previous State (If Required)

Run the following command only if the previous OpenTofu state must be restored.

```bash
tofu state push opentofu.tfstate.backup
```

## 8. Decommissioning Checklist

Use the following checklist to verify the decommissioning process is fully complete.

- Resources reviewed and approved for removal
- OpenTofu state backup captured
- `tofu destroy` completed successfully
- Azure resource groups verified as removed
- Backend and residual manual resources removed
- Access roles, service principals, and secrets rotated or retired
- Internal documentation and CMDB/asset records updated

## 9. References

Refer to the following documentation for detailed product guidance.

- [OpenTofu Destroy Documentation](https://opentofu.org/docs/cli/commands/destroy/)
- [Azure CLI Documentation](https://learn.microsoft.com/en-us/cli/azure/)

Deployment Complete! 🎉