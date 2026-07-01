# 04 - Rollback Procedures

This section explains how to roll back failed or partial infrastructure deployments.

## Table of Contents

- [04 - Rollback Procedures](#04---rollback-procedures)
  - [Purpose](#purpose)
  - [1. Rollback Principles](#1-rollback-principles)
  - [2. Immediate Safety Actions](#2-immediate-safety-actions)
  - [3. Module-Level Rollback](#3-module-level-rollback)
  - [4. Commit-Based Rollback (Recommended for Bad IaC Changes)](#4-commit-based-rollback-recommended-for-bad-iac-changes)
  - [5. Common Issues](#5-common-issues)
    - [Issue: OpenTofu State Lock](#issue-opentofu-state-lock)
    - [Issue: AKS Deployment Fails](#issue-aks-deployment-fails)
    - [Issue: Private Endpoint DNS Not Resolving](#issue-private-endpoint-dns-not-resolving)
    - [Issue: Workload Identity Not Working](#issue-workload-identity-not-working)
    - [Issue: VM Provisioned but Not Reachable](#issue-vm-provisioned-but-not-reachable)
    - [Issue: Pipeline Fails with Authorization Errors](#issue-pipeline-fails-with-authorization-errors)
    - [Issue: File Scanning Service Component Fails to Provision](#issue-file-scanning-service-component-fails-to-provision)
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

## 2. Immediate Safety Actions

Take the following immediate actions as soon as a deployment issue is detected.

- Pause further pipeline or manual applies.
- Export current OpenTofu state snapshot.
- Save current `tofu plan` output for audit trail.

```bash
cd infrastructure/opentofu
tofu state pull > opentofu.tfstate.rollback.backup
tofu plan -var-file="environments/my-deployment.tfvars" -out=tfplan-investigation
```

## 3. Module-Level Rollback

Use the following approach to roll back a single affected module.

If a specific module introduces invalid resources, perform a targeted destroy for that module only.

```bash
tofu plan \
  -var-file="environments/my-deployment.tfvars" \
  -destroy \
  -target=module.<module_name> \
  -out=tfplan-rollback-module

tofu apply tfplan-rollback-module
```

Re-apply with corrected parameters:

```bash
tofu plan -var-file="environments/my-deployment.tfvars" -target=module.<module_name> -out=tfplan-redeploy-module
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

## 5. Common Issues

Review the following common issues and their suggested remediation steps.

### Issue: OpenTofu State Lock

Use the following commands if OpenTofu reports a locked state file.

Symptom: `Error acquiring state lock`

```bash
tofu force-unlock <LOCK-ID>
az storage blob show \
  --account-name <state-storage-account> \
  --container-name tfstate \
  --name dpn-<env>.opentofu.tfstate \
  --query "properties.lease"
```

### Issue: AKS Deployment Fails

Use the following checks when AKS deployment fails because of quota or timeout issues.

Symptom: `InsufficientQuota` or timeout errors

```bash
az vm list-usage --location <azure-region> --output table
```

Mitigation:
- Request quota increase.
- Temporarily reduce node count / VM SKU.

### Issue: Private Endpoint DNS Not Resolving

Use the following commands to troubleshoot private endpoint DNS resolution.

```bash
az network private-dns link vnet list \
  --resource-group rg-pdns-dpn-<env>-<instance> \
  --zone-name privatelink.vaultcore.azure.net

kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  nslookup kv-dpn-<env>-<instance>.vault.azure.net
```

### Issue: Workload Identity Not Working

Use the following checks to troubleshoot workload identity configuration issues.

```bash
az aks show -g rg-aks-dpn-<env>-<instance> -n aks-dpn-<env>-<instance> --query "oidcIssuerProfile"
az identity federated-credential list --identity-name <workload-identity-name> --resource-group <identity-rg>
kubectl describe pod <pod-name> -n <namespace>
```

### Issue: VM Provisioned but Not Reachable

Use the following checks when a management/jump VM is created but cannot be accessed.

```bash
az vm get-instance-view --resource-group <vm-rg> --name <vm-name> --query "instanceView.statuses[].displayStatus" -o table
az network nic show --resource-group <vm-rg> --name <vm-nic-name> --query "ipConfigurations[].privateIPAddress" -o table
az network nsg rule list --resource-group <vm-rg> --nsg-name <vm-nsg-name> -o table
```

Mitigation:
- Verify subnet route/NSG rules permit required management path.
- Validate private DNS resolution and jump-host path if no public IP is used.

### Issue: Pipeline Fails with Authorization Errors

Use the following checks when deployment pipeline reports `AuthorizationFailed` or `Forbidden`.

```bash
az role assignment list --assignee <service-principal-object-id> --all -o table
az account show --output table
```

Mitigation:
- Confirm pipeline uses the intended service connection.
- Ensure service principal has required RBAC at correct scope.
- Re-run after RBAC propagation delay.

### Issue: File Scanning Service Component Fails to Provision

Use the following checks when the Event Grid topic, Service Bus namespace, or file scanning storage account fails to deploy or its private endpoint does not connect.

```bash
az eventgrid topic show --name <event-grid-topic-name> --resource-group <event-grid-resource-group> --query "provisioningState"
az servicebus namespace show --name <service-bus-namespace-name> --resource-group <service-bus-resource-group> --query "status"
az network private-endpoint show --name <private-endpoint-name> --resource-group <resource-group-name> --query "privateLinkServiceConnections[].privateLinkServiceConnectionState"
```

Common causes:
- Service Bus namespace SKU is not `Premium` (required for private endpoints).
- The dedicated subnet for the component (Event Grid, Service Bus, or file scanning storage) does not exist yet or has `private_endpoint_network_policies` set incorrectly.
- RBAC role assignment principal IDs (`event_grid_*_principal_ids`, `service_bus_*_principal_ids`, `file_scanning_service_storage_*_principal_ids`) reference an object ID that does not exist in the tenant.

Mitigation:
- Roll back the specific module only, following [Section 3](#3-module-level-rollback) (for example `-target=module.event_grid`, `-target=module.service_bus`, or `-target=module.file_scanning_service_storage`).
- Re-validate subnet and SKU configuration before re-applying.

## 6. Full Environment Rollback (Last Resort)

Use the following steps only when targeted rollback is not sufficient.

Use only when module rollback is not sufficient.

```bash
tofu plan -destroy -var-file="environments/my-deployment.tfvars" -out=tfplan-destroy-all
tofu apply tfplan-destroy-all
```

## 7. Post-Rollback Validation

Perform the following checks to confirm the environment is stable after rollback.

- Validate resource inventory in affected resource groups.
- Confirm OpenTofu state is consistent.
- Re-run plan and verify no unexpected drift.

```bash
az resource list --resource-group <resource-group-name> --output table
tofu plan -var-file="environments/my-deployment.tfvars"
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