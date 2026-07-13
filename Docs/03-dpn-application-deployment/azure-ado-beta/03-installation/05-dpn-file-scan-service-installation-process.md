# DPN Installation Process

---

# Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation Steps](#installation-steps)
  - [Step 1 — Provision the Quarantine Container](#step-1--provision-the-quarantine-container)
  - [Step 2 — Enable Microsoft Defender for Storage](#step-2--enable-microsoft-defender-for-storage)
  - [Step 3 — Configure the Event Grid System Topic](#step-3--configure-the-event-grid-system-topic)
  - [Step 4 — Provision the Service Bus Topic and Subscription](#step-4--provision-the-service-bus-topic-and-subscription)
  - [Step 5 — Assign Managed Identity RBAC Roles](#step-5--assign-managed-identity-rbac-roles)
  - [Step 6 — Configure GHCR Image Access](#step-6--configure-ghcr-image-access)
  - [Step 7 — Configure Environment Approval Gates](#step-7--configure-environment-approval-gates)
  - [Step 8 — Build and Deploy the Verification Service](#step-8--build-and-deploy-the-verification-service)
  - [Step 9 — Verify the Horizontal Pod Autoscaler](#step-9--verify-the-horizontal-pod-autoscaler)
  - [Step 10 — Verify the Deployment](#step-10--verify-the-deployment)
- [Troubleshooting](#troubleshooting)
- [Review Notes](#review-notes)

---

## Overview

This document describes the planned installation process for the DPN File Scanning Service (the ADR's "DPN File Verification Service"), which inserts a malware-scanning gate in front of the existing DPN Data Pipeline Consumer Extractor. It depends on the DPN Data Pipeline already being installed, since it writes into the same `dp-consumer-stage` container that component already reads from.

The service is **fully containerised**: the only artefact deployed to AKS is the single custom image `ghcr.io/energy-dsi/dpn-file-scan-service:1.0.0`. It has no third-party runtime containers to install alongside it — its dependencies (Defender for Storage, Event Grid, Service Bus) are Azure PaaS services, provisioned in Steps 1–4 below rather than deployed as pods.

---

## Prerequisites

- The DPN Data Pipeline Consumer (Extractor + Schema Mapper) is already installed and reading from `dp-consumer-stage` — see the [DPN Data Pipeline Installation Process](../dpn-data-pipelines/installation.md).
- An AKS cluster with access to deploy new workloads, with the **metrics-server** running (required for HPA — enabled by default on AKS).
- Azure subscription access sufficient to enable Microsoft Defender for Storage, create an Event Grid System Topic, and provision a Service Bus namespace/topic.
- Permission to create and assign Managed Identities and RBAC role assignments.
- An OTEL-compatible log aggregator endpoint to send processing logs to.
- Access to the `ghcr.io/energy-dsi/dpn-file-scan-service` GHCR package — see [Step 6](#step-6--configure-ghcr-image-access).
- Confirmation that the target environment's Azure DevOps Environment approval gate is configured — see [Step 7](#step-7--configure-environment-approval-gates).

---

## Installation Steps

### Step 1 — Provision the Quarantine Container

Create a new container, `dp-consumer-raw`, on the storage account used for inbound DPN data products. This is separate from — and sits in front of — the existing `dp-consumer-stage` container.

```bash
az storage container create \
  --account-name <storage-account-name> \
  --name dp-consumer-raw
```

Update the Federator Client's configuration so it writes inbound files to `dp-consumer-raw` instead of directly to `dp-consumer-stage`.

---

### Step 2 — Enable Microsoft Defender for Storage

Enable Defender for Storage on the storage account hosting `dp-consumer-raw`, with malware scanning turned on.

```bash
az security pricing create \
  --name StorageAccounts \
  --tier Standard
```

Confirm malware scanning is scoped to (at minimum) the `dp-consumer-raw` container.

---

### Step 3 — Configure the Event Grid System Topic

Create an Event Grid System Topic on the storage account, and a subscription that forwards the relevant events (blob created / Defender for Storage scan result) to the Service Bus Topic created in Step 4.

```bash
az eventgrid system-topic create \
  --name <system-topic-name> \
  --resource-group <resource-group> \
  --source <storage-account-resource-id> \
  --topic-type Microsoft.Storage.StorageAccounts

az eventgrid system-topic event-subscription create \
  --name <subscription-name> \
  --system-topic-name <system-topic-name> \
  --resource-group <resource-group> \
  --endpoint-type servicebustopic \
  --endpoint <service-bus-topic-resource-id>
```

---

### Step 4 — Provision the Service Bus Topic and Subscription

Create the Service Bus namespace (if one doesn't already exist), Topic, and a Subscription for the Verification Service to read from.

```bash
az servicebus namespace create --name <sb-namespace> --resource-group <resource-group>
az servicebus topic create --name dpn-file-scan-results --namespace-name <sb-namespace> --resource-group <resource-group>
az servicebus topic subscription create \
  --name dpn-file-verification-service \
  --topic-name dpn-file-scan-results \
  --namespace-name <sb-namespace> \
  --resource-group <resource-group>
```

---

### Step 5 — Assign Managed Identity RBAC Roles

Per the ADR's Azure design (see the [Configuration Guide](./config.md#managed-identity--rbac-configuration) for the full table), assign:

| Identity | Role | Scope |
|----------|------|-------|
| Event Grid System Topic's identity | Azure Service Bus Data Sender | Service Bus Topic |
| Verification Service's Managed Identity | Azure Service Bus Data Receiver | Service Bus Subscription |
| Verification Service's Managed Identity | Storage Blob Data Reader | `dp-consumer-raw` container |
| Verification Service's Managed Identity | Storage Blob Data Contributor | `dp-consumer-stage` container |

```bash
az role assignment create \
  --assignee <managed-identity-principal-id> \
  --role "Storage Blob Data Reader" \
  --scope <dp-consumer-raw-container-resource-id>

az role assignment create \
  --assignee <managed-identity-principal-id> \
  --role "Storage Blob Data Contributor" \
  --scope <dp-consumer-stage-container-resource-id>
```

---

### Step 6 — Configure GHCR Image Access

The service pulls a single image, `ghcr.io/energy-dsi/dpn-file-scan-service:1.0.0`, at deploy time. This is the **only** image AKS pulls for this service — the Python build base (`python:3.12.11-slim-bookworm`) used to build it is a build-stage-only dependency pulled directly from Docker Hub by the CI pipeline, never by AKS, and is not mirrored to GHCR (see [Third-Party / Build-Base Image](./config.md#third-party--build-base-image-not-mirrored-to-ghcr) — this differs from the DPN Data Pipeline, which does mirror its third-party runtime images).

1. Confirm whether the `energy-dsi/dpn-file-scan-service` GHCR package is public or private.
2. If private, create an `imagePullSecrets`-referenced Kubernetes secret in the target namespace **before** running the CD pipeline:
   ```bash
   kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
   ```
3. Ensure the CI pipeline's service connection/credentials have `write:packages` scope if this deployment will also be building and publishing the image, not just pulling a pre-built one.

---

### Step 7 — Configure Environment Approval Gates

Before running the CD pipeline against any environment beyond Development, confirm the corresponding Azure DevOps Environment has its approval check configured — see [Environment-Specific Approval Gates](./config.md#environment-specific-approval-gates) in the Configuration Guide (Development: none; Test: single approver; Pre-Production: two approvers; Production: two approvers plus a defined deployment window).

This service sits directly in the inbound file security path, so treat its Production approval requirement as at least as strict as the Data Pipeline's.

---

### Step 8 — Build and Deploy the Verification Service

**No CI/CD pipeline exists for this repository yet.** Once implementation begins, this step should follow the same Azure DevOps CI/CD pattern used by the other DPN components:

1. CI pipeline builds the image, tags it with a fixed semantic version, and pushes to `ghcr.io/energy-dsi/dpn-file-scan-service:<version>`.
2. CD pipeline deploys it via Helm, using the values proposed in the [Configuration Guide](./config.md#service-configuration-parameters), pausing at the approval gate configured in Step 7 for any environment beyond Development.
3. Confirm the deployed pod's image reference matches the expected GHCR path and tag:
   ```bash
   kubectl get pods -n <namespace> -l app=dpn-file-scan-service -o jsonpath='{.items[*].spec.containers[*].image}'
   ```

---

### Step 9 — Verify the Horizontal Pod Autoscaler

If deployed with `hpa.enabled: true` (see [Horizontal Pod Autoscaler (HPA) Configuration](./config.md#horizontal-pod-autoscaler-hpa-configuration)):

```bash
kubectl get hpa -n <namespace>
```

Confirm the `TARGETS` column shows real CPU/memory percentages (not `<unknown>`, which indicates metrics-server is not reachable). If `hpa.maxReplicas` is set above `1`, also confirm the Service Bus consumption pattern doesn't allow two replicas to process the same scan-result message twice — see [Open Questions](./config.md#open-questions) in the Configuration Guide.

---

### Step 10 — Verify the Deployment

1. Upload a benign test file into `dp-consumer-raw` (via the Federator Client, or directly for testing purposes) and confirm it lands in `dp-consumer-stage` after scanning, with a corresponding log entry in the OTEL aggregator.
2. Upload an [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) into `dp-consumer-raw` and confirm:
   - Defender for Storage flags it as malicious and deletes it from `dp-consumer-raw`.
   - It never appears in `dp-consumer-stage`.
   - The Verification Service logs the malicious-file event appropriately.
3. Confirm the existing Consumer Extractor continues to function against `dp-consumer-stage` without any changes to its own configuration.

---

## Troubleshooting

### Scan-Result Events Not Reaching the Verification Service

Check the Event Grid subscription's delivery status and the Service Bus Topic/Subscription for dead-lettered messages. Confirm the Event Grid System Topic's Managed Identity has the **Azure Service Bus Data Sender** role on the topic.

### GHCR Image Pull Failures

If the pod shows `ImagePullBackOff` or `ErrImagePull`:

- If the `energy-dsi/dpn-file-scan-service` GHCR package is private, confirm the `imagePullSecrets` referenced by the chart exists in the target namespace with a valid, non-expired GitHub PAT (`read:packages` scope) — see [Step 6](#step-6--configure-ghcr-image-access).
- Confirm the AKS node pool has outbound network access to `ghcr.io`.
- Confirm the image reference matches the actual published GHCR package/tag exactly — remember AKS should **never** be attempting to pull `python:3.12.11-slim-bookworm` directly; if it is, the chart is misconfigured to reference the build-base image instead of the built service image.

### CD Pipeline Stuck Awaiting Approval

Check **Pipelines → Runs → [run]** for a pending **Review** action, and confirm the correct approver(s) for that environment are configured under **Pipelines → Environments → [environment] → Approvals and checks** (see [Step 7](#step-7--configure-environment-approval-gates)).

### Verification Service Cannot Read from `dp-consumer-raw`

Confirm the Verification Service's Managed Identity has the **Storage Blob Data Reader** role scoped to the `dp-consumer-raw` container, and that Managed Identity (not a connection string) is actually being used at runtime.

### Verified Files Not Appearing in `dp-consumer-stage`

Confirm the Verification Service's Managed Identity has the **Storage Blob Data Contributor** role scoped to `dp-consumer-stage`, and check the service's logs (via the OTEL aggregator) for write failures.

### HPA Not Scaling

If `kubectl get hpa` shows `<unknown>` under `TARGETS`, confirm metrics-server is running (`kubectl get deployment metrics-server -n kube-system`) and that the pod has CPU/memory `requests` set in its Deployment spec.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
