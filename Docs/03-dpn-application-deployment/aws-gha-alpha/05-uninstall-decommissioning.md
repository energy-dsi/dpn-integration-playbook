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
  - [Remove Container Images from Container Registry](#remove-container-images-from-cr)
  - [Remove Kafka Topics](#remove-kafka-topics)
  - [Remove Secrets and Certificates](#remove-secrets-and-certificates)
  - [Remove AWS DevOps Pipelines](#remove-aws-devops-pipelines)
- [Final Verification](#final-verification)
- [Review Notes](#review-notes)

---

## Overview

This document describes the process for **completely uninstalling the DPN platform** from an organisation's **AWS environment.**

The uninstallation process removes the following components:

- DPN Data Pipeline containers (adaptors, mappers, extractors)
- DPN Federator Certificate Manager and Vault service
- DPN Federator Gateway (Kafka, Zookeeper, Redis, Federator Server and Client)
- Kubernetes resources and Helm releases
- Container images in Container Registry
- GitHub Actions workflows

The uninstallation is performed using **dedicated uninstall CD pipelines**, one per repository. Each pipeline uses `helm uninstall` targeted at the specific components it owns. This approach ensures that only the components managed by each repository are removed in a controlled and auditable manner.

The goal of the procedure is to ensure that **all components of the DPN node are safely removed** without leaving orphaned infrastructure resources.

---

## Uninstallation Scope

The following components are removed during this procedure, grouped by the repository that manages them.

| Component | Repository | Description |
|-----------|------------|-------------|
| Producer Adaptor | dpn-data-pipelines | Data transformation — producer side |
| Producer Mapper | dpn-data-pipelines | Schema mapping — producer side |
| Consumer Extractor | dpn-data-pipelines | File extraction — consumer side |
| Consumer Mapper | dpn-data-pipelines | Schema validation — consumer side |
| Certificate Manager | dpn-federator-certificate-manager | Certificate lifecycle and P12 keystore management |
| HashiCorp Vault | dpn-federator-certificate-manager | Secret store for key pair and certificates |
| Federator Server | dpn-federator | Outgoing data transmission via gRPC |
| Federator Client | dpn-federator | Incoming data reception via gRPC |
| Kafka Source | dpn-federator | Source Kafka cluster |
| Kafka Target | dpn-federator | Target Kafka cluster |
| Zookeeper Source | dpn-federator | Coordination for source Kafka |
| Zookeeper Target | dpn-federator | Coordination for target Kafka |
| Kafka UI | dpn-federator | Kafka monitoring interface |
| Redis | dpn-federator | Kafka offset and token cache |

---

## Uninstallation Approach

Each DPN repository provides a dedicated uninstall CD pipeline YAML file located under the `cd-pipelines` folder:

```
Root-Repository/
└── .pipelines/
    └── github-actions-pipelines/
        └── aws-pipelines/
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
- All CI/CD workflow triggers have been disabled in GitHub Actions.
- Required data backups have been taken

To verify there are no unprocessed messages, inspect the Kafka topics via the Kafka UI before proceeding:

```
http://kafka-ui:8085
```

---

## Part 1 — Uninstall DPN Data Pipeline

This part removes all producer and consumer data pipeline containers deployed from the `dpn-data-pipelines` repository. The pipeline targets only the Helm release and component labels associated with the data pipeline and does not affect the Federator or Certificate Manager components.

---

### Step 1 — Prepare Data Pipeline Uninstall CD Pipeline

Create a new pipeline from the following YAML file in the `dpn-data-pipelines` repository:

```
Root-Repository/
└── .pipelines/
    └── github-actions-pipelines/
        └── aws-pipelines/
            └── cd-pipelines/
                └── dsi-data-pipelines-uninstall-cd.yaml
```

To create the pipeline in AWS DevOps:

1. Go to your GitHub repository (dpn-data-pipelines).
2. Navigate to `.github/workflows/` (if folder not present then create it)
3. Upload or create a new workflow file: dsi-data-pipelines-uninstall-cd.yaml
4. Commit and push the file to the repository (e.g., to the main branch).
5. The workflow will now appear under: GitHub → Actions tab

---

### Step 2 — Execute Data Pipeline Uninstall CD Pipeline

Trigger the pipeline manually and provide the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `role-to-assume` | AWS IAM Role used for authentication via GitHub Actions (OIDC) |
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

Create a new pipeline from the following YAML file in the `dpn-federator-certificate-manager` repository:

```
Root-Repository/
└── .pipelines/
    └── github-actions-pipelines/
        └── aws-pipelines/
            └── cd-pipelines/
                └── certificate-manager-uninstall-cd.yaml
```

To create the pipeline in AWS DevOps:

1. Go to your GitHub repository (dpn-federator-certificate-manager).
2. Navigate to `.github/workflows/` (if folder not present then create it)
3. Upload or create a new workflow file: certificate-manager-uninstall-cd.yaml
4. Commit and push the file to the repository (e.g., to the main branch).
5. The workflow will now appear under: GitHub → Actions tab

---

### Step 2 — Execute Certificate Manager Uninstall CD Pipeline

Trigger the pipeline manually and provide the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `role-to-assume` | AWS IAM Role used for authentication via GitHub Actions (OIDC) |
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

Create a new AWS DevOps pipeline from the following YAML file in the `dpn-federator` repository:

```
Root-Repository/
└── .pipelines/
    └── github-actions-pipelines/
        └── aws-pipelines/
            └── cd-pipelines/
                └── aws-dpn-uninstall-cd.yaml
```

To create the pipeline in AWS DevOps:

1. Go to your GitHub repository (dpn-federator).
2. Navigate to `.github/workflows/` (if folder not present then create it)
3. Upload or create a new workflow file: aws-dpn-uninstall-cd.yaml
4. Commit and push the file to the repository (e.g., to the main branch).
5. The workflow will now appear under: GitHub → Actions tab

---

### Step 2 — Execute Federator Gateway Uninstall CD Pipeline

Trigger the pipeline manually and provide the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `role-to-assume` | AWS IAM Role used for authentication via GitHub Actions (OIDC) |
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

After all three CD pipeline uninstalls have completed successfully, perform the following manual cleanup steps to remove residual resources from AWS and the Kubernetes cluster.

---

### Remove Container Images from Container Registry

Remove container images from Container Registry if they are no longer required.

List all repositories:

```bash
<registry-cli> repository list --registry <registry-name>
```

Delete each repository as required:

```bash
<registry-cli> repository delete \
  --registry <registry-name> \
  --repository <image-name> \
  --force
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

Remove any certificates and secrets from **AWS Secret Manager** that are no longer required, following the organisation's secrets management policy.

---

### Remove AWS DevOps Pipelines

Delete all AWS DevOps pipelines associated with the DPN node once uninstallation is confirmed complete. These include:

- Federator CI and CD pipelines
- Federator uninstall CD pipeline
- Certificate Manager CI, CD, and uninstall CD pipelines
- Data Pipeline CI, CD, and uninstall CD pipelines

Pipeline definitions are located at:

```
Root-Repository/
└── .pipelines/
    └── github-actions-pipelines/
        └── aws-pipelines
            ├── ci-pipelines/
            └── cd-pipelines/
```

Pipeline workflows can be removed through the GitHub Actions management interface under: Repository → Actions → Workflows

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
| Container repositories cleared | <container-registry-cli> list-repositories | filter "dpn" | No DPN repositories present

If all commands return no DPN resources, the DPN platform has been successfully decommissioned.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
