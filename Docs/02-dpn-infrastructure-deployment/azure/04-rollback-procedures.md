# 04 - Rollback Procedures

This section explains how to roll back failed or partial infrastructure deployments.

## Purpose

This document provides rollback and recovery actions for failed or partially successful deployments.

---

## 1. Rollback Principles

Use the following principles to guide safe and controlled rollback decisions.

- Prefer Terraform-managed rollback over manual deletion.
- Roll back only the failed module first; avoid broad destructive actions.
- Capture current state and plan output before remediation.
- Use maintenance windows for production rollback.

## 2. Immediate Safety Actions

Take the following immediate actions as soon as a deployment issue is detected.

- Pause further pipeline or manual applies.
- Export current Terraform state snapshot.
- Save current `terraform plan` output for audit trail.

```bash
cd infrastructure/terraform
terraform state pull > terraform.tfstate.rollback.backup
terraform plan -var-file="environments/my-deployment.tfvars" -out=tfplan-investigation
```

## 3. Module-Level Rollback

Use the following approach to roll back a single affected module.

If a specific module introduces invalid resources, perform a targeted destroy for that module only.

```bash
terraform plan \
  -var-file="environments/my-deployment.tfvars" \
  -destroy \
  -target=module.<module_name> \
  -out=tfplan-rollback-module

terraform apply tfplan-rollback-module
```

Re-apply with corrected parameters:

```bash
terraform plan -var-file="environments/my-deployment.tfvars" -target=module.<module_name> -out=tfplan-redeploy-module
terraform apply tfplan-redeploy-module
```

## 4. Commit-Based Rollback (Recommended for Bad IaC Changes)

Use this rollback path when the failure is caused by a recent code/configuration commit.

If you revert to the previous known-good commit (or revert commit) and run the deployment pipeline again with `apply`, Terraform reconciles resources back to that previous desired state.

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

- `terraform apply` does not "undo" by itself; it applies the current code in the repo.
- To roll back infrastructure behavior, the desired state in Git must first be rolled back.
- Always review the rollback `plan` output before `apply`.

## 5. Common Issues

Review the following common issues and their suggested remediation steps.

### Issue: Terraform State Lock

Use the following commands if Terraform reports a locked state file.

Symptom: `Error acquiring state lock`

```bash
terraform force-unlock <LOCK-ID>
az storage blob show \
  --account-name <state-storage-account> \
  --container-name tfstate \
  --name dpn-<env>.terraform.tfstate \
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

## 6. Full Environment Rollback (Last Resort)

Use the following steps only when targeted rollback is not sufficient.

Use only when module rollback is not sufficient.

```bash
terraform plan -destroy -var-file="environments/my-deployment.tfvars" -out=tfplan-destroy-all
terraform apply tfplan-destroy-all
```

## 7. Post-Rollback Validation

Perform the following checks to confirm the environment is stable after rollback.

- Validate resource inventory in affected resource groups.
- Confirm Terraform state is consistent.
- Re-run plan and verify no unexpected drift.

```bash
az resource list --resource-group <resource-group-name> --output table
terraform plan -var-file="environments/my-deployment.tfvars"
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