# DPN Uninstallation and Decommissioning Process

---

## Table of Contents

- [Overview](#overview)
- [Uninstallation Scope](#uninstallation-scope)
- [Uninstallation Approach](#uninstallation-approach)
- [Pre-Uninstallation Checklist](#pre-uninstallation-checklist)
- [Part 1 — Uninstall DPN Data Pipeline](#part-1--uninstall-dpn-data-pipeline)
  - [Step 1 — Prepare Data Pipeline Uninstall CD Pipeline](#step-1--prepare-data-pipeline-uninstall-cd-pipeline)
  - [Step 2 — Execute Data Pipeline Uninstall CD Pipeline](#step-2--execute-data-pipeline-uninstall-cd-pipeline)
  - [Step 3 — Verify Data Pipeline Removal](#step-3--verify-data-pipeline-removal)
- [Part 2 — Uninstall DPN Federator Certificate Manager](#part-2--uninstall-dpn-federator-certificate-manager)
  - [Step 1 — Prepare Certificate Manager Uninstall CD Pipeline](#step-1--prepare-certificate-manager-uninstall-cd-pipeline)
  - [Step 2 — Execute Certificate Manager Uninstall CD Pipeline](#step-2--execute-certificate-manager-uninstall-cd-pipeline)
  - [Step 3 — Verify Certificate Manager Removal](#step-3--verify-certificate-manager-removal)
- [Part 3 — Uninstall DPN Federator Gateway](#part-3--uninstall-dpn-federator-gateway)
  - [Step 1 — Prepare Federator Gateway Uninstall CD Pipeline](#step-1--prepare-federator-gateway-uninstall-cd-pipeline)
  - [Step 2 — Execute Federator Gateway Uninstall CD Pipeline](#step-2--execute-federator-gateway-uninstall-cd-pipeline)
  - [Step 3 — Verify Federator Gateway Removal](#step-3--verify-federator-gateway-removal)
- [Part 4 — Post-Uninstallation Cleanup](#part-4--post-uninstallation-cleanup)
  - [Remove Container Images from ACR](#remove-container-images-from-acr)
  - [Remove Kafka Topics](#remove-kafka-topics)
  - [Remove Secrets and Certificates](#remove-secrets-and-certificates)
  - [Remove Azure DevOps Pipelines](#remove-azure-devops-pipelines)
- [Final Verification](#final-verification)
- [Review Notes](#review-notes)

---

## Overview

This document describes the procedure for **completely uninstalling the DPN platform** from an organisation's Azure environment.

The uninstallation process removes the following components:

- DPN Data Pipeline containers (adaptors, mappers, extractors)
- DPN Federator Certificate Manager and Vault service
- DPN Federator Gateway (Kafka, Zookeeper, Redis, Federator Server and Client)
- Kubernetes resources and Helm releases
- Container images in Azure Container Registry
- Azure DevOps pipelines

The uninstallation is performed using **dedicated uninstall CD pipelines**, one per repository. Each pipeline uses `helm uninstall` targeted at the specific components it owns. This approach ensures that only the components managed by each repository are removed in a controlled and auditable manner.

The goal of the procedure is to ensure that **all components of the DPN node are safely removed** without leaving orphaned infrastructure resources.

---

## Uninstallation Scope

All the DPN services deployed under DSI Package are part of uninstallation scope. If Organisation choses to have their own component (BYO) then uninstallation part to be managed by Organisations

- DPN Federator Gateway
- DPN Federator Certificate Manager
- DPN Data Pipelines
- DPN File Scan Service
- DPN Health Monitoring Service

---

## Uninstallation Approach

Each DPN repository provides a dedicated uninstall CD pipeline YAML file located under the `cd-pipelines` folder:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── XXX-uninstall-cd.yaml
```

Each pipeline accepts runtime parameters to scope the uninstallation to a specific environment, cluster, and component set. Internally, each pipeline runs `helm uninstall` scoped to the Helm release and component labels that belong to that repository, leaving components from other repositories unaffected.

**Uninstallation must be performed in the following order** to respect service dependencies:

1. Data Pipeline (no dependencies on other DPN components at removal time)
2. Federator Certificate Manager (depends on Vault, which is removed together)
3. Federator Gateway (all remaining infrastructure components)

---

## Pre-Uninstallation Checklist

Before starting the uninstallation process, confirm the following.

- All data exchanges with partner organisations have been stopped
- No active files are currently being processed
- Kafka topics have been drained and contain no unprocessed messages
- All CI/CD pipeline triggers have been disabled in Azure DevOps
- Required data backups have been taken

To verify there are no unprocessed messages, inspect the Kafka topics via the Kafka UI before proceeding:

```
http://`<<kakfa-UI Load balancer IP>>:8086
```

---

## Part 1 — Uninstall DPN Data Pipeline

This part removes all producer and consumer data pipeline containers deployed from the `dpn-data-pipelines` repository. The pipeline targets only the Helm release and component labels associated with the data pipeline and does not affect the Federator or Certificate Manager components.

---

### Step 1 — Prepare Data Pipeline Uninstall CD Pipeline

Create a new Azure DevOps pipeline from the following YAML file in the `dpn-data-pipelines` repository:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dsi-data-pipelines-uninstall-cd.yaml
```

To create the pipeline in Azure DevOps:

1. Go to **Pipelines** and click **New Pipeline**.
2. Select the `dpn-data-pipelines` source repository.
3. Choose **Existing Azure Pipelines YAML file**.
4. Point to `dsi-data-pipelines-uninstall-cd.yaml`.
5. Click **Save** (do not run yet).

---

### Step 2 — Execute Data Pipeline Uninstall CD Pipeline

Trigger the pipeline manually and provide the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `serviceConnection` | Azure service connection for the target environment |
| `environment` | Target environment (e.g. `dev`, `test`, `prd`) |
| `configType` | `producer` or `consumer` — select the pipeline type to remove |
| `namespace` | Kubernetes namespace where the components are deployed |

> **Note:** Run the pipeline separately for `producer` and `consumer` configuration types if both are deployed. The pipeline applies `helm uninstall` scoped to the relevant Helm release and component label selectors for the selected configuration type.

The pipeline internally executes the equivalent of:

```bash
helm uninstall <data-pipeline-release> -n <namespace>
```

If the pipeline completes successfully, the following message will appear at the end of the uninstall stage:

```
DATA PIPELINE UNINSTALL COMPLETE
```

---

### Step 3 — Verify Data Pipeline Removal

After the pipeline completes, confirm that all data pipeline pods have been removed:

```bash
kubectl get pods -n <namespace>
```

Confirm no data pipeline deployments remain:

```bash
kubectl get deployments -n <namespace>
```

No pods with names matching the patterns below should remain:

- `producer-{integration-type}-adaptor-{schema-type}-*`
- `producer-{integration-type}-mapper-{schema-type}-*`
- `consumer-{integration-type}-extractor-*`
- `consumer-{integration-type}-mapper-*`

---

## Part 2 — Uninstall DPN Federator Certificate Manager

This part removes the Federator Certificate Manager and the HashiCorp Vault service deployed from the `dpn-federator-certificate-manager` repository. Removing the Certificate Manager will also remove the P12 keystore and truststore files from the shared storage at `/tls`.

> **Warning:** Once the Certificate Manager and Vault are removed, the Federator Gateway will no longer be able to renew or synchronise certificates. Ensure the Federator Gateway is removed immediately after this step.

---

### Step 1 — Prepare Certificate Manager Uninstall CD Pipeline

Create a new Azure DevOps pipeline from the following YAML file in the `dpn-federator-certificate-manager` repository:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── certificate-manager-uninstall-cd.yaml
```

To create the pipeline in Azure DevOps:

1. Go to **Pipelines** and click **New Pipeline**.
2. Select the `dpn-federator-certificate-manager` source repository.
3. Choose **Existing Azure Pipelines YAML file**.
4. Point to `certificate-manager-uninstall-cd.yaml`.
5. Click **Save** (do not run yet).

---

### Step 2 — Execute Certificate Manager Uninstall CD Pipeline

Trigger the pipeline manually and provide the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `serviceConnection` | Azure service connection for the target environment |
| `environment` | Target environment (e.g. `dev`, `test`, `prd`) |
| `namespace` | Kubernetes namespace where the components are deployed |

The pipeline internally executes the equivalent of:

```bash
helm uninstall dpn-certificate-manager -n <namespace>
```

This removes the Certificate Manager deployment, the Vault deployment, associated Kubernetes services, and the shared storage mount. If the pipeline completes successfully, the following message will appear:

```
CERTIFICATE MANAGER UNINSTALL COMPLETE
```

---

### Step 3 — Verify Certificate Manager Removal

After the pipeline completes, confirm that the Certificate Manager and Vault pods have been removed:

```bash
kubectl get pods -n <namespace>
```

Confirm the associated services have been removed:

```bash
kubectl get svc -n <namespace>
```

No pods with names matching the patterns below should remain:

- `dpn-federator-certificate-manager-*`
- `vault-*`

---

## Part 3 — Uninstall DPN Federator Gateway

This part removes all Federator Gateway components deployed from the `dpn-federator` repository, including Kafka, Zookeeper, Redis, and the Federator Server and Client.

---

### Step 1 — Prepare Federator Gateway Uninstall CD Pipeline

Create a new Azure DevOps pipeline from the following YAML file in the `dpn-federator` repository:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── azure-dpn-uninstall-cd.yaml
```

To create the pipeline in Azure DevOps:

1. Go to **Pipelines** and click **New Pipeline**.
2. Select the `dpn-federator` source repository.
3. Choose **Existing Azure Pipelines YAML file**.
4. Point to `azure-dpn-uninstall-cd.yaml`.
5. Click **Save** (do not run yet).

---

### Step 2 — Execute Federator Gateway Uninstall CD Pipeline

Trigger the pipeline manually and provide the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `serviceConnection` | Azure service connection for the target environment |
| `environment` | Target environment (e.g. `dev`, `test`, `prd`) |
| `namespace` | Kubernetes namespace where the components are deployed |

The pipeline internally executes the equivalent of:

```bash
helm uninstall dpn-platform -n <namespace>
```

This removes all Federator Gateway Helm-managed resources, including Kafka, Zookeeper, Redis, Federator Server, and Federator Client. If the pipeline completes successfully, the following message will appear:

```
DPN FEDERATOR UNINSTALL COMPLETE
```

---

### Step 3 — Verify Federator Gateway Removal

After the pipeline completes, confirm all Federator pods have been removed:

```bash
kubectl get pods -n <namespace>
```

Confirm all services have been removed:

```bash
kubectl get svc -n <namespace>
```

Confirm no Helm releases remain:

```bash
helm list -n <namespace>
```

No pods with names matching the patterns below should remain:

- `dpn-federator-server-*`
- `dpn-federator-client-*`
- `dpn-kafka-src-*`
- `dpn-kafka-target-*`
- `dpn-zookeeper-src-*`
- `dpn-zookeeper-dest-*`
- `dpn-kafka-ui-*`
- `dpn-redis-*`

---

## Part 4 — Post-Uninstallation Cleanup

After all three CD pipeline uninstalls have completed successfully, perform the following manual cleanup steps to remove residual resources from Azure and the Kubernetes cluster.

---

### Remove Container Images from ACR

Remove container images from Azure Container Registry if they are no longer required.

List all repositories:

```bash
az acr repository list --name <acr-name>
```

Delete each repository as required:

```bash
az acr repository delete \
  --name <acr-name> \
  --repository <image-name> \
  --yes
```

Repeat for all DPN-related images, including:

- `dpn-federator-server`
- `dpn-federator-client`
- `dpn-federator-certificate-manager`
- `producer-file-adaptor-*`
- `producer-file-mapper-*`
- `consumer-file-extractor-*`
- `consumer-file-mapper-*`

---

### Remove Kafka Topics

If the Kafka namespace and cluster have been fully removed by the Federator uninstall pipeline, Kafka topics will have been deleted automatically. If any topics persist, remove them via the Kafka UI before the namespace is deleted.

```
http://kafka-ui:8085
```

Typical DPN topic names include:

- `dpn-producer-<filetype>-raw`
- `dpn-producer-<filetype>-valid-schema`
- `dpn-producer-<filetype>-knowledge`
- `dpn-consumer-<filetype>-valid-schema`
- `dpn-consumer-<filetype>-valid-schema-knowledge`

---

### Remove Secrets and Certificates

Delete any remaining Kubernetes secrets that were not removed by the Helm uninstall:

```bash
kubectl get secrets -n <namespace>
kubectl delete secrets --all -n <namespace>
```

Remove the P12 keystore and truststore files from the shared storage location if persistent volume claims were not deleted by the uninstall pipeline:

```bash
kubectl delete pvc --all -n <namespace>
```

Remove any certificates and secrets from **Azure Key Vault** that are no longer required, following the organisation's secrets management policy.

---

### Remove Azure DevOps Pipelines

Delete all Azure DevOps pipelines associated with the DPN node once uninstallation is confirmed complete. These include:

- Federator CI and CD pipelines
- Federator uninstall CD pipeline
- Certificate Manager CI, CD, and uninstall CD pipelines
- Data Pipeline CI, CD, and uninstall CD pipelines

Pipeline definitions are located at:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        ├── ci-pipelines/
        └── cd-pipelines/
```

Pipelines can be removed through the **Azure DevOps pipeline management interface** under **Pipelines → All pipelines**.

---

## Final Verification

After all parts are complete, confirm the following conditions are met before closing the decommissioning activity.

| Verification | Command | Expected Result |
|-------------|---------|-----------------|
| No pods running | `kubectl get pods -n <namespace>` | No resources found |
| No services remaining | `kubectl get svc -n <namespace>` | No resources found |
| No deployments remaining | `kubectl get deployments -n <namespace>` | No resources found |
| No Helm releases | `helm list -n <namespace>` | No releases found |
| No persistent volume claims | `kubectl get pvc -n <namespace>` | No resources found |
| No secrets remaining | `kubectl get secrets -n <namespace>` | No resources found |
| ACR repositories cleared | `az acr repository list --name <acr-name>` | No DPN repositories listed |

If all commands return no DPN resources, the DPN platform has been successfully decommissioned.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
