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

Deployment uses **two separate GitHub Actions CD workflows** in `dpn-containerised-deployment-service`; CI (image build) runs separately in the component's own source repository where already migrated.

**CD Workflows**

| Workflow | File | Purpose |
|---|---|---|
| Prerequisites | `.github/workflows/dpn-file-scan-prerequisites-cd.yml` | One-off/idempotent provisioning of the Azure Service Bus topic/subscription, Defender for Storage malware scanning, the Event Grid wiring between them, and the quarantine storage container. **Azure-specific by design** — there is no AWS/GCP equivalent for this provisioning step yet, though it still exposes a `cloud` input for consistency |
| Main deploy | `.github/workflows/dpn-file-scan-cd.yml` | Builds nothing itself — deploys the already-built container image via Helm |

---

## Step1: Prepare Service Principal in Azure AD 

The File Scan Service requires a service principal for authentication to all the Azure native components, such as Azure Service Bus and Storage accounts. The new service principal should have the following role assignments completed. 

| Role Name | Role assigned on  | Role Assigned to |
|-----------|-------------------|------------------|
| Service Bus Data Receiver | Service Bus | Service Principal Object ID |
| Storage Blob Data Contributor | Storage accounts source/destination | Service Principal Object ID |

Once the service principal is available, note the CLIENT_ID and CLIENT_SECRET to be used for file scan service.

## Step2: Configure Prerequisites Provisioning Pipeline

`dpn-file-scan-prerequisites-cd.yml` is a separate, parameterised GitHub Actions workflow that performs following actions. 

- **Note** Organisation must set up softDelete for malicious blob at the storage account level in Defender for Storage settings. Subscription level settings will not work as the prerequisite workflow overrides the subscription settings to use eventgrid topic for scan result publish
- Registers Event Grid subscription on Defender for cloud storage
- Create event grid topic to push events from Defender service to Azure Service Bus
- Create a new container in the target storage account
- Performs necessary role assignments
- Verifies that the required storage accounts exist in the environment

### Step2a: Setup Prerequisite Pipeline Parameters

`workflow_dispatch` inputs:

| Parameter | Purpose |
|---|---|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `containerName` | Source container used to scan file — default `dp-consumer-raw` |
| `serviceBusNamespace` | Target Service Bus namespace (required, no default) |
| `serviceBusResourceGroup` | Resource group of the Service Bus namespace — default `rg-sb-dpn-dev-uks-01` |
| `serviceBusTopicName` | Topic that receives scan-result events — default `dpn-fileupload-scan-results` |
| `eventGridResourceGroup` | Resource group of the Event Grid topic — default `rg-evgt-dpn-dev-uks-01` |
| `eventGridTopicResourceGroup` | (Same resource group, referenced separately in the workflow) — default `rg-evgt-dpn-dev-uks-01` |
| `eventGridCustomTopicName` | The **custom** Event Grid Topic name where Defender publishes scan results — default `evgt-dpn-dev-uks-01` |

