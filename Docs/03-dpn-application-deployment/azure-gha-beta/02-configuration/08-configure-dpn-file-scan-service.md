Release : 2.1.0 - Oct 2026

# DPN File Scan Service Configuration 

This section describes how to configure and deploy the **DPN File Scan Service** on Azure. Unlike the AWS deployment (which uses Amazon GuardDuty Malware Protection for S3 and an SNS → SQS fan-out), the Azure path uses **Microsoft Defender for Storage** malware scanning on an Azure Storage Account, and the service consumes Defender's scan-result verdict events via an **Event Grid → Service Bus** fan-out rather than polling a scan API directly.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Prepare Identity for the Service](#step1-prepare-identity-for-the-service)
- [Step2: Azure Resource Setup (Service Bus/Event Grid/Defender for Storage)](#step2-azure-resource-setup-service-busevent-griddefender-for-storage)
- [Step3: Configure File Scan Deployment Workflow](#step3-configure-file-scan-deployment-workflow)
  - [Step3a: Configure Environment JSON File](#step3a-configure-environment-json-file)
- [Step4: Configure Helm Chart Files](#step4-configure-helm-chart-files)
- [Step5: Configure Secrets](#step5-configure-secrets)
- [Review Notes](#review-notes)

---

## Overview

The DPN File Scan Service is a FastAPI application that runs as a single AKS Deployment. Microsoft Defender for Storage malware scanning scans every object landed in the inbound ("raw"/quarantine) Blob container; on completion it publishes a scan-result verdict event through a custom Event Grid topic, which fans out to a Service Bus topic subscription the service long-polls. For files scanned clean, the service copies the object to the outbound ("stage") container and deletes it from the inbound container; for files flagged with threats, the object is deleted from inbound and a `malicious_files` metric is incremented.

**Deployment and part of the Azure prerequisite setup both use pipelines.** `dpn-gha-file-scan-cd.yaml` in `dpn-file-scan-service` deploys this service via Helm. `dpn-gha-file-scan-prerequisites-cd.yaml` also runs on `cloud: azure`: it creates the Service Bus topic and subscription, enables Defender for Storage malware scanning (on-upload) on the raw container's storage account wired to a custom Event Grid topic, enables that Event Grid topic's system-assigned identity, grants it the **Azure Service Bus Data Sender** role on the Service Bus topic, creates the Event Grid → Service Bus event subscription, and creates the raw storage container itself. It does **not** seed the service's own OAuth client credentials in Key Vault — those (`FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET`) are provisioned separately (see [Step5](#step5-configure-secrets)).

**CD Workflow**

| Workflow | Display name | File | Purpose |
|---|---|---|---|
| Main deploy | **DPN CD - File Scan Service** | `.github/workflows/dpn-gha-file-scan-cd.yaml` | Builds nothing itself — deploys the already-built container image via Helm (release `dpn-file-scan-service`, chart `charts/file-scan-service`) |
| Prerequisites | **DPN CD - File Scan Prerequisites** | `.github/workflows/dpn-gha-file-scan-prerequisites-cd.yaml` | On `cloud: azure`, creates the Service Bus topic/subscription, enables Defender for Storage malware scanning wired to a custom Event Grid topic, grants the topic's managed identity Service Bus access, creates the Event Grid → Service Bus event subscription, and creates the raw storage container |
| Rollback | **DPN Rollback - File Scan Service** | `.github/workflows/dpn-gha-file-scan-rollback.yaml` | `helm rollback` of `dpn-file-scan-service` — see [Rollback Procedures, Part 4](../04-rollback/04-rollback-procedures.md#part-4--dpn-file-scanning-service-rollback) |
| Uninstall | **DPN Uninstall - File Scan Service** | `.github/workflows/dpn-gha-file-scan-uninstall.yaml` | `helm uninstall` of `dpn-file-scan-service`; leaves the prerequisite Azure resources in place — see [Uninstall, Part 1](../05-uninstall/05-uninstall-decommissioning.md#part-1--uninstall-dpn-file-scanning-service) |

Both take the `environment` (`dev`/`test`, default `test`), `cluster` (`dpn01`/`dpn02`, default `dpn01`) and `cloud` (default `aws` — select `azure` explicitly) inputs, run under the GitHub Environment `<environment>-<cluster>` on a self-hosted runner labelled `[self-hosted, vmss]`, and log in through the `.github/actions/cloud-login` composite action using Azure OIDC federation with the `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` repository or environment secrets.

---

## Step1: Prepare Identity for the Service

The File Scan Service's own pod does not use the system-assigned identity created in [Step2](#step2-azure-resource-setup-service-busevent-griddefender-for-storage) for the Event Grid topic — that identity is only used by Azure to deliver Defender's scan-result events into Service Bus. The service pod itself authenticates to its dependencies as follows:

| Dependency | Access mechanism |
|---|---|
| Azure Storage Account (source/dest containers) | Service principal credential (`ClientSecretCredential`) built from `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET` and `env.tenantId`; the accounts and containers are configured via the chart's `env.sourceStorageAccount`/`env.sourceContainer`/`env.destStorageAccount`/`env.destContainer` values (see [Step4](#step4-configure-helm-chart-files)) |
| Service Bus subscription (scan-result events) | The same service principal credential; Service Bus namespace + topic/subscription name configured via `env.serviceBusNamespace`/`env.topicname`/`env.subscriptionname` |
| OAuth client credentials (`FILESCAN_CLIENT_ID`/`FILESCAN_CLIENT_SECRET`) | Azure Key Vault, mounted into the pod at `/mnt/keyvault` by the Secrets Store CSI driver's `SecretProviderClass` (`dpn-file-scan-service-kv-secrets`), which authenticates with the user-assigned managed identity in `keyvault.clientID` — see [Step5](#step5-configure-secrets) |

> **Note:** `dpn-gha-file-scan-prerequisites-cd.yaml` (run with `cloud: azure`) provisions the Event Grid topic's own system-assigned identity and its Service Bus role assignment for you, as part of wiring Defender's scan-result delivery — see [Step2](#step2-azure-resource-setup-service-busevent-griddefender-for-storage). It does not create or manage the service pod's Key Vault access policy/RBAC; that follows the same pattern as the other DPN services (see [Configure DPN Vault Service](01-configure-dpn-vault-service.md)).

## Step2: Azure Resource Setup (Service Bus/Event Grid/Defender for Storage)

`dpn-gha-file-scan-prerequisites-cd.yaml` (run with `cloud: azure`) provisions the following, idempotently:

1. **Service Bus topic and subscription** — creates the topic (`serviceBusTopicName` input, e.g. `dpn-fileupload-scan-results`) and subscription (`FILESCAN_SB_SUBSCRIPTION_NAME` from the config JSON, e.g. `dpn-fileupload-scan-results-sub`) under `serviceBusNamespace`/`serviceBusResourceGroup`, if they don't already exist.
2. **Defender for Storage malware scanning** — enables `malwareScanning.onUpload` on the raw container's storage account (`FILESCAN_STORAGE_ACCOUNT` in `FILESCAN_STORAGE_RG`), pointing `scanResultsEventGridTopicResourceId` at the custom Event Grid topic (`eventGridCustomTopicName` input), via `az rest PUT` against the `DefenderForStorageSettings` ARM API.
3. **Event Grid topic managed identity** — enables a system-assigned identity on the Event Grid custom topic (`az eventgrid topic update --identity systemassigned`).
4. **Service Bus role assignment** — grants that Event Grid topic identity the **Azure Service Bus Data Sender** role, scoped to the Service Bus topic, so Event Grid can deliver events into it.
5. **Event Grid → Service Bus event subscription** — creates the event subscription (`FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME` from the config JSON, e.g. `dpn-defender-malware-scan-sub`) on the Event Grid custom topic, with `ServiceBusTopic` as its destination and `deliveryWithResourceIdentity` using the topic's system-assigned identity, via `az rest PUT` (ARM, `Microsoft.EventGrid/eventSubscriptions`).
6. **Raw storage container** — creates the inbound Blob container (`containerName` input, e.g. `dp-consumer-raw`) on `FILESCAN_STORAGE_ACCOUNT` if it does not already exist (`az storage container create --auth-mode login`).

> **Note:** apart from the four `FILESCAN_*` config JSON keys, every resource name above is a run-time input of the workflow: `containerName` (default `dp-consumer-raw`), `serviceBusNamespace` (no default; the "Validate Required Values (Azure)" step fails if it is blank), `serviceBusResourceGroup` (default `rg-sb-dpn-dev-uks-01`), `serviceBusTopicName` (default `dpn-fileupload-scan-results`), `eventGridResourceGroup` and `eventGridTopicResourceGroup` (both default `rg-evgt-dpn-dev-uks-01`) and `eventGridCustomTopicName` (default `evgt-dpn-dev-uks-01`). The defaults are dev resource names — override them for other environments/clusters.

> **Note:** Organisation must set up soft-delete/blob versioning on the malicious-object handling at the storage account/lifecycle level per your organisation's policy — the service itself does not enable this.

> **Note:** the federated service principal running this workflow needs, on the target scopes: Service Bus create + Data Owner, Security Admin (Defender settings), Owner/User Access Administrator (role assignment), EventGrid Contributor, and Storage Blob Data Contributor (container create with `--auth-mode login`).

---

## Step3: Configure File Scan Deployment Workflow

Organisations should prepare a `.github/config/azure/<environment>-<cluster>.json` file per environment/cluster where the file scan service is deployed. Both workflows read this file (`PARAMETERS_FILE`) and export every key into the job environment.

```text
dpn-file-scan-service/
└── .github/
    └── config/
        └── azure/
            └── <environment>-<cluster>.json     # e.g. dev-dpn01.json
```

### Step3a: Configure Environment JSON File

| Key | Purpose | Example (`dev-dpn01`) |
|---|---|---|
| `AZURE_SUBSCRIPTION_ID` / `ARM_SUBSCRIPTION_ID` | Azure subscription the resources live in. `ARM_SUBSCRIPTION_ID` is what the `cloud-login` action selects (`az account set`) and what the prerequisites workflow pins to explicitly (the federated SP's default subscription may differ, causing `AuthorizationFailed`) | `f0350356-d639-4845-b2f8-8c1d74d23007` |
| `RESOURCE_GROUP` | Resource group holding the AKS cluster | `rg-aks-dpn-azure-dev-uks-001` |
| `AKS_CLUSTER` | AKS cluster name | `aks-dpn-azure-dev-uks-001` |
| `KEY_VAULT_NAME` | Key Vault holding `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET` (see [Step5](#step5-configure-secrets)). Not read by this service's workflows — the chart reads the vault name from `keyvault.name` in the values file, so keep the two in sync | `kv-dpn-azure-dev-uks-001` |
| `NAMESPACE` | Target namespace | `ns-dpn-01` |
| `BASE_REGISTRY` / `ACR_NAME` | Base registry URL. Both are set to `ghcr.io` on Azure — no Azure Container Registry is used for this service | `ghcr.io` |
| `FILESCAN_STORAGE_ACCOUNT` | Azure Storage Account Defender for Storage scans — the prerequisites workflow enables malware scanning on it and creates the raw (inbound) container (`containerName` input) on it | `stfsdpndev001uks01` |
| `FILESCAN_STORAGE_RG` | Resource group of `FILESCAN_STORAGE_ACCOUNT` | `rg-stfs-dpn-dev001-uks-01` |
| `FILESCAN_SB_SUBSCRIPTION_NAME` | Service Bus subscription the service long-polls for scan-result events, under the topic from [Step2](#step2-azure-resource-setup-service-busevent-griddefender-for-storage) — a **name**, not a resource ID | `dpn-fileupload-scan-results-sub` |
| `FILESCAN_DEFENDER_EVENT_SUBSCRIPTION_NAME` | The Event Grid event subscription name from [Step2](#step2-azure-resource-setup-service-busevent-griddefender-for-storage) that carries Defender's scan verdict events into Service Bus | `dpn-defender-malware-scan-sub` |

> **Note:** the source and destination containers and the destination storage account (e.g. `dp-consumer-raw` / `dp-consumer-stage`) are **not** keys in this config JSON — they are set as Helm values (`env.sourceStorageAccount`/`env.sourceContainer`/`env.destStorageAccount`/`env.destContainer`) in [Step4](#step4-configure-helm-chart-files). In the chart's reference `values/azure/dev-dpn01.yaml` the source account matches `FILESCAN_STORAGE_ACCOUNT` (`stfsdpndev001uks01`) while the destination is a different storage account (`stdevdpnazuredevuks001`). (The AWS equivalent of this doc instead uses two distinct bucket keys, `FILESCAN_SOURCE_BUCKET`/`FILESCAN_DEST_BUCKET`, directly in its config JSON.)
>
> The same JSON file is shared with other components, so it also carries keys this service does not read (e.g. `OAUTH2_PROXY_EXTERNAL_URL`) — leave those as they are. The OTel collector endpoint is not a config JSON key; it is set via `env.otelEndpoint` in the values file ([Step4](#step4-configure-helm-chart-files)).

---

## Step4: Configure Helm Chart Files

Set the parameters below in your environment/cluster's values file. The CD workflow sets `CHART_LOCATION=charts/file-scan-service` and resolves `VALUES_FILE=charts/file-scan-service/values/azure/<environment>-<cluster>.yaml` from the `environment`/`cluster`/`cloud` inputs you select at runtime.

```text
dpn-file-scan-service/
└── charts/
    └── file-scan-service/
        ├── values.yaml                              <- Reference file; do not edit directly
        └── values/
            └── azure/
                └── <environment>-<cluster>.yaml     <- Your environment overrides
```

The following values to be modified in that file

| Item | Value |
|---|---|
| image:repository | `ghcr.io/energy-dsi/dpn-file-scan-service` |
| image:tag | Leave `""` — the workflow sets it from its required `imageTag` input (`--set image.tag=<imageTag>`); the workflow also sets `namespace` from `NAMESPACE` in the config JSON |
| keyvault.name | Key Vault to read `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET`/`TRUSTSTORE-PASSWORD` from — matches `KEY_VAULT_NAME` in the config JSON | `kv-dpn-azure-dev-uks-001` |
| keyvault.clientID | User-assigned managed identity client ID used by the Secrets Store CSI driver (`useVMManagedIdentity: "true"`) to authenticate to Key Vault | `926f11f6-84b7-445f-91b0-c957963f9098` |
| keyvault.tenantId | Azure AD tenant ID | `a63c9e9e-b4db-442a-a94f-08718d788e8c` |
| keyvault.truststorePasswordSecretName | Key Vault object synced into the `dpn-file-scan-service-otel-truststore` Kubernetes Secret (key `password`) and injected as `TRUSTSTORE_PASSWORD`; leave empty to set no `TRUSTSTORE_PASSWORD` | `TRUSTSTORE-PASSWORD` |
| env.otelEndpoint | OTel collector's OTLP endpoint (passed as `OTEL_EXPORTER_OTLP_ENDPOINT`) | `https://dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` |
| env.otelExporterCertificate / env.truststorePath | Path of the `dpn-tls` truststore mounted at `/etc/secrets` (passed as `OTEL_EXPORTER_OTLP_CERTIFICATE` / `TRUSTSTORE_PATH`) | `/etc/secrets/truststore.jks` |
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
| env.otelOauthClientId | Keycloak client ID used to authenticate OTel Collector export | `dpn-service-client` |
| env.otelOauthTokenEndpointUrl | Keycloak token endpoint for the OTel OAuth client, e.g. `https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token`. Not set in the provided Azure values files (chart default `""`), which leaves OTLP OAuth off | `""` |
| keyvault.otelOauthClientSecretName | Key Vault object holding `dpn-service-client`'s secret (`KC-SERVICE-CLIENT-SECRET`), synced into the `dpn-file-scan-service-otel-truststore` Secret (key `oauth-client-secret`) as `OTEL_OAUTH_CLIENT_SECRET`. Not set in the provided Azure values files; if you set it (together with `env.otelOauthTokenEndpointUrl`), also add `KC-SERVICE-CLIENT-SECRET` to `keyvault.objects` | `""` |
| env.otelOauthCaLocation | CA location for the OTel OAuth token endpoint — leave empty (chart default) so it falls back to the OTLP exporter's CA; do not point it at `truststore.jks` | `""` |

> **Note:** there is no Helm value for the Event Grid custom topic or its event subscription — the app only ever consumes from its Service Bus subscription; the Event Grid → Service Bus fan-out from [Step2](#step2-azure-resource-setup-service-busevent-griddefender-for-storage) is wiring set up outside the application. The AWS-only `env.awsRegion`/`env.sourceBucket`/`env.destBucket`/`env.sqsQueueName` fields are not set in the Azure values files and are not used on Azure.
>
> The Deployment always mounts the `dpn-tls` Kubernetes Secret (name from `env.otelTlsSecretName`, default `dpn-tls`) at `/etc/secrets`, so that secret must exist in the namespace before deploying.

---

## Step5: Configure Secrets

Unlike the AWS path, this service sources its OAuth client credentials from **Azure Key Vault**, via the Secrets Store CSI driver's `SecretProviderClass` (the same pattern used by the platform's other services — see [Configure DPN Vault Service](01-configure-dpn-vault-service.md)):

| Parameter | Purpose | Example |
|-----------|---------|---------|
| keyvault.name | Key Vault holding `FILESCAN-CLIENT-ID`/`FILESCAN-CLIENT-SECRET` | `kv-dpn-azure-dev-uks-001` |
| keyvault.objects | CSI driver object list, mounted at `/mnt/keyvault` — must include `FILESCAN-CLIENT-ID` and `FILESCAN-CLIENT-SECRET` (both `type: secret`), alongside the shared `TRUSTSTORE-PASSWORD` object. This list replaces the chart default's list entirely | see the chart's reference `values/azure/<environment>-<cluster>.yaml` |

Both `FILESCAN-CLIENT-ID` and `FILESCAN-CLIENT-SECRET` must already exist in `keyvault.name` before the first deploy — this workflow's Azure prerequisites steps ([Step2](#step2-azure-resource-setup-service-busevent-griddefender-for-storage)) do not seed them; provision them the same way as the other DPN services' Key Vault secrets (see [Configure DPN Vault Service](01-configure-dpn-vault-service.md)).

> **Note:** the AWS equivalent of this doc describes `dpn-gha-file-scan-prerequisites-cd.yaml` seeding a `REPLACE_ME` placeholder for its Secrets Manager equivalent of these two credentials automatically. Nothing in the Azure-conditional steps of that same workflow does the equivalent for Key Vault, so these two secrets (and `TRUSTSTORE-PASSWORD`, which the provided Azure values files also mount) must be created manually before first deploy.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
