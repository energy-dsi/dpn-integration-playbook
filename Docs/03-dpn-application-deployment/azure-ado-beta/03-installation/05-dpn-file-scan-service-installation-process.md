# DPN Installation Process

---

# Table of Contents

- [Overview](#overview)

- [Prerequisites](#prerequisites)
- [Installation Steps](#installation-steps)
  - [Step 1 — Provision the Quarantine Container](#step-1--provision-the-quarantine-container)
  - [Step 2 — Enable Microsoft Defender for Storage](#step-2--enable-microsoft-defender-for-storage)
  - [Step 3 — Configure the Event Grid System Topic](#step-3--configure-the-event-grid-system-topic)
  - [Step 4 — Provision the Service Bus Topic and Subscription](#step-4--provision-the-service-bus-topic-and-subscription)
  - [Step 5 — Assign Managed Identity RBAC Roles](#step-5--assign-managed-identity-rbac-roles)
  - [Step 6 — Build and Deploy the Verification Service](#step-6--build-and-deploy-the-verification-service)
  - [Step 7 — Verify the Deployment](#step-7--verify-the-deployment)
- [Troubleshooting](#troubleshooting)
- [Review Notes](#review-notes)

---

## Overview

This document describes the planned installation process for the DPN File Scanning Service (the ADR's "DPN File Verification Service"), which inserts a malware-scanning gate in front of the existing DPN Data Pipeline Consumer Extractor. It depends on the DPN Data Pipeline already being installed, since it writes into the same `dp-consumer-stage` container that component already reads from.

---

## Prerequisites

- The DPN Data Pipeline Consumer (Extractor + Schema Mapper) is already installed and reading from `dp-consumer-stage` — see the [DPN Data Pipeline Installation Process](../dpn-data-pipelines/installation.md).
- An AKS cluster with access to deploy new workloads
- Azure subscription access sufficient to enable Microsoft Defender for Storage, create an Event Grid System Topic, and provision a Service Bus namespace/topic.
- Permission to create and assign Managed Identities and RBAC role assignments.
- An OTEL-compatible log aggregator endpoint to send processing logs to.

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

### Step 6 — Build and Deploy the Verification Service

Once implementation begins, this step should follow the same Azure DevOps CI/CD pattern used by the other DPN components — a CI pipeline that builds and pushes the container image, and a CD pipeline that deploys it via Helm to AKS, configured with the values proposed in the [Configuration Guide](./config.md#service-configuration-parameters-proposed).

---

### Step 7 — Verify the Deployment

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

### Verification Service Cannot Read from `dp-consumer-raw`

Confirm the Verification Service's Managed Identity has the **Storage Blob Data Reader** role scoped to the `dp-consumer-raw` container, and that Managed Identity (not a connection string) is actually being used at runtime.

### Verified Files Not Appearing in `dp-consumer-stage`

Confirm the Verification Service's Managed Identity has the **Storage Blob Data Contributor** role scoped to `dp-consumer-stage`, and check the service's logs (via the OTEL aggregator) for write failures.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
