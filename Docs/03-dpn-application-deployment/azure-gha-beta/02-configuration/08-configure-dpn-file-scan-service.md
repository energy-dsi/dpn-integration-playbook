# DPN File Scan Service Configuration 

This section describes how to configure and deploy the **DPN File Scan Service** on Azure. Unlike the AWS deployment (which uses Amazon GuardDuty Malware Protection for S3 and an SNS → SQS fan-out), the Azure path uses **Microsoft Defender for Storage** malware scanning on an Azure Storage Account, and the service consumes Defender's scan-result verdict events via an **Event Grid → Service Bus** fan-out rather than polling a scan API directly.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Prepare Identity for the Service](#step1-prepare-identity-for-the-service)
- [Step2: Azure Resource Setup (Service Bus/Event Grid/Defender for Storage)](#step2-azure-resource-setup-service-buseventgrid-defender-for-storage)
- [Step3: Configure File Scan Deployment Workflow](#step3-configure-file-scan-deployment-workflow)
  - [Step3a: Configure Environment JSON File](#step3a-configure-environment-json-file)
- [Step4: Configure Helm Chart Files](#step4-configure-helm-chart-files)
- [Step5: Configure Secrets](#step5-configure-secrets)
- [Review Notes](#review-notes)

---

## Overview

The DPN File Scan Service is a FastAPI application that runs as a single AKS Deployment. Microsoft Defender for Storage malware scanning scans every object landed in the inbound ("raw"/quarantine) Blob container; on completion it publishes a scan-result verdict event through a custom Event Grid topic, which fans out to a Service Bus topic subscription the service long-polls. For files scanned clean, the service copies the object to the outbound ("stage") container and deletes it from the inbound container; for files flagged with threats, the object is deleted from inbound and a `malicious_files` metric is incremented.

**Deployment and part of the Azure prerequisite setup both use pipelines.** `dpn-file-scan-cd.yml` in `dpn-containerised-deployment-service` deploys this service via Helm. `dpn-file-scan-prerequisites-cd.yml` also runs on `cloud: azure`: it creates the Service Bus topic and subscription, enables Defender for Storage malware scanning (on-upload) on the raw container's storage account wired to a custom Event Grid topic, enables that Event Grid topic's system-assigned identity, grants it the **Azure Service Bus Data Sender** role on the Service Bus topic, creates the Event Grid → Service Bus event subscription, and creates the raw storage container itself. It does **not** seed the service's own OAuth client credentials in Key Vault — those (`FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET`) are provisioned separately (see [Step5](#step5-configure-secrets)).

**CD Workflow**

| Workflow | File | Purpose |
|---|---|---|
| Main deploy | `.github/workflows/dpn-file-scan-cd.yml` | Builds nothing itself — deploys the already-built container image via Helm |
| Prerequisites | `.github/workflows/dpn-file-scan-prerequisites-cd.yml` | On `cloud: azure`, creates the Service Bus topic/subscription, enables Defender for Storage malware scanning wired to a custom Event Grid topic, grants the topic's managed identity Service Bus access, creates the Event Grid → Service Bus event subscription, and creates the raw storage container |

---

## Step1: Prepare Identity for the Service

The File Scan Service's own pod does not use the system-assigned identity created in [Step2](#step2-azure-resource-setup-service-buseventgrid-defender-for-storage) for the Event Grid topic — that identity is only used by Azure to deliver Defender's scan-result events into Service Bus. The service pod itself authenticates to its dependencies as follows:

| Dependency | Access mechanism |
|---|---|
| Azure Storage Account (source/dest containers) | Storage account connection string / key, configured via the chart's `env.sourceStorageAccount`/`env.sourceContainer`/`env.destStorageAccount`/`env.destContainer` values (see [Step4](#step4-configure-helm-chart-files)) |
| Service Bus subscription (scan-result events) | Service Bus namespace + topic/subscription name, configured via `env.serviceBusNamespace`/`env.topicname`/`env.subscriptionname` |
| OAuth client credentials (`FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET`) | Azure Key Vault, synced into the pod via the Secrets Store CSI driver's `SecretProviderClass` — see [Step5](#step5-configure-secrets) |

> **Note:** `dpn-file-scan-prerequisites-cd.yml` (run with `cloud: azure`) provisions the Event Grid topic's own system-assigned identity and its Service Bus role assignment for you, as part of wiring Defender's scan-result delivery — see [Step2](#step2-azure-resource-setup-service-buseventgrid-defender-for-storage). It does not create or manage the service pod's Key Vault access policy/RBAC; that follows the same pattern as the other DPN services (see [Configure DPN Vault Service](01-configure-dpn-vault-service.md)).

## Step2: Azure Resource Setup (Service Bus/Event Grid/Defender for Storage)

`dpn-file-scan-prerequisites-cd.yml` (run with `cloud: azure`) provisions the following, idempotently:

1. **Service Bus topic and subscription** — creates the topic (`serviceBusTopicName` input, e.g. `dpn-fileupload-scan-results`) and subscription (`FILESCAN_SB_SUBSCRIPTION_NAME` from the config JSON, e.g. `dpn-fileupload-scan-results-sub`) under `serviceBusNamespace`/`serviceBusResourceGroup`, if they don't already exist.
2. **Defender for Storage malware scanning** — enables `malwareScanning.onUpload` on the raw container's storage account (`FILESCAN_STORAGE_ACCOUNT` in `FILESCAN_STORAGE_RG`), pointing `scanResultsEventGridTopicResourceId` at the custom Event Grid topic (`eventGridCustomTopicName` input), via `az rest PUT` against the `DefenderForStorageSettings` ARM API.
3. **Event Grid topic managed identity** — enables a system-assigned identity on the Event Grid custom topic (`az eventgrid topic update --identity systemassigned`).
4. **Service Bus role assignment** — grants that Event Grid topic identity the **Azure Service Bus Data Sender** role, scoped to the Service Bus topic, so Event Grid can deliver events into it.
5. **Event Grid → Service Bus event subscription** — creates the event subscription (`FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME` from the config JSON, e.g. `dpn-defender-malware-scan-sub`) on the Event Grid custom topic, with `ServiceBusTopic` as its destination and `deliveryWithResourceIdentity` using the topic's system-assigned identity, via `az rest PUT` (ARM, `Microsoft.EventGrid/eventSubscriptions`).
6. **Raw storage container** — creates the inbound Blob container (`containerName` input, e.g. `dp-consumer-raw`) on `FILESCAN_STORAGE_ACCOUNT` if it does not already exist (`az storage container create --auth-mode login`).

> **Note:** Organisation must set up soft-delete/blob versioning on the malicious-object handling at the storage account/lifecycle level per your organisation's policy — the service itself does not enable this.

> **Note:** the federated service principal running this workflow needs, on the target scopes: Service Bus create + Data Owner, Security Admin (Defender settings), Owner/User Access Administrator (role assignment), EventGrid Contributor, and Storage Blob Data Contributor (container create with `--auth-mode login`).

---

## Step3: Configure File Scan Deployment Workflow

Organisations should prepare a `.github/config/azure/<environment>-<cluster>.json` file per environment/cluster where the file scan service is deployed. This file will be read by the workflow during deployment.

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
| `AZURE_SUBSCRIPTION_ID` / `ARM_SUBSCRIPTION_ID` | Azure subscription the resources live in. `ARM_SUBSCRIPTION_ID` is what the prerequisites workflow pins to explicitly (the federated SP's default subscription may differ, causing `AuthorizationFailed`) | `f0350356-d639-4845-b2f8-8c1d74d23007` |
| `RESOURCE_GROUP` | Resource group holding the AKS cluster | `rg-aks-dpn-azure-dev-uks-001` |
| `AKS_CLUSTER` | AKS cluster name | `aks-dpn-azure-dev-uks-001` |
| `KEY_VAULT_NAME` | Key Vault holding `FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET` (see [Step5](#step5-configure-secrets)) | `kv-dpn-azure-dev-uks-001` |
| `NAMESPACE` | Target namespace | `ns-dpn-01` |
| `BASE_REGISTRY` / `ACR_NAME` | Base registry URL. Both are set to `ghcr.io` on Azure — no Azure Container Registry is used for this service | `ghcr.io` |
| `FILESCAN_STORAGE_ACCOUNT` | Azure Storage Account Defender for Storage scans (holds both the source/raw and dest/stage containers) | `stfsdpndev001uks01` |
| `FILESCAN_STORAGE_RG` | Resource group of `FILESCAN_STORAGE_ACCOUNT` | `rg-stfs-dpn-dev001-uks-01` |
| `FILESCAN_SB_SUBSCRIPTION_NAME` | Service Bus subscription the service long-polls for scan-result events, under the topic from [Step2](#step2-azure-resource-setup-service-buseventgrid-defender-for-storage) — a **name**, not a resource ID | `dpn-fileupload-scan-results-sub` |
| `FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME` | The Event Grid event subscription name from [Step2](#step2-azure-resource-setup-service-buseventgrid-defender-for-storage) that carries Defender's scan verdict events into Service Bus | `dpn-defender-malware-scan-sub` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTel collector's OTLP endpoint. Defaults to the HTTPS endpoint on port `4318` | `https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` |

> **Note:** the source and destination containers themselves (e.g. `dp-consumer-raw` / `dp-consumer-stage`) are **not** separate keys in this config JSON — they are set as Helm values (`env.sourceContainer`/`env.destContainer`) in [Step4](#step4-configure-helm-chart-files), both resolved against the single `FILESCAN_STORAGE_ACCOUNT` above (the AWS equivalent of this doc instead uses two distinct bucket keys, `FILESCAN_SOURCE_BUCKET`/`FILESCAN_DEST_BUCKET`, directly in its config JSON — confirm this split matches your actual environment JSON before relying on it, since the source/dest storage accounts in the chart's reference `values/azure/dev-dpn01.yaml` are in fact two different storage account names, `stfsdpndev001uks01` and `stdevdpnazuredevuks001`, rather than one shared account as implied above).

---

## Step4: Configure Helm Chart Files

Set the parameters below in your environment/cluster's values file. The CD workflow resolves `values/azure/<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
dpn-file-scan/
  └── charts/
        └── file-scan-service/
          └── values/
              └── azure/           
                ├──<environment>-<cluster>.yaml <- Your environment overrides
```

The following values to be modified in that file

| Item | Value |
|---|---|
| image:repository | `ghcr.io/energy-dsi/dpn-file-scan-service` |
| image:tag | Image tag to deploy |
| keyvault.name | Key Vault to read `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET`/`TRUSTSTORE-PASSWORD` from — matches `KEY_VAULT_NAME` in the config JSON | `kv-dpn-azure-dev-uks-001` |
| keyvault.clientID | Managed identity client ID used by the Secrets Store CSI driver to authenticate to Key Vault | `926f11f6-84b7-445f-91b0-c957963f9098` |
| keyvault.tenantId | Azure AD tenant ID | `a63c9e9e-b4db-442a-a94f-08718d788e8c` |
| env.serviceBusNamespace | Service Bus namespace hostname the service connects to | `sb-dpn-dev001-uks-01.servicebus.windows.net` |
| env.sourceStorageAccount | Storage account holding the inbound/raw container that Defender for Storage scans. Matches `FILESCAN_STORAGE_ACCOUNT` in the config JSON | `stfsdpndev001uks01` |
| env.sourceContainer | Inbound Blob container name | `dp-consumer-raw` |
| env.destStorageAccount | Storage account clean files are copied to | `stdevdpnazuredevuks001` |
| env.destContainer | Outbound/stage Blob container name | `dp-consumer-stage` |
| env.cloudprovidertype | Cloud provider discriminator read by the application | `AZURE` |
| env.tenantId | Azure AD tenant ID (app-level) | `a63c9e9e-b4db-442a-a94f-08718d788e8c` |
| env.topicname | Service Bus topic name the subscription in `env.subscriptionname` belongs to | `dpn-fileupload-scan-results` |
| env.subscriptionname | Service Bus subscription the service long-polls for scan-result events. Matches `FILESCAN_SB_SUBSCRIPTION_NAME` in the config JSON | `dpn-fileupload-scan-results-sub` |
| env.clientIdFile / env.clientSecretFile | Paths the Key Vault CSI driver mounts `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET` at | `/mnt/keyvault/FILESCAN-CLIENT-ID` / `/mnt/keyvault/FILESCAN-CLIENT-SECRET` |

> **Note:** there is no Helm value for the Event Grid custom topic or its event subscription — the app only ever consumes from its Service Bus subscription; the Event Grid → Service Bus fan-out from [Step2](#step2-azure-resource-setup-service-buseventgrid-defender-for-storage) is wiring set up outside the application. The AWS-only `env.awsRegion`/`env.sourceBucket`/`env.destBucket`/`env.sqsQueueName` fields alongside this shared `env.*` block should be left empty (their default) on Azure.
>
> Optionally, `env.truststorePath` gates whether the chart mounts the `dpn-tls` OTLP truststore volume at all — leave it unset for an environment with no `dpn-tls` secret provisioned.

---

## Step5: Configure Secrets

Unlike the AWS path, this service sources its OAuth client credentials from **Azure Key Vault**, via the Secrets Store CSI driver's `SecretProviderClass` (the same pattern used by the platform's other services — see [Configure DPN Vault Service](01-configure-dpn-vault-service.md)):

| Parameter | Purpose | Example |
|-----------|---------|---------|
| keyvault.name | Key Vault holding `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET` | `kv-dpn-azure-dev-uks-001` |
| keyvault.objects | CSI driver object list — must include `FILESCAN-CLIENT-ID` and `FILESCAN-CLIENT-SECRET` (both `type: secret`), alongside the shared `TRUSTSTORE-PASSWORD` object | see the chart's reference `values/azure/<environment>-<cluster>.yaml` |

Both `FILESCAN-CLIENT-ID` and `FILESCAN-CLIENT-SECRET` must already exist in `keyvault.name` before the first deploy — this workflow's Azure prerequisites steps ([Step2](#step2-azure-resource-setup-service-buseventgrid-defender-for-storage)) do not seed them; provision them the same way as the other DPN services' Key Vault secrets (see [Configure DPN Vault Service](01-configure-dpn-vault-service.md)).

> **Note:** the AWS equivalent of this doc describes `dpn-file-scan-prerequisites-cd.yml` seeding a `REPLACE_ME` placeholder for its Secrets Manager equivalent of these two credentials automatically. Nothing in the real Azure-conditional blocks of that same workflow does the equivalent for Key Vault — confirm whether a comparable placeholder-seeding step exists for your environment, or whether these two secrets must be created manually before first deploy.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
