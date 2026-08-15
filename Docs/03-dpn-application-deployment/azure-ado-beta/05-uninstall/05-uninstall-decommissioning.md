# DPN Uninstallation and Decommissioning Process

---

## Table of Contents

- [Overview](#overview)
- [Uninstallation Scope](#uninstallation-scope)
- [Uninstallation Approach](#uninstallation-approach)
- [Uninstallation Sequence](#uninstallation-sequence)
- [Pre-Uninstallation Checklist](#pre-uninstallation-checklist)
- [Part 1 — Uninstall DPN File Scanning Service](#part-1--uninstall-dpn-file-scanning-service)
  - [Step 1 — Prepare File Scanning Service Uninstall CD Pipeline](#step-1--prepare-file-scanning-service-uninstall-cd-pipeline)
  - [Step 2 — Execute File Scanning Service Uninstall CD Pipeline](#step-2--execute-file-scanning-service-uninstall-cd-pipeline)
  - [Step 3 — Verify File Scanning Service Removal](#step-3--verify-file-scanning-service-removal)
- [Part 2 — Uninstall DPN Data Pipeline](#part-2--uninstall-dpn-data-pipeline)
  - [Step 1 — Prepare Data Pipeline Uninstall CD Pipeline](#step-1--prepare-data-pipeline-uninstall-cd-pipeline)
  - [Step 2 — Execute Data Pipeline Uninstall CD Pipeline](#step-2--execute-data-pipeline-uninstall-cd-pipeline)
  - [Step 3 — Verify Data Pipeline Removal](#step-3--verify-data-pipeline-removal)
- [Part 3 — Uninstall DPN Federator Certificate Manager](#part-3--uninstall-dpn-federator-certificate-manager)
  - [Step 1 — Prepare Certificate Manager Uninstall CD Pipeline](#step-1--prepare-certificate-manager-uninstall-cd-pipeline)
  - [Step 2 — Execute Certificate Manager Uninstall CD Pipeline](#step-2--execute-certificate-manager-uninstall-cd-pipeline)
  - [Step 3 — Verify Certificate Manager Removal](#step-3--verify-certificate-manager-removal)
- [Part 4 — Uninstall DPN Federator Gateway](#part-4--uninstall-dpn-federator-gateway)
  - [Step 1 — Prepare Federator Gateway Uninstall CD Pipeline](#step-1--prepare-federator-gateway-uninstall-cd-pipeline)
  - [Step 2 — Execute Federator Gateway Uninstall CD Pipeline](#step-2--execute-federator-gateway-uninstall-cd-pipeline)
  - [Step 3 — Verify Federator Gateway Removal](#step-3--verify-federator-gateway-removal)
- [Part 5 — Uninstall DPN Health Monitoring Service](#part-5--uninstall-dpn-health-monitoring-service)
  - [Step 1 — Remove Health Monitoring Sub-Components](#step-1--remove-health-monitoring-sub-components)
  - [Step 2 — Verify Health Monitoring Service Removal](#step-2--verify-health-monitoring-service-removal)
- [Part 6 — Post-Uninstallation Cleanup](#part-6--post-uninstallation-cleanup)
  - [Remove Container Images from ACR / GHCR](#remove-container-images-from-acr--ghcr)
  - [Remove Kafka Topics](#remove-kafka-topics)
  - [Remove Secrets and Certificates](#remove-secrets-and-certificates)
  - [Remove Azure DevOps Pipelines](#remove-azure-devops-pipelines)
- [Final Verification](#final-verification)
- [Review Notes](#review-notes)

---

## Overview

This document describes the procedure for **completely uninstalling the DPN platform** from an organisation's Azure environment.

The uninstallation process removes the following components:

- DPN File Scanning Service
- DPN Data Pipeline containers (adaptors, mappers, extractors)
- DPN Federator Certificate Manager and Vault service
- DPN Federator Gateway (Kafka, Zookeeper, Redis, Federator Server and Client)
- DPN Health Monitoring Service (Kafka-health, OpenTelemetry Collector, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, Nginx-observability)
- Kubernetes resources and Helm releases
- Container images in Azure Container Registry / GHCR
- Azure DevOps pipelines

The uninstallation is performed using **dedicated uninstall CD pipelines**, one per repository, where one exists. Each pipeline uses `helm uninstall` targeted at the specific components it owns. This approach ensures that only the components managed by each repository are removed in a controlled and auditable manner. Where no dedicated uninstall pipeline exists (currently, the Health Monitoring Service), the equivalent manual `helm uninstall` commands are given instead — see [Part 5](#part-5--uninstall-dpn-health-monitoring-service).

The goal of the procedure is to ensure that **all components of the DPN node are safely removed** without leaving orphaned infrastructure resources.

---

## Uninstallation Scope

All DPN services deployed as part of the DSI package are in scope for this uninstallation process. If an Organisation has chosen to bring their own (BYO) version of a component instead of the DSI-provided one, uninstallation of that component is the Organisation's own responsibility and is not covered here.

- DPN File Scan Service
- DPN Data Pipelines
- DPN Federator Certificate Manager
- DPN Federator Gateway
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

At the time of writing, no dedicated uninstall pipeline was found for the DPN Health Monitoring Service. [Part 5](#part-5--uninstall-dpn-health-monitoring-service) gives the manual `helm uninstall` equivalent, one command per sub-component, following the same removal order described below.

---

## Uninstallation Sequence

**Uninstallation must be performed in the following order**, to respect the same runtime dependencies used elsewhere in DPN's documentation (see the dependency chain in the Rollback and Recovery Process):

```
File Scanning Service -> Data Pipeline -> Federator Gateway -> Federator Certificate Manager -> Vault 
```

Because uninstallation removes components rather than reverting them, work **up the chain, from the most dependent component to the most foundational one** — the reverse of the order you would use to install them:

1. **File Scanning Service** — remove first. It depends on the Data Pipeline's `dp-consumer-stage` container already existing; removing it first avoids scan results being written into a container that may be mid-removal.
2. **Data Pipeline** — has no other DPN component depending on it for its own removal, and no longer has anything writing into it once File Scanning Service is gone.
3. **Federator Certificate Manager (and Vault, removed together)** — safe to remove once nothing downstream still expects it to issue or renew certificates.
4. **Federator Gateway** — remove **immediately after** step 3. Once the Certificate Manager and Vault are gone, the Gateway can no longer renew or synchronise certificates, so leaving it running afterward serves no purpose and it will begin to fail on its own.
5. **Health Monitoring Service** — remove last. It has no other DPN component depending on it to function, and keeping it in place while the components above are removed means its dashboards can still be used to confirm each preceding removal completed cleanly.

Parts 1–5 below are ordered to match this sequence — follow them top to bottom rather than picking an order of convenience.

---

## Pre-Uninstallation Checklist

Before starting the uninstallation process, confirm the following.

- All data exchanges with partner organisations have been stopped
- No active files are currently being processed
- Kafka topics have been drained and contain no unprocessed messages, on **both** the main DPN Kafka (used by Federator Gateway / Data Pipeline) and the Health Monitoring Service's separate `otel-logs`/`otel-traces`/`otel-metrics` Kafka in `ns-dpn-health-01`
- All CI/CD pipeline triggers have been disabled in Azure DevOps
- Required data backups have been taken, including a secure offline copy of the certificate bundle if Vault/Certificate Manager are in scope

To verify there are no unprocessed messages, inspect the Kafka topics via the relevant Kafka UI before proceeding. Note these are two separate Kafka clusters with two separate UIs:

```
# Main DPN Kafka UI (Federator Gateway / Data Pipeline)
http://<kafka-ui-loadbalancer-ip>:8086

# Health Monitoring Service Kafka UI (ns-dpn-health-01)
http://<kafka-health-ui-loadbalancer-ip>:8082
```

---

## Part 1 — Uninstall DPN File Scanning Service

This part removes the DPN File Scanning Service deployed from the `dpn-file-scan-service` repository. It is removed first, per [Uninstallation Sequence](#uninstallation-sequence), since it depends on the Data Pipeline's `dp-consumer-stage` container.

---

### Step 1 — Prepare File Scanning Service Uninstall CD Pipeline

Create a new Azure DevOps pipeline from the following YAML file in the `dpn-file-scan-service` repository:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-file-scan-service-uninstall-cd.yaml
```

To create the pipeline in Azure DevOps:

1. Go to **Pipelines** and click **New Pipeline**.
2. Select the `dpn-file-scan-service` source repository.
3. Choose **Existing Azure Pipelines YAML file**.
4. Point to `dpn-file-scan-service-uninstall-cd.yaml`.
5. Click **Save** (do not run yet).

---

### Step 2 — Execute File Scanning Service Uninstall CD Pipeline

Trigger the pipeline manually and provide the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `serviceConnection` | Azure service connection for the target environment |
| `environment` | Target environment (e.g. `dev`, `test`, `prd`) |
| `namespace` | Kubernetes namespace where the component is deployed |

The pipeline internally executes the equivalent of:

```bash
helm uninstall dpn-file-scan-service -n <namespace>
```

If the pipeline completes successfully, the following message will appear at the end of the uninstall stage:

```
FILE SCANNING SERVICE UNINSTALL COMPLETE
```

---

### Step 3 — Verify File Scanning Service Removal

After the pipeline completes, confirm the File Scanning Service pod has been removed:

```bash
kubectl get pods -n <namespace>
```

No pods matching the pattern below should remain:

- `dpn-file-scan-service-*`

Confirm the `dp-consumer-raw` container's Event Grid subscription and associated Service Bus topic created during the File Scanning Service's installation are also removed or disabled, if they are not cleaned up automatically by the pipeline.

---

## Part 2 — Uninstall DPN Data Pipeline

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

## Part 3 — Uninstall DPN Federator Certificate Manager

This part removes the Federator Certificate Manager and the HashiCorp Vault service deployed from the `dpn-federator-certificate-manager` repository. Removing the Certificate Manager will also remove the P12 keystore and truststore files from the shared storage at `/tls`.

> **Warning:** Once the Certificate Manager and Vault are removed, the Federator Gateway will no longer be able to renew or synchronise certificates. Per [Uninstallation Sequence](#uninstallation-sequence), proceed directly to [Part 4](#part-4--uninstall-dpn-federator-gateway) immediately after this step.

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

## Part 4 — Uninstall DPN Federator Gateway

This part removes all Federator Gateway components deployed from the `dpn-federator` repository, including Kafka, Zookeeper, Redis, and the Federator Server and Client. Per [Uninstallation Sequence](#uninstallation-sequence), this should be performed immediately after [Part 3](#part-3--uninstall-dpn-federator-certificate-manager).

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

## Part 5 — Uninstall DPN Health Monitoring Service

This part removes the Health Monitoring Service stack deployed in `ns-dpn-health-01`. No dedicated uninstall CD pipeline was found for this repository — the following commands are the manual equivalent, run per sub-component. This is removed **last**, per [Uninstallation Sequence](#uninstallation-sequence), so it remains available to confirm the earlier removals completed cleanly.

---

### Step 1 — Remove Health Monitoring Sub-Components

Remove each Helm release in the **reverse of the deployment dependency order** used to install them (`Init → Kafka → OpenSearch → Prometheus → Thanos → DataPrepper/Jaeger → Perses → OTel → NginxObservability`), so no component is left pointing at a dependency that's already gone:

```bash
helm uninstall nginx-observability -n ns-dpn-health-01
helm uninstall otel-collector -n ns-dpn-health-01
helm uninstall perses -n ns-dpn-health-01
helm uninstall jaeger -n ns-dpn-health-01
helm uninstall data-prepper -n ns-dpn-health-01
helm uninstall thanos -n ns-dpn-health-01
helm uninstall prometheus -n ns-dpn-health-01
helm uninstall opensearch -n ns-dpn-health-01
helm uninstall kafka-health -n ns-dpn-health-01
```

> **Note:** Removing `nginx-observability` first also removes proxied access to the Federator's Kafka UI mentioned in the [Pre-Uninstallation Checklist](#pre-uninstallation-checklist) — complete any Kafka topic checks before this step.

---

### Step 2 — Verify Health Monitoring Service Removal

Confirm all Health Monitoring pods have been removed:

```bash
kubectl get pods -n ns-dpn-health-01
```

Confirm no Helm releases remain in the namespace:

```bash
helm list -n ns-dpn-health-01
```

Confirm the namespace itself can be safely removed, if no longer required:

```bash
kubectl delete namespace ns-dpn-health-01
```

---

## Part 6 — Post-Uninstallation Cleanup

After Parts 1–5 have completed successfully, perform the following manual cleanup steps to remove residual resources from Azure and the Kubernetes cluster.

---

### Remove Container Images from ACR / GHCR

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
- `dpn-file-scan-service`
- `producer-file-adaptor-*`
- `producer-file-mapper-*`
- `consumer-file-extractor-*`
- `consumer-file-mapper-*`

If any component was deployed using DSI-provided GHCR images (`ghcr.io/energy-dsi/...`), no image deletion is required on the `energy-dsi` GHCR itself — those images are shared, DSI-managed packages. Only remove the `ghcr-pull-secret` Kubernetes secret used to authenticate against it, per [Remove Secrets and Certificates](#remove-secrets-and-certificates).

---

### Remove Kafka Topics

If the Kafka namespace and cluster have been fully removed by the Federator uninstall pipeline, Kafka topics will have been deleted automatically. If any topics persist, remove them via the Kafka UI before the namespace is deleted.

```
http://<kafka-ui-loadbalancer-ip>:8086
```

Typical DPN topic names include:

- `dpn-producer-<filetype>-raw`
- `dpn-producer-<filetype>-valid-schema`
- `dpn-producer-<filetype>-knowledge`
- `dpn-consumer-<filetype>-valid-schema`
- `dpn-consumer-<filetype>-valid-schema-knowledge`

If Health Monitoring Service's own Kafka (`ns-dpn-health-01`) was not fully removed by [Part 5](#part-5--uninstall-dpn-health-monitoring-service), also check for and remove its topics:

- `otel-logs`
- `otel-traces`
- `otel-metrics`

---

### Remove Secrets and Certificates

Delete any remaining Kubernetes secrets that were not removed by the Helm uninstall:

```bash
kubectl get secrets -n <namespace>
kubectl delete secrets --all -n <namespace>
```

This includes the `ghcr-pull-secret` used for GHCR image pulls, if one was created during installation.

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
- File Scanning Service CI, CD, and uninstall CD pipelines
- Health Monitoring Service CD pipelines (no dedicated uninstall pipeline exists to remove — see [Part 5](#part-5--uninstall-dpn-health-monitoring-service))

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

After all parts are complete, confirm the following conditions are met before closing the decommissioning activity. Run these checks against **both** the main DPN namespace and `ns-dpn-health-01`, if Health Monitoring Service was in scope.

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
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
