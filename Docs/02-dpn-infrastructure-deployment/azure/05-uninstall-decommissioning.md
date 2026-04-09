# 05 - Uninstall & Decommissioning

This section explains how to uninstall and decommission the deployed infrastructure.

## Purpose

This document describes how to safely remove DPN participant infrastructure and complete decommissioning activities.

---

## 1. Prerequisites

Confirm the following prerequisites before starting any uninstall or decommissioning activity.

- Terraform 1.0+
- Azure CLI access to target subscription
- Permissions to delete resource groups and dependent resources
- Approved decommissioning window and change record

## 2. Backup State (Recommended)

Run the following command to back up the current Terraform state before any removal actions.

```bash
cd infrastructure/terraform
terraform state pull > terraform.tfstate.backup
```

## 3. Review Destroy Plan

Run the following command to review the proposed destroy actions before execution.

```bash
terraform plan -destroy -var-file=environments/<env>.tfvars
```

## 4. Destroy Managed Infrastructure

Run the following commands to remove Terraform-managed infrastructure resources.

Warning: This action is irreversible.

```bash
terraform destroy -var-file=environments/<env>.tfvars
```

## 5. Verify Cleanup

Run the following command to confirm resources have been removed from Azure.

```bash
az resource list --resource-group <resource-group-name>
```

Also verify both storage accounts are handled as expected:

- Terraform state storage account (backend)
- Application/workload storage account

## 6. Manual Cleanup (If Needed)

Use the following steps to remove any remaining resources not handled automatically.

If resources were created outside Terraform or are retained by policies:

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

Run the following command only if the previous Terraform state must be restored.

```bash
terraform state push terraform.tfstate.backup
```

## 8. Decommissioning Checklist

Use the following checklist to verify the decommissioning process is fully complete.

- Resources reviewed and approved for removal
- Terraform state backup captured
- `terraform destroy` completed successfully
- Azure resource groups verified as removed
- Backend and residual manual resources removed
- Access roles, service principals, and secrets rotated or retired
- Internal documentation and CMDB/asset records updated

## 9. References

Refer to the following documentation for detailed product guidance.

- [Terraform Destroy Documentation](https://www.terraform.io/cli/commands/destroy)
- [Azure CLI Documentation](https://learn.microsoft.com/en-us/cli/azure/)

Deployment Complete! 🎉