The Service Bus subscription name and Defender event-subscription name are **not** workflow inputs (kept under GitHub Actions' 10-input cap per workflow) — they come from the environment config JSON instead as `FILESCAN_SB_SUBSCRIPTION_NAME` and `FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME` (see [Step3a](#step3a-configure-environment-json-file)). There is no ADO-style approval-group concept — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual gate before this runs.

---

## Step3: Configure File Scan Deployment Pipeline

Organisations should prepare a `.github/config/azure/<environment>-<cluster>.json` file per environment/cluster where the file scan service is deployed. This file will be read by both workflows during deployment.

```text
dpn-containerised-deployment-service/
└── .github/
    └── config/
        └── azure/
            └── <environment>-<cluster>.json
```

### Step3a: Configure Environment JSON File

| Key | Purpose | Example (`dev-dpn01`) |
|---|---|---|
| `ACR_NAME` | Container registry instance name | `ghcr.io` (or your ACR, no `.azurecr.io` suffix) |
| `BASE_REGISTRY` | Base registry URL | `ghcr.io` |
| `AZURE_SUBSCRIPTION_ID` / `ARM_SUBSCRIPTION_ID` | Target subscription | *(per-cluster subscription id)* |
| `KEY_VAULT_NAME` | Key Vault name holding `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET` | `kv-dpn-azure-dev-uks-001` |
| `AKS_CLUSTER` | AKS cluster name | `aks-dpn-azure-dev-uks-001` |
| `RESOURCE_GROUP` | AKS resource group | `rg-aks-dpn-azure-dev-uks-001` |
| `NAMESPACE` | Target namespace | `ns-dpn-01` |
| `FILESCAN_STORAGE_ACCOUNT` | Storage account hosting the quarantine container | `stfsdpndev001uks01` |
| `FILESCAN_STORAGE_RG` | Resource group of that storage account | `rg-stfs-dpn-dev001-uks-01` |
| `FILESCAN_SB_SUBSCRIPTION_NAME` | Service Bus subscription the service listens on | `dpn-fileupload-scan-results-sub` |
| `FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME` | Name of the Event Grid event subscription created by the prerequisites workflow | `dpn-defender-malware-scan-sub` |
| `OTEL_ENDPOINT` | Open Telemetry Endpoint | `https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318`
| `otelExporterProtocol` |  Protocol | `https`
| `otelExporterCertificate` | Otel Exporter Certificate | `/etc/secrets/truststore.jks`
| `truststorePath` | Truststore Path | `/etc/kafka/secrets/truststore.jks`
| `otelTlsSecretName` | Otel TLS Secret Name | `dpn-tls`
| `truststorePasswordSecretName` | Universal dpn truststore certificate password | `UNIVERSAL-DPN-CERT-PASSWORD`
| `OTEL_OAUTH_ENABLED` | Otel Authorization Enabled | `True`
| `OTEL_OAUTH_CLIENT_ID` | Otel OAuth Client ID | `dpn-service-client`
| `OTEL_OAUTH_CLIENT_SECRET` | Otel OAuth Client Secret | `Secret Value`
| `OTEL_OAUTH_TOKEN_ENDPOINT_URL` | Otel OAuth Token Endpoint Url | `https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token`
| `OTEL_OAUTH_CA_LOCATION` |  Otel OAuth CA Location | `/etc/kafka/secrets/ca.crt`
| `<AWS_REGION>` | Region the S3/SNS/SQS resources live in | `eu-west-2` 
| `<INBOUND_BUCKET>` | S3 bucket GuardDuty scans | `S3_BUCKET_INBOUND`
| `<OUTBOUND_BUCKET>` | S3 bucket clean files are copied to | `S3_BUCKET_OUTBOUND`
| `<SQS_QUEUE_URL>` | The queue URL from Step 3 | `SQS_QUEUE`
| `<SNS_TOPIC_ARN>` | The topic ARN from Step 3 | `SNS_TOPIC`
| `<IRSA_ROLE_ARN>` | ARN of the IAM role granting the S3/SQS permissions above | `NA`

---

## Step4: Configure Helm Chart Files

Set the parameters below in your environment/cluster's values file. The CD workflow resolves `values/azure/<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
dpn-file-scan/
  └── charts/
        └── file-scan-service/
              ├── values.yaml                              <- Reference file; do not edit directly
              └── values/azure/<environment>-<cluster>.yaml <- Your environment overrides
```

The following values to be modified in that file

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
| *(value of `keyvault.truststorePasswordSecretName`)* | Password for the `dpn-tls` JKS truststore (`truststore.jks`), synced into a native Kubernetes Secret and injected as `TRUSTSTORE_PASSWORD` |

> **Note:** the shared secret name `UNIVERSAL-DPN-CERT-PASSWORD` previously used for the truststore password above has been retired in favour of an environment-specific Key Vault secret name (e.g. `KC-HTTPS-TRUST-STORE-PASSWORD` or `TRUSTSTORE-PASSWORD`, depending on the cluster). Set `keyvault.truststorePasswordSecretName` in your environment's values file to whichever secret name your Key Vault actually uses — do not assume the old universal name still applies.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
