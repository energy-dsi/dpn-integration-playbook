# DPN Federator Gateway Installation Process

This document covers the installation of the **DPN Federator Gateway** (Server, Client, and supporting Kafka/Zookeeper/Redis/Kafka UI services) into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS).

> **Full instructions live in the configuration guide.** The end-to-end Federator Gateway flow — overview, prerequisites, Key Vault and Kubernetes secrets, the values to populate, deployment, and verification — is documented in one place:
>
> 👉 **[Configure DPN Federator Gateway](../02-configuration/03-configure-dpn-federator-gateway.md)**
>
> This installation page is a quick-reference summary that points to that guide.

> **Depends on Vault and the Certificate Manager.** Complete [Vault installation](01-dpn-vault-installation-process.md) and [Certificate Manager installation](02-dpn-certificate-manager-installtion-process.md) first — the gateway reads the P12 passwords from Vault and the P12 files from the Certificate Manager's shared file share.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Sequence](#installation-sequence)
- [Verification](#verification)
- [Review Notes](#review-notes)

---

## Overview

The Federator Gateway is deployed as a **single Helm release (`dpn-platform`)** via one Azure DevOps CD pipeline run. The release includes the Federator Server and Client plus Zookeeper (source/target), Kafka (source/target), Kafka UI, and Redis.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── azure-dpn-cd.yaml
```

Key points, detailed in the configuration guide:
- The P12 **passwords are read from Vault**; only the storage connection strings are Key Vault secrets.
- The **Server and Client use separate storage accounts** — the **Client uses the File Scan Service source storage account**.
- The deployment targets a **single DPN cluster** (`dpn01` or `dpn02`).

---

## Prerequisites

Confirm the prerequisites before starting — see [Configure DPN Federator Gateway → Prerequisites](../02-configuration/03-configure-dpn-federator-gateway.md#prerequisites). In summary: Vault and Certificate Manager deployed, the shared file share PVC and `cert-manager-truststore` / `certificate-manager-secrets` secrets present, the two storage connection strings in Key Vault, the Server and File Scan source storage accounts provisioned, reserved internal LB IPs, OAuth2/Management Node details from DSM, an image tag, and a populated `config/<env>.json` and `values-<env>-<cluster>.yaml`.

---

## Installation Sequence

Run the CD pipeline once with your environment and single cluster. Full parameter details are in [Configure DPN Federator Gateway → Deployment](../02-configuration/03-configure-dpn-federator-gateway.md#deployment).

| Pipeline | What it does |
|----------|--------------|
| `azure-dpn-cd` | Deploys all Federator Gateway components in the single `dpn-platform` Helm release. Parameters: `ServiceConnection`, `environment`, `dpncluster` (single: `dpn01` or `dpn02`), `imageTag` |

On success the deployment stage ends with `DPN DEPLOYMENT COMPLETE`.

---

## Verification

After deployment, confirm all components are running and validate end-to-end connectivity using the checks in [Configure DPN Federator Gateway → Post-Deployment and Verification](../02-configuration/03-configure-dpn-federator-gateway.md#post-deployment-and-verification). Quick check:

```bash
kubectl get pods -n <namespace>
kubectl get svc  -n <namespace>   # confirm Server + Client internal LB IPs
```

Then use the Kafka UI (reachable from inside the Azure network via the Windows VM / bastion) to confirm both Kafka clusters and publish a test message end-to-end:

```text
http://dpn-kafka-ui:8080
```

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 15-May-2026 | DSI Assurance    | Draft  | V0.1.0 |
