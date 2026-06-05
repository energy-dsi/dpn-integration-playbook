# 03 - Installation Process

This section describes the end-to-end infrastructure installation process.

## Table of Contents

- [03 - Installation Process](#03---installation-process)
  - [Purpose](#purpose)

- [Phase 0: Preflight (Required)](#phase-0-preflight-required)
  - [Current ADO Pipeline Stage Sequence (Authoritative)](#current-ado-pipeline-stage-sequence-authoritative)
  - [Step 0.1 Set Deployment Variables](#step-01-set-deployment-variables)
    - [How to Create the Library Variable Group](#how-to-create-the-library-variable-group)
    - [A. Azure Subscription & Environment](#a-azure-subscription--environment)
    - [B. Agent Pool & Service Connection](#b-agent-pool--service-connection)
    - [C. Terraform Backend State Storage](#c-terraform-backend-state-storage)
    - [D. Virtual Network](#d-virtual-network)
    - [E. Private DNS](#e-private-dns)
    - [F. Pipeline YAML-Defined Variables](#f-pipeline-yaml-defined-variables)
  - [Step 0.2 Authenticate and Select Subscription](#step-02-authenticate-and-select-subscription)
  - [Step 0.3 Validate Tooling and Required Files](#step-03-validate-tooling-and-required-files)

- [Phase 1: Bootstrap Infrastructure](#phase-1-bootstrap-infrastructure)
  - [Step 1.0 Use the Bootstrap Pipeline](#step-10-use-the-bootstrap-pipeline)
  - [Step 1.1 Check Bootstrap State](#step-11-check-bootstrap-state)
  - [Step 1.2 Deploy Bootstrap via Subscription-Scope Bicep](#step-12-deploy-bootstrap-via-subscription-scope-bicep)
  - [Step 1.4 Validate Backend Storage Redundancy](#step-14-validate-backend-storage-redundancy)

- [Phase 2: Initialize and Plan](#phase-2-initialize-and-plan)
  - [Step 2.1 Prepare Environment tfvars](#step-21-prepare-environment-tfvars)
  - [Step 2.2 Initialize Terraform](#step-22-initialize-terraform)
  - [Step 2.3 Plan Infrastructure](#step-23-plan-infrastructure)

- [Phase 3: Validate Core Services](#phase-3-validate-core-services)
  - [Step 3.1 Validate Security and Monitoring Components](#step-31-validate-security-and-monitoring-components)

- [Phase 4: Compute Platform](#phase-4-compute-platform)
  - [Step 4.1 Validate Compute Components](#step-41-validate-compute-components)
  - [Step 4.2 VM Validation](#step-42-vm-validation)

- [Phase 5: Storage Services](#phase-5-storage-services)
  - [Step 5.1 Deploy Storage Accounts](#step-51-deploy-storage-accounts)
  - [Step 5.2 Deploy Azure File Share](#step-52-deploy-azure-file-share)

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

This guide assumes a Bash-compatible shell (Azure Cloud Shell, WSL, or Linux/macOS terminal).
It is written for Azure DevOps pipeline execution (not manual/local runs).
Replace all placeholder values before running commands.

> ⚠️ **EXECUTION RULE FOR THIS DOCUMENT**
>
> - **Commands shown below are pipeline task commands executed by Azure DevOps agents.**
> - **Do not run these commands manually unless a step explicitly says manual troubleshooting or marks the command as an optional operational example.**
> - **Ensure variables/service connections are configured in pipeline/library settings before command execution.**

---

## Phase 0: Preflight (Required)

Complete the following preflight steps before starting any deployment activity.

### Current ADO Pipeline Stage Sequence (Authoritative)

Use this stage sequence to understand the current Azure DevOps deployment flow before triggering any pipeline run.

1. **Bootstrap pipeline** (`azure-pipeline-bootstrap-*.yml`)
  - `CheckBootstrap`
  - `DeployBootstrap` (runs only when bootstrap resources are missing)
  - `ConfigureRBAC`
  - `BootstrapSkipped` (runs when bootstrap already exists)

2. **Main infrastructure pipeline** (`azure-pipelines-*.yml`)
  - `Prerequisites`
  - `TerraformDeployment`
    - `TerraformPlan`
    - `ManualApproval` (only when `action=apply` and approval required)
    - `TerraformApply` (only when `action=apply`)
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

#### A. Azure Subscription & Environment

> Get `ARM_SUBSCRIPTION_ID` and `ARM_TENANT_ID` from **Azure portal > Azure Active Directory > Overview**. `ENVIRONMENT` must match the prefix of the tfvars filename (e.g. `devtest01`).

- `ARM_SUBSCRIPTION_ID` — Azure subscription ID where DPN infrastructure will be deployed. Example: `<your-azure-subscription-id>`
- `ARM_TENANT_ID` — Azure AD tenant ID for your organisation. Example: `<your-azure-tenant-id>`
- `AZURE_LOCATION` — Azure region agreed with DSI for this environment. Example: `<azure-region>` (e.g. `UK South`)
- `ENVIRONMENT` — Short label matching the tfvars filename prefix. Example: `<env-name>` (e.g. `devtest01`)

---

#### B. Agent Pool & Service Connection

> `AGENT_POOL` is provided by the platform team. `SERVICE_CONNECTION` is created in **Project Settings > Service Connections**.

- `AGENT_POOL` — Name of the self-hosted Azure DevOps agent pool registered for this project. Example: `<agent-pool-name>`
- `SERVICE_CONNECTION` — Name of the Azure DevOps service connection scoped to the deployment subscription. Example: `<service-connection-name>`
- `SERVICE_CONNECTION_NAME` — Alias used by pipeline tasks that reference the connection by name. Set to the same value as `SERVICE_CONNECTION`. Example: `<service-connection-name>`

---

#### C. Terraform Backend State Storage

> All three values are created by the **bootstrap pipeline**. Run bootstrap first, then read the values from Azure portal or pipeline logs.

- `BACKEND_RESOURCE_GROUP` — Resource group that holds the Terraform remote state storage account.
  - Pattern: `rg-tfstate-dpn-<env>-uks-01`
  - Example: `rg-tfstate-dpn-<env-name>-uks-01`
- `BACKEND_STORAGE_ACCOUNT` — Storage account name for Terraform remote state 
  - Pattern: `sttfdpn<env>uks01`
- `BACKEND_KEY` — Blob name for the state file inside the `tfstate` container. Must be unique per environment and never change across runs.
  - Pattern: `dpn.<env>.tfstate`

---

#### D. Virtual Network

> Obtain from the connectivity/networking team. These resources must exist before the bootstrap pipeline runs.

- `VNET_RESOURCE_GROUP` — Resource group of the pre-existing VNet for this environment. Example: `<vnet-resource-group-name>`
- `VNET_NAME` — Name of the pre-existing VNet. Example: `<vnet-name>`
- `TFSTATE_SUBNET_PREFIX` — CIDR `/28` block allocated by the networking team for the Terraform state private endpoint subnet. Example: `<subnet-cidr>/28`

---

#### E. Private DNS

> Obtain from the DNS/networking team. `DNS_SUBSCRIPTION_ID` may differ from `ARM_SUBSCRIPTION_ID` when DNS is centrally managed in a separate subscription.

- `DNS_SUBSCRIPTION_ID` — Subscription ID hosting the shared private DNS zone. Example: `<dns-subscription-id>`
- `DNS_RESOURCE_GROUP` — Resource group containing the private DNS zone. Example: `<dns-resource-group-name>`
- `DNS_ZONE_NAME` — Private DNS zone for Azure Blob Storage private endpoints. Fixed value across all environments: `privatelink.blob.core.windows.net`

---

#### F. Pipeline YAML-Defined Variables

> Set directly in the pipeline YAML file — **not** in the Library Variable Group.

- `TF_WORKING_DIR` — Repo-relative path to the environment folder containing `main.tf` and `environments/`. Use the folder name at the repository root that matches the target environment. Example: `<repo-environment-folder-name>`
- `TFVARS_FILE` — Exact `.tfvars` filename under `$(TF_WORKING_DIR)/environments/`. The file must exist before the pipeline runs. Example: `<env-name>.tfvars`
- `TF_VERSION` — Terraform CLI version pinned for all pipeline tasks. Do not change without regression testing. Recommended: `1.9.8`

### Step 0.2 Authenticate and Select Subscription

Authentication is provided by the Azure DevOps service connection.
Use this pipeline task command to validate the active subscription context.

```bash
az account show --output table
```

### Step 0.3 Validate Tooling and Required Files

Use the following pipeline task checks to verify tooling and required files are available.

```bash
az version
terraform version

cd $(TF_WORKING_DIR)
test -f "environments/$(TFVARS_FILE)"
```

If the tfvars file check fails, create `environments/$(TFVARS_FILE)` before running the deployment pipeline.

---

## Phase 1: Bootstrap Infrastructure

This phase is executed by the bootstrap pipeline.

### Step 1.0 Use the Bootstrap Pipeline

Run the bootstrap pipeline first for a new environment, or whenever backend/state prerequisites are missing.

Bootstrap pipeline usage:

- Use `azure-pipeline-bootstrap-*.yml` for the target environment.
- Run it before the main `azure-pipelines-*.yml` deployment pipeline.
- Use it to create or validate the backend storage account, tfstate container, private endpoint path, and required bootstrap RBAC.
- If bootstrap resources already exist, the pipeline should complete through the bootstrap check/skip path.

### Step 1.1 Check Bootstrap State

Verify backend storage account and private endpoint existence first.

- If both exist, bootstrap is skipped.
- If missing/incomplete, bootstrap deployment runs.

### Step 1.2 Deploy Bootstrap via Subscription-Scope Bicep

When bootstrap is required, use this pipeline task command with pipeline variables:

```bash
az deployment sub create \
  --location "$(AZURE_LOCATION)" \
  --template-file "$(TF_WORKING_DIR)/bootstrap/main.bicep" \
  --parameters \
    envConfig="$(ENVIRONMENT)" \
    region="$(AZURE_LOCATION)" \
    bootstrapResourceGroupName="$(BACKEND_RESOURCE_GROUP)" \
    backendStorageAccountName="$(BACKEND_STORAGE_ACCOUNT)" \
    infraResourceGroupName="$(VNET_RESOURCE_GROUP)" \
    vnetName="$(VNET_NAME)" \
    vnetResourceGroupName="$(VNET_RESOURCE_GROUP)" \
    tfstateSubnetPrefix="$(TFSTATE_SUBNET_PREFIX)" \
    privateDnsZoneId="/subscriptions/$(DNS_SUBSCRIPTION_ID)/resourceGroups/$(DNS_RESOURCE_GROUP)/providers/Microsoft.Network/privateDnsZones/$(DNS_ZONE_NAME)"
```

### Step 1.4 Validate Backend Storage Redundancy

Confirm the Terraform state storage account uses the bootstrap-configured redundancy.

```bash
az storage account show \
  --name "$(BACKEND_STORAGE_ACCOUNT)" \
  --resource-group "$(BACKEND_RESOURCE_GROUP)" \
  --query "sku.name" -o tsv
```

Expected output:

```text
Standard_RAGRS
```

---

## Phase 2: Initialize and Plan

This phase is executed in the main infrastructure pipeline.

### Step 2.1 Prepare Environment tfvars

Verify tfvars file existence in pipeline working directory.

```bash
cd $(TF_WORKING_DIR)
test -f "environments/$(TFVARS_FILE)"
```

### Step 2.2 Initialize Terraform

Use the following pipeline task command to initialise Terraform with the configured backend.

```bash
terraform init \
  -backend-config="resource_group_name=$(BACKEND_RESOURCE_GROUP)" \
  -backend-config="storage_account_name=$(BACKEND_STORAGE_ACCOUNT)" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=$(BACKEND_KEY)" \
  -backend-config="use_azuread_auth=true"
```

Expected Output:

```text
Terraform has been successfully initialized!
```

### Step 2.3 Plan Infrastructure

Main pipeline behavior is controlled by `action` parameter:

- `plan` → runs Terraform plan and publishes plan artifact
- `apply` → runs plan, optional manual approval, then apply
- `destroy` → routed through destroy path/pipeline

Plan command in pipeline:

```bash
terraform plan \
  -var-file=environments/$(TFVARS_FILE) \
  -out=tfplan \
  -parallelism=4
```

Optional (advanced): If troubleshooting, you can target a specific module with
`-target=module.<module_name>` only after you confirm the module name in your root `main.tf`.

Apply workflow behavior:

- Temporarily removes CanNotDelete lock on `$(VNET_RESOURCE_GROUP)`
- Runs `terraform apply -var-file=environments/$(TFVARS_FILE) -auto-approve`
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

### Step 3.1 Validate Security and Monitoring Components

If your deployment completed successfully in Phase 2, verify key shared services are present and healthy.

Validation:

```bash
az monitor log-analytics workspace show --resource-group "<log-analytics-resource-group>" --workspace-name "<log-analytics-workspace>" --output table
az keyvault show --name "<keyvault-name>" --output table
```

---

## Phase 4: Compute Platform

Use the following steps to deploy the compute platform components.

### Step 4.1 Validate Compute Components

If ACR and AKS are part of your stack, validate cluster access and node readiness.

Validation:

```bash
az aks get-credentials --resource-group "<aks-resource-group>" --name "<aks-name>"
kubectl get nodes
kubectl get namespaces
```

### Step 4.2 VM Validation

Validate provisioning and access posture for the management/jump VM.

```bash
az vm list --query "[].{Name:name,RG:resourceGroup,Size:hardwareProfile.vmSize}" -o table
az network nic list --query "[].{NIC:name,RG:resourceGroup,PrivateIP:ipConfigurations[0].privateIPAddress}" -o table
```

---

## Phase 5: Storage Services

Use the following step to deploy the required storage services.

### Step 5.1 Deploy Storage Accounts

If storage components are defined in your stack, verify both accounts after full apply:

- state storage account (terraform backend)
- application storage account (workload data)

```bash
az storage account list --query "[].name" -o table

az storage account show \
  --name "$(BACKEND_STORAGE_ACCOUNT)" \
  --resource-group "$(BACKEND_RESOURCE_GROUP)" \
  --query "sku.name" -o tsv

az storage account show \
  --name "<application-storage-account-name>" \
  --resource-group "<app-storage-resource-group-name>" \
  --query "sku.name" -o tsv
```

Expected output examples:

```text
Backend state storage: Standard_RAGRS
Application storage:   Standard_GRS (or Standard_RAGZRS if adopted by organisation policy)
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

---

## Phase 6: Validation and Testing

Use the following steps to validate the completed infrastructure deployment.

### Step 6.1 Complete Remaining Deployments

Use the following pipeline task commands to apply any remaining unmanaged Terraform changes.

```bash
terraform plan -var-file=environments/$(TFVARS_FILE) -out=tfplan-complete
terraform apply tfplan-complete
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
az resource list \
  --resource-group "<infra-resource-group>" \
  --output table > deployment-resources.txt

terraform show -json | jq '.values.root_module.resources[] | {type, name}' > terraform-resources.json
```

### 10.5 Prepare for Application Deployment

After infrastructure deployment completes successfully, prepare handoff documentation for the application deployment team.

**Export Infrastructure Outputs:**

Terraform outputs contain critical information needed for application deployment configuration. Export these values:

```bash
# Retrieve Terraform outputs for application team
terraform output -json > infrastructure-outputs.json

# Extract key values
AKS_CLUSTER=$(terraform output -raw aks_cluster_name)
ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
KEYVAULT_URI=$(terraform output -raw keyvault_uri)

# Set AKS resource group from your tfvars or outputs key naming
AKS_RESOURCE_GROUP="<aks-resource-group-name>"

# Verify connectivity to deployed resources
az aks get-credentials --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER"
kubectl get nodes -o wide
kubectl get namespaces
```

### 10.6 Pipeline Execution and Connectivity Validation

Validate that deployment connectivity works as expected:

```text
Agent --> ADO Repo --> Pipeline --> Service Principal --> Azure
```

Checklist:

- Self-hosted agent can access Azure DevOps and fetch repository.
- Pipeline references the intended service connection.
- Service principal has required RBAC scope.
- Terraform operations succeed without interactive login.

**Document Infrastructure Details:**

Create a handoff document for the application deployment team with:

- Deployed resource names (AKS cluster, ACR, Key Vault, Storage accounts)
- Node pool configurations and capacity
- Network topology and security group rules
- RBAC assignments and service principal information
- Key Vault endpoint and secret naming conventions


**Next Steps:**

Transition to your application deployment guide or platform runbook.

The application deployment guide references:

- Azure DevOps pipeline setup for CI/CD
- Self-hosted agent configuration for application builds
- Container registry configuration for image storage
- Helm chart customization for deployment to AKS

---

Continue with [04-rollback-procedures.md](04-rollback-procedures.md)