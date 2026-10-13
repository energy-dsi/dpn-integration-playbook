Release : 2.1.0 - Oct 2026

# DPN Uninstallation and Decommissioning Process

---

## Table of Contents

- [Overview](#overview)
- [Uninstallation Scope](#uninstallation-scope)
- [Uninstallation Approach](#uninstallation-approach)
- [Uninstallation Sequence](#uninstallation-sequence)
- [Pre-Uninstallation Checklist](#pre-uninstallation-checklist)
- [Part 1 — Uninstall DPN File Scanning Service](#part-1--uninstall-dpn-file-scanning-service)
  - [Step 1 — Remove the File Scanning Service](#step-1--remove-the-file-scanning-service)
  - [Step 2 — Verify File Scanning Service Removal](#step-2--verify-file-scanning-service-removal)
- [Part 2 — Uninstall DPN Data Pipeline](#part-2--uninstall-dpn-data-pipeline)
  - [Step 1 — Delete Data Products from the Self-Service UI](#step-1--delete-data-products-from-the-self-service-ui)
  - [Step 2 — Uninstall the Self-Service UI and Consumer Releases](#step-2--uninstall-the-self-service-ui-and-consumer-releases)
  - [Step 3 — Remove Releases Deployed by dpn-cd-data-pipelines.yml](#step-3--remove-releases-deployed-by-dpn-cd-data-pipelinesyml)
  - [Step 4 — Remove the Data Pipeline Namespace](#step-4--remove-the-data-pipeline-namespace)
  - [Step 5 — Verify Data Pipeline Removal](#step-5--verify-data-pipeline-removal)
- [Part 3 — Uninstall DPN Federator Certificate Manager](#part-3--uninstall-dpn-federator-certificate-manager)
  - [Step 1 — Remove the Certificate Manager](#step-1--remove-the-certificate-manager)
  - [Step 2 — Verify Certificate Manager Removal](#step-2--verify-certificate-manager-removal)
- [Part 4 — Uninstall DPN Federator Gateway](#part-4--uninstall-dpn-federator-gateway)
  - [Step 1 — Remove the Federator Gateway](#step-1--remove-the-federator-gateway)
  - [Step 2 — Verify Federator Gateway Removal](#step-2--verify-federator-gateway-removal)
- [Part 5 — Uninstall DPN Health Monitoring Service](#part-5--uninstall-dpn-health-monitoring-service)
  - [Step 1 — Remove Health Monitoring Sub-Components](#step-1--remove-health-monitoring-sub-components)
  - [Step 2 — Verify Health Monitoring Service Removal](#step-2--verify-health-monitoring-service-removal)
- [Part 6 — Post-Uninstallation Cleanup](#part-6--post-uninstallation-cleanup)
  - [Remove Container Images from ACR / GHCR](#remove-container-images-from-acr--ghcr)
  - [Remove Kafka Topics](#remove-kafka-topics)
  - [Remove Secrets and Certificates](#remove-secrets-and-certificates)
  - [Disable the Deployment Workflows](#disable-the-deployment-workflows)
- [Final Verification](#final-verification)
- [Review Notes](#review-notes)

---

## Overview

This document describes the procedure for **completely uninstalling the DPN platform** from an organisation's Azure environment.

The uninstallation process removes the following components:

- DPN File Scanning Service
- DPN Data Pipeline — the Self-Service UI, the consumer pipelines, the producer data products created from the UI, and any legacy pre-2.1.0 producer/consumer releases
- DPN Federator Certificate Manager and Vault service
- DPN Federator Gateway (Kafka, Zookeeper, Redis, Federator Server and Client)
- DPN Health Monitoring Service (Kafka-health, OpenTelemetry Collector, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, Nginx-observability)
- Kubernetes resources and Helm releases
- Container images in Azure Container Registry / GHCR

**None of the DPN components have a dedicated uninstall GitHub Actions workflow today** — uninstallation is performed with `helm uninstall` commands run directly against the target cluster (via `kubectl`/`helm` from a machine with the right OIDC/kubeconfig access, or as an ad-hoc job on the shared self-hosted runner), targeted at the specific Helm release each component owns. This approach ensures that only the components you intend to remove are affected. The Self-Service UI and its consumer releases can also be removed with the Azure DevOps uninstall pipeline in `dpn-data-pipelines` (see [Part 2, Step 2](#step-2--uninstall-the-self-service-ui-and-consumer-releases)); there is no GitHub Actions equivalent for Azure.

The goal of the procedure is to ensure that **all components of the DPN node are safely removed** without leaving orphaned infrastructure resources.

---

## Uninstallation Scope

All DPN services deployed as part of the DSI package are in scope for this uninstallation process. If an Organisation has chosen to bring their own (BYO) version of a component instead of the DSI-provided one, uninstallation of that component is the Organisation's own responsibility and is not covered here.

- DPN File Scan Service
- DPN Data Pipelines (Self-Service UI, consumer pipelines, data products, legacy releases)
- DPN Federator Certificate Manager
- DPN Federator Gateway
- DPN Health Monitoring Service

---

## Uninstallation Approach

There is no uninstall workflow for any component — only CD (deploy) workflows exist. For every part below, uninstallation is a direct `helm uninstall <release> -n <namespace>` command, scoped to the Helm release that component owns, leaving other components unaffected. [Part 5](#part-5--uninstall-dpn-health-monitoring-service) gives the same pattern applied per sub-component, following the removal order described below.

---

## Uninstallation Sequence

**Uninstallation must be performed in the following order**, to respect the same runtime dependencies used elsewhere in DPN's documentation (see the dependency chain in the Rollback and Recovery Process):

```
File Scanning Service -> Data Pipeline -> Federator Gateway -> Federator Certificate Manager -> Vault 
```

Because uninstallation removes components rather than reverting them, work **up the chain, from the most dependent component to the most foundational one** — the reverse of the order you would use to install them:

1. **File Scanning Service** — remove first. It depends on the Data Pipeline's `dp-consumer-stage` container already existing; removing it first avoids scan results being written into a container that may be mid-removal.
2. **Data Pipeline** — has no other DPN component depending on it for its own removal, and no longer has anything writing into it once File Scanning Service is gone. Data products must be deleted from the Self-Service UI **before** the UI itself is uninstalled.
3. **Federator Certificate Manager (and Vault, removed together)** — safe to remove once nothing downstream still expects it to issue or renew certificates.
4. **Federator Gateway** — remove **immediately after** step 3. Once the Certificate Manager and Vault are gone, the Gateway can no longer renew or synchronise certificates, so leaving it running afterward serves no purpose and it will begin to fail on its own.
5. **Health Monitoring Service** — remove last. It has no other DPN component depending on it to function, and keeping it in place while the components above are removed means its dashboards can still be used to confirm each preceding removal completed cleanly.

Parts 1–5 below are ordered to match this sequence — follow them top to bottom rather than picking an order of convenience.

---

## Pre-Uninstallation Checklist

Before starting the uninstallation process, confirm the following.

- All data exchanges with partner organisations have been stopped
- No active files are currently being processed
- All data products are stopped in the Self-Service UI, and no business users are creating or managing data products
- Kafka topics have been drained and contain no unprocessed messages, on **both** the main DPN Kafka (used by Federator Gateway / Data Pipeline) and the Health Monitoring Service's separate `otel-logs`/`otel-traces`/`otel-metrics` Kafka in `ns-dpn-health-01`
- Any scheduled or automated triggers for the CI/CD workflows have been disabled
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

### Step 1 — Remove the File Scanning Service

```bash
helm uninstall dpn-file-scan-service -n <namespace>
```

---

### Step 2 — Verify File Scanning Service Removal

After the command completes, confirm the File Scanning Service pod has been removed:

```bash
kubectl get pods -n <namespace>
```

No pods matching the pattern below should remain:

- `dpn-file-scan-service-*`

Confirm the Service Bus subscription, Storage Account containers, and Microsoft Defender for Storage malware scanning configuration created for the File Scanning Service are also removed or disabled — `helm uninstall` does not clean these up, since they were provisioned manually (see [Configure DPN File Scan Service, Step2](../02-configuration/06-configure-dpn-file-scan-service.md#step2-azure-resource-setup-storage-service-bus-defender) — not by this Helm release.

---

## Part 2 — Uninstall DPN Data Pipeline

This part removes the DPN Data Pipeline in its 2.1.0 single-container Self-Service design, plus anything left from earlier releases. It does not affect the Federator or Certificate Manager components.

| What | Where | Deployed by | Removed by |
|------|-------|-------------|------------|
| Producer data products (`dpn-producer-<pathway>-<product_type>` Deployment + HPA, plus their storage containers and Kafka topics) | `ns-dpn-dp-01` | Self-Service UI, at runtime (not Helm releases) | **Delete** in the Self-Service UI — [Step 1](#step-1--delete-data-products-from-the-self-service-ui) |
| Helm releases `dpn-self-service`, `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor` | `ns-dpn-dp-01` | Azure DevOps pipeline `dpn-self-service-cd.yaml` in `dpn-data-pipelines` (no Azure GitHub Actions equivalent exists) | `dpn-self-service-uninstall-cd.yaml` (ADO) or `helm uninstall` — [Step 2](#step-2--uninstall-the-self-service-ui-and-consumer-releases) |
| Consumer and legacy pre-2.1.0 producer releases (`dpn-consumer-*`, `dpn-producer-*`) | `ns-dpn-01` | `dpn-cd-data-pipelines.yml` (central repo) | `helm uninstall` — [Step 3](#step-3--remove-releases-deployed-by-dpn-cd-data-pipelinesyml) |

---

### Step 1 — Delete Data Products from the Self-Service UI

Producer data products are plain Kubernetes Deployments created by the Self-Service UI, not Helm releases. Uninstalling the `dpn-self-service` release does **not** remove them, and once the UI is gone there is nothing left that can clean up their storage containers and topics. Delete them first, while the UI is still running.

1. Sign in to the Self-Service UI with a user holding the `dpnadmin` role (only `dpnadmin` can delete).
2. For each data product, use **Delete**. As described in [Operate a Data Product](../02-configuration/07-configure-dpn-data-pipelines.md#step-07-operate-a-data-product), Delete removes the product's Deployment **and** its Kafka topic(s) and storage container(s). It is irreversible.
3. Confirm no producer Deployments remain:

   ```bash
   kubectl get deployments,hpa -n ns-dpn-dp-01
   ```

   Only `dpn-self-service`, `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` (and `oauth2-proxy`, if enabled) should be left.

> **Note:** Delete on a consumer pipeline in the UI removes its Deployment only. Remove the consumer pipelines with `helm uninstall` in Step 2 instead, so that their Helm release records are removed too.

---

### Step 2 — Uninstall the Self-Service UI and Consumer Releases

On Azure the Self-Service UI is deployed by the Azure DevOps pipeline `dpn-self-service-cd.yaml` (see [Overview of the installation guide](../03-installation/07-dpn-data-pipeline-installation-process.md#overview)), as three Helm releases in `ns-dpn-dp-01`:

- `dpn-self-service`
- `dpn-consumer-file-extractor`
- `dpn-consumer-topic-extractor`

There is no Azure GitHub Actions uninstall workflow for these releases. `dpn-data-pipelines` has GitHub Actions uninstall workflows for AWS and GCP only.

**Option A — Azure DevOps pipeline.** Run `dpn-self-service-uninstall-cd.yaml` (`.pipelines/azure-pipelines/cd-pipelines/` in `dpn-data-pipelines`) once per release, as described in the [azure-ado-beta uninstall guide](../../azure-ado-beta/05-uninstall/05-uninstall-decommissioning.md#part-2--uninstall-dpn-data-pipeline). It runs `helm uninstall <release_name> -n ns-dpn-dp-01 --wait --timeout 10m` after an environment approval.

**Option B — manual.** The equivalent commands are:

```bash
helm uninstall dpn-consumer-file-extractor -n ns-dpn-dp-01
helm uninstall dpn-consumer-topic-extractor -n ns-dpn-dp-01
helm uninstall dpn-self-service -n ns-dpn-dp-01
```

Uninstalling `dpn-self-service` also removes its registry PVC (`dpn-self-service-data`), its `dpn-self-service-external` load balancer and its `oauth2-proxy`. The UI also mirrors its data-product registry to a container in the platform storage account (default name `dpconfig`, overridable with `DPN_REGISTRY_BACKUP_CONTAINER`) and restores from it on start-up. That container is not removed by `helm uninstall`; delete it during [Post-Uninstallation Cleanup](#part-6--post-uninstallation-cleanup), otherwise a later reinstall will restore the old registry.

---

### Step 3 — Remove Releases Deployed by dpn-cd-data-pipelines.yml

The central `dpn-cd-data-pipelines.yml` workflow deploys one Helm release per chart into the main namespace (`ns-dpn-01`, the `NAMESPACE` value in `.pipelines/github-actions-pipelines/config/azure/<environment>-<cluster>.json`). It is used for the consumer pipelines on this path (see the installation guide) and was used for per-product producers before the 2.1.0 Self-Service design. Skip this step if it was never run.

The release names follow the workflow's naming:

- Consumer: `dpn-consumer-<processType>-<extractor|mapper>`
- Producer (pre-2.1.0): `dpn-producer-<processType>-<adaptor|mapper>-<schemaType>`

(a `schema_mapper` chart folder becomes `mapper` in the release name). List and remove them:

```bash
helm list -n ns-dpn-01 -q | grep -E '^dpn-(producer|consumer)-'
helm uninstall <release-name> -n ns-dpn-01
```

Repeat for every release listed.

---

### Step 4 — Remove the Data Pipeline Namespace

The namespace `ns-dpn-dp-01` was created by hand in the cluster bootstrap (see [AKS Namespace Configuration](../02-configuration/00-common-dpn-configuration.md#step23-aks-namespace-configuration)) and holds the secrets copied into it for the Data Pipeline:

| Secret | How it got there |
|--------|------------------|
| `dpn-tls`, `tls-auth-secret` | Copied automatically by `dpn-gha-tls-cd.yml`, if the namespace existed when it ran |
| `dpn-keycloak-secrets`, `producer-file-dp-secret`, `consumer-file-dp-secret` | Copied manually from `ns-dpn-01` |
| `dpn-health-ca` | Created manually (OTEL collector CA bundle) |
| `ghcr-pull-secret` | Created manually (GHCR pull secret), if used |

Once Steps 1–2 are complete, remove the namespace. This deletes every secret and any remaining object in it:

```bash
kubectl get all,secrets,pvc -n ns-dpn-dp-01
kubectl delete namespace ns-dpn-dp-01
```

> **Note:** If `dpn-gha-tls-cd.yml` is run again while the namespace still exists, it re-copies `dpn-tls` and `tls-auth-secret` into it. Delete the namespace after the last run of that workflow, or delete the two secrets again.

The secrets copied out of `ns-dpn-01` are only copies; the originals are removed in [Remove Secrets and Certificates](#remove-secrets-and-certificates).

---

### Step 5 — Verify Data Pipeline Removal

```bash
kubectl get namespace ns-dpn-dp-01          # NotFound
helm list -n ns-dpn-01 | grep -E 'dpn-(producer|consumer)-'   # no output
kubectl get deployments -n ns-dpn-01 | grep -E 'dpn-(producer|consumer)-'   # no output
```

No pods matching the patterns below should remain in any namespace:

- `dpn-self-service-*`
- `dpn-consumer-file-extractor-*`, `dpn-consumer-topic-extractor-*`, `dpn-consumer-*-mapper-*`
- `dpn-producer-<pathway>-<product_type>-*` (data products)
- `dpn-producer-*` (legacy releases in `ns-dpn-01`)

---

## Part 3 — Uninstall DPN Federator Certificate Manager

This part removes the Federator Certificate Manager and the HashiCorp Vault service deployed from the `dpn-federator-certificate-manager` repository. Removing the Certificate Manager will also remove the P12 keystore and truststore files from the shared storage at `/tls`.

> **Warning:** Once the Certificate Manager and Vault are removed, the Federator Gateway will no longer be able to renew or synchronise certificates. Per [Uninstallation Sequence](#uninstallation-sequence), proceed directly to [Part 4](#part-4--uninstall-dpn-federator-gateway) immediately after this step.

---

### Step 1 — Remove the Certificate Manager

The Certificate Manager and Vault are separate Helm releases (`dpn-gha-vault-cd.yml`/`dpn-gha-vault-https-cd.yml` and `dpn-gha-certificate-manager-cd.yml` deploy them independently) — remove both:

```bash
helm uninstall dpn-certificate-manager -n <namespace>
helm uninstall vault-https -n <namespace>
```

This removes the Certificate Manager deployment, the Vault deployment, and their associated Kubernetes services.

---

### Step 2 — Verify Certificate Manager Removal

After the commands complete, confirm that the Certificate Manager and Vault pods have been removed:

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

### Step 1 — Remove the Federator Gateway

```bash
helm uninstall dpn-platform -n <namespace>
```

This removes all Federator Gateway Helm-managed resources in the single release, including Kafka, Zookeeper, Redis, Federator Server, and Federator Client. If the REST Federator Gateway (`dpn-gha-rest-federator-cd.yml`) was also deployed, remove its two releases separately:

```bash
helm uninstall dpn-rest-federator -n <namespace>
helm uninstall dpn-rest-federator-redis -n <namespace>
```

---

### Step 2 — Verify Federator Gateway Removal

After the commands complete, confirm all Federator pods have been removed:

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

Remove each Helm release in the **reverse of the deployment dependency order** used to install them (`Init → Kafka → OpenSearch → Prometheus → Thanos → DataPrepper/Jaeger → Perses → OTel → DPN Portal`), so no component is left pointing at a dependency that's already gone:

```bash
helm uninstall dpn-portal -n ns-dpn-health-01
helm uninstall otel-collector -n ns-dpn-health-01
helm uninstall perses -n ns-dpn-health-01
helm uninstall jaeger -n ns-dpn-health-01
helm uninstall data-prepper -n ns-dpn-health-01
helm uninstall thanos -n ns-dpn-health-01
helm uninstall prometheus -n ns-dpn-health-01
helm uninstall opensearch -n ns-dpn-health-01
helm uninstall kafka-health -n ns-dpn-health-01
```

> **Note:** `dpn-portal` (a tile landing page linking out to the observability UIs) has replaced the retired `nginx-observability` reverse proxy as the first release removed here; it is fronted by its own `oauth2-proxy` gateway rather than being the reverse proxy itself. The Kafka UI's `oauth2-proxy` gateway has also been retired — Kafka UI now uses native Keycloak OIDC login and is exposed on its own internal load balancer, so removing `dpn-portal` no longer affects Kafka UI access. Complete the Kafka topic checks from the [Pre-Uninstallation Checklist](#pre-uninstallation-checklist) against that Kafka UI endpoint before proceeding regardless.

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

Remove container images from your own Azure Container Registry if they are no longer required (skip this if you deploy exclusively from DSI-provided GHCR images).

List all repositories:

```bash
az acr repository list --name <acr-name> --output table
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
- `dsi/dpn-self-service`
- `dsi/dpn-producer-file-adaptor-generic`, `dsi/dpn-producer-topic-adaptor-generic`
- `dsi/dpn-consumer-file-extractor`, `dsi/dpn-consumer-topic-extractor`
- images used by `dpn-cd-data-pipelines.yml` and legacy pre-2.1.0 images: `consumer-<processType>-<extractor|mapper>`, `producer-<processType>-<adaptor|mapper>-*`

If any component was deployed using DSI-provided GHCR images (`ghcr.io/energy-dsi/...`), no image deletion is required on the `energy-dsi` GHCR itself — those images are shared, DSI-managed packages. Only remove the `ghcr-pull-secret` Kubernetes secret used to authenticate against it, per [Remove Secrets and Certificates](#remove-secrets-and-certificates).

---

### Remove Kafka Topics

If the Kafka namespace and cluster have been fully removed by the `helm uninstall dpn-platform` command in [Part 4](#part-4--uninstall-dpn-federator-gateway), Kafka topics will have been deleted automatically. Topics of data products deleted from the Self-Service UI ([Part 2, Step 1](#step-1--delete-data-products-from-the-self-service-ui)) are already gone. If any topics persist, remove them via the Kafka UI before the namespace is deleted.

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

Delete the Data Pipeline storage left behind in the storage accounts: the Self-Service registry backup container (`dpconfig` by default, or the value of `DPN_REGISTRY_BACKUP_CONTAINER`), any data product containers that were not deleted from the UI, and containers used by legacy pre-2.1.0 pipelines. Rotate or revoke the storage account keys held in `producer-file-dp-secret` and `consumer-file-dp-secret` if the accounts are kept.

---

### Disable the Deployment Workflows

Unlike ADO pipelines, GitHub Actions workflows are just version-controlled files (`.pipelines/github-actions-pipelines/workflows/*.yml`) — there's no separate "registered pipeline" object to delete. Once uninstallation is confirmed complete:

- If this organisation's DPN was the only consumer of that repository's workflows, remove the federated identity credential / app registration used for GitHub OIDC (or its role assignment) in the target Azure subscription and revoke AKS cluster access (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#azure-entra-id-oidc-federated-credential)) so the workflows can no longer authenticate, rather than deleting the workflow files themselves (other environments may still use them).
- If you want to actively prevent accidental re-runs, disable the individual workflows from the GitHub UI (**Actions → select workflow → "..." → Disable workflow**) rather than deleting the files.

---

## Final Verification

After all parts are complete, confirm the following conditions are met before closing the decommissioning activity. Run these checks against the main DPN namespace, `ns-dpn-dp-01` (which should no longer exist after [Part 2, Step 4](#step-4--remove-the-data-pipeline-namespace)) and `ns-dpn-health-01`, if Health Monitoring Service was in scope.

| Verification | Command | Expected Result |
|-------------|---------|-----------------|
| No pods running | `kubectl get pods -n <namespace>` | No resources found |
| No services remaining | `kubectl get svc -n <namespace>` | No resources found |
| No deployments remaining | `kubectl get deployments -n <namespace>` | No resources found |
| No Helm releases | `helm list -n <namespace>` | No releases found |
| No persistent volume claims | `kubectl get pvc -n <namespace>` | No resources found |
| No secrets remaining | `kubectl get secrets -n <namespace>` | No resources found |
| ACR repositories cleared | `az acr repository list --name <acr-name> --output table` | No DPN repositories listed |

If all commands return no DPN resources, the DPN platform has been successfully decommissioned.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
