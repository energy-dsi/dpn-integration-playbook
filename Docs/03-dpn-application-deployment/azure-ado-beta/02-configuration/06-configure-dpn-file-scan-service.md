# DPN File Scan Service Configuration 

This section describes how to configure and deploy the **DPN File Scan Service** on Azure Cloud platform. This service uses native Azure cloud components for file scan using Azure Defender For Cloud Storage.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Prepare Service Principal in Azure AD](#step1-prepare-service-principal-in-azure-ad)
- [Step2: Configure Prerequisites Provisioning Pipeline](#step2-configure-prerequisites-provisioning-pipeline)
  - [Step2a: Setup Prerequisite Pipeline Parameters](#step2a-setup-prerequisite-pipeline-parameters)
- [Step3: Configure File Scan Deployment Pipeline](#step3-configure-file-scan-deployment-pipeline)
  - [Step3a: Configure Environment JSON File](#step3a-configure-environment-json-file)
- [Step4: Configure Helm Chart Files](#step4-configure-helm-chart-files)
- [Step5: Configure Azure Key Vault / Secrets](#step5-configure-azure-key-vault--secrets)
- [Review Notes](#review-notes)

---

## Overview

The DPN File Scan Service is a FastAPI application that runs as a single AKS Deployment. It listens on an Azure Service Bus subscription for Microsoft Defender for Storage malware-scan results, and — for files scanned clean — copies the file from a source ("raw"/quarantine) storage account/container to a destination ("stage") storage account/container.

The repository ships **two separate CD pipelines** and a single CI pipeline.

**CI Pipeline:**

| Pipeline | File Location in Repo | Purpose |
|---|---|---|
| ACR CI | `.pipelines/azure-pipelines/ci-pipelines/dpn-file-scan-service-ci.yaml` | Pushes container image to Azure Container Registry |

**CD Pipeline**

| Pipeline | File Location in Repo | Purpose |
|---|---|---|
| Prerequisites | `.pipelines/azure-pipelines/cd-pipelines/dpn-file-scan-service-prerequisites-cd.yaml` | One-off/idempotent provisioning of the Azure Service Bus topic/subscription, Defender for Storage malware scanning, the Event Grid wiring between them, and the quarantine storage container |
| Main deploy | `.pipelines/azure-pipelines/cd-pipelines/dpn-file-scan-service-cd.yml` | Builds nothing itself — deploys the already-built container image via Helm |

---

## Step1: Prepare Service Principal in Azure AD 

The File Scan Service requires a service principal for authentication to all the Azure native components, such as Azure Service Bus and Storage accounts. The new service principal should have the following role assignments completed. 

| Role Name | Role assigned on  | Role Assigned to |
|-----------|-------------------|------------------|
| Service Bus Data Receiver | Service Bus | Service Principal Object ID |
| Storage Blob Data Contributor | Storage accounts source/destination | Service Principal Object ID |

Once the service principal is available, note the CLIENT_ID and CLIENT_SECRET to be used for file scan service.

## Step2: Configure Prerequisites Provisioning Pipeline

`dpn-file-scan-service-prerequisites-cd.yaml` is a separate, parameterised pipeline that performs following actions. 

- **Note** Organisation must set up softDelete for malicious blob at the storage account level in Defender for Storage settings. Subscription level settings will not work as the prerequisite pipeline overrides the subscription settings to use eventgrid topic for scan result publish
- Registers Event Grid subscription on Defender for cloud storage
- Create event grid topic to push events from Defender service to Azure Service Bus
- Create a new container in the target storage account
- Performs necessary role assignments
- Verifies that the required storage accounts exist in the environment

### Step2a: Setup Prerequisite Pipeline Parameters

| Parameter | Purpose |
|---|---|
| `serviceConnection` | Azure DevOps service connection to use |
| `storageAccountName` | Storage account hosting the quarantine container |
| `storageResourceGroup` | Resource group of that storage account |
| `containerName` | Source container used to scan file - preferred `<dp-consumer-raw>` |
| `serviceBusNamespace` | Target Service Bus namespace |
| `serviceBusResourceGroup` | Resource group of the Service Bus namespace |
| `serviceBusTopicName` | Topic that receives scan-result events |
| `serviceBusSubscriptionName` | Subscription the service listens on |
| `defenderEventSubscriptionName` | Name of the Event Grid event subscription created |
| `eventGridResourceGroup` | Resource group of the Event Grid topic |
| `eventGridTopicResourceGroup` | (Same resource group, referenced separately in the script) |
| `eventGridCustomTopicName` | The **custom** Event Grid Topic name where Defender publishes scan results |
| `approval_group` | Organisation may decide if pipeline runs on approval then ADO Environment name the deployment job gates against |

---

## Step3: Configure File Scan Deployment Pipeline

Organisations should prepare a config/dpn-<env-name>.json file per environment where file scan service is deployed and keep in the following location. This file will be referenced by the pipelines during deployment.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── config/
            └── dpn-<env-name>.json
```

### Step3a: Configure Environment JSON File

| Key | Purpose | Example (`pdev-dpn01`) |
|---|---|---|
| `ENV_NAME` | Environment label | `pdev` |
| `ACR_NAME` | ACR instance name (no `.azurecr.io` suffix) | `acrdpndevuks01` |
| `BASE_REGISTRY` | Templated as `$(ACR_NAME).azurecr.io` | — |
| `AZURE_SUBSCRIPTION_ID` | Target subscription | *(per-cluster subscription id)* |
| `KEY_VAULT_NAME` | Key Vault name holding `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET` | `kv-dpn-pdev-uks-01` |
| `AKS_CLUSTER` | AKS cluster name | `aks-dpn-pdev-uks-08` |
| `RESOURCE_GROUP` | AKS resource group | `rg-aks-dpn-pdev-uks-08` |
| `NAMESPACE` | Target namespace | `ns-dpn-01` |

---

## Step4: Configure Helm Chart Files

Copy `values.yaml` (reference — do not edit directly) to `values-<env>.yaml` and set the parameters below in the following location. The CD pipeline resolves `values-<env>.yaml` from the environment you select at runtime.

```text
Root-Repository
  └── charts
        └── file-scan-service
              ├── values.yaml        <- Reference file; do not edit directly
              ├── values-<env>.yaml  <- Your environment overrides
```

The following values to be modified in the values-<env>.yaml

| Item | Value |
|---|---|
| image:repository | `<ACR_NAME>.azurecr.io/dpn-file-scan-service` |
| image:tag | `<Build.BuildNumber>` |
| keyvault:name | `Your AKV name` |
| keyvault:clientID | `Azure Service Principal - Client ID ` |
| keyvault:tenantID | `Azure Service Principal - Azure Tenant ID` |
| serviceBusNamespace | `Azure Service namespace i.e. <xyz>.servicebus.windows.net` |
| sourceStorageAccount | `Azure source storage account name where file will be scanned` |
| sourceContainer | `Azure source storage account container name, preferred name "dp-consumer-raw"`|
| destStorageAccount | `Azure destination storage account name where file will be copied` |
| destContainer |  `Azure destination storage account container name, preferred name "dp-consumer-stage"`|
| tenantId | `Azure Subscription tenant ID` |
| topicname | `target topic name on the azure service bus- preferred <dpn-fileupload-scan-results>`|
| subscriptionname | `Azure Subscription ID`|

---

## Step5: Configure Azure Key Vault / Secrets

The following secrets should be created in Azure Key Vault

| Secret name | Purpose |
|-------------|---------|
|FILESCAN-CLIENT-ID | Service principal client id |
|FILESCAN-CLIENT-SECRET | Service principal secret |

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
