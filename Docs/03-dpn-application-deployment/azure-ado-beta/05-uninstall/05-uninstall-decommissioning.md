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
  - [Step 1 — Delete Data Products from the Self-Service UI](#step-1--delete-data-products-from-the-self-service-ui)
  - [Step 2 — Uninstall the Self-Service UI and Consumer Releases](#step-2--uninstall-the-self-service-ui-and-consumer-releases)
  - [Step 3 — Uninstall Legacy Releases and Airflow](#step-3--uninstall-legacy-releases-and-airflow)
  - [Step 4 — Remove the Data Pipeline Namespace](#step-4--remove-the-data-pipeline-namespace)
  - [Step 5 — Verify Data Pipeline Removal](#step-5--verify-data-pipeline-removal)
- [Part 3 — Uninstall DPN Federator Certificate Manager](#part-3--uninstall-dpn-federator-certificate-manager)
  - [Step 1 — Prepare Certificate Manager Uninstall CD Pipeline](#step-1--prepare-certificate-manager-uninstall-cd-pipeline)
  - [Step 2 — Execute Certificate Manager Uninstall CD Pipeline](#step-2--execute-certificate-manager-uninstall-cd-pipeline)
  - [Step 3 — Verify Certificate Manager Removal](#step-3--verify-certificate-manager-removal)
- [Part 4 — Uninstall DPN Federator Gateway](#part-4--uninstall-dpn-federator-gateway)
  - [Step 1 — Prepare Federator Gateway Uninstall CD Pipeline](#step-1--prepare-federator-gateway-uninstall-cd-pipeline)
  - [Step 2 — Execute Federator Gateway Uninstall CD Pipeline](#step-2--execute-federator-gateway-uninstall-cd-pipeline)
  - [Step 3 — Verify Federator Gateway Removal](#step-3--verify-federator-gateway-removal)
- [Part 4a — Uninstall DPN REST Federator Gateway](#part-4a--uninstall-dpn-rest-federator-gateway)
- [Part 5 — Uninstall DPN Health Monitoring Service](#part-5--uninstall-dpn-health-monitoring-service)
  - [Step 1 — Remove Health Monitoring Sub-Components](#step-1--remove-health-monitoring-sub-components)
  - [Step 2 — Verify Health Monitoring Service Removal](#step-2--verify-health-monitoring-service-removal)
- [Part 5a — Uninstall DPN Authentication Service](#part-5a--uninstall-dpn-authentication-service)
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
- DPN Data Pipeline — the Self-Service UI, the consumer pipelines, the producer data products created from the UI, any legacy pre-2.1.0 producer/consumer releases, and Airflow
- DPN Federator Certificate Manager and Vault service
- DPN Federator Gateway (Kafka, Zookeeper, Redis, Federator Server and Client)
- DPN REST Federator Gateway (optional — the REST/HTTPS alternative to the gRPC Federator Gateway, plus its own `dpn-redis` release)
- DPN Authentication Service (Keycloak and its own PostgreSQL instance)
- DPN Health Monitoring Service (Kafka-health, OpenTelemetry Collector, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, Nginx-observability)
- Kubernetes resources and Helm releases
- Container images in Azure Container Registry / GHCR
- Azure DevOps pipelines

The uninstallation is performed using **dedicated uninstall CD pipelines**, one per repository, where one exists. The `dpn-data-pipelines` repository has two: one for the Self-Service UI and consumer releases, and one for legacy releases and Airflow (see [Part 2](#part-2--uninstall-dpn-data-pipeline)). Each pipeline uses `helm uninstall` targeted at the specific components it owns. This approach ensures that only the components managed by each repository are removed in a controlled and auditable manner. Where no dedicated uninstall pipeline exists (currently, the Health Monitoring Service), the equivalent manual `helm uninstall` commands are given instead — see [Part 5](#part-5--uninstall-dpn-health-monitoring-service).

The goal of the procedure is to ensure that **all components of the DPN node are safely removed** without leaving orphaned infrastructure resources.

---

## Uninstallation Scope

All DPN services deployed as part of the DSI package are in scope for this uninstallation process. If an Organisation has chosen to bring their own (BYO) version of a component instead of the DSI-provided one, uninstallation of that component is the Organisation's own responsibility and is not covered here.

- DPN File Scan Service
- DPN Data Pipelines (Self-Service UI, consumer pipelines, data products, legacy releases)
- Airflow (`dpn-airflow`)
- DPN Federator Certificate Manager
- DPN Federator Gateway
- DPN REST Federator Gateway (optional)
- DPN Authentication Service
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
File Scanning Service -> Data Pipeline (incl. Airflow) -> Federator Gateway -> REST Federator Gateway -> Federator Certificate Manager -> Vault -> Health Monitoring Service -> Authentication Service
```

Because uninstallation removes components rather than reverting them, work **up the chain, from the most dependent component to the most foundational one** — the reverse of the order you would use to install them:

1. **File Scanning Service** — remove first. It depends on the Data Pipeline's `dp-consumer-stage` container already existing; removing it first avoids scan results being written into a container that may be mid-removal.
2. **Data Pipeline and Airflow** — has no other DPN component depending on it for its own removal, and no longer has anything writing into it once File Scanning Service is gone. Data products must be deleted from the Self-Service UI **before** the UI itself is uninstalled.
3. **Federator Certificate Manager (and Vault, removed together)** — safe to remove once nothing downstream still expects it to issue or renew certificates.
4. **Federator Gateway and REST Federator Gateway** — remove **immediately after** step 3, in either order relative to each other (they don't depend on one another). Once the Certificate Manager and Vault are gone, neither gateway can renew or synchronise certificates, so leaving either running afterward serves no purpose and it will begin to fail on its own.
5. **Health Monitoring Service** — remove next-to-last. It has no other DPN component depending on it to function, and keeping it in place while the components above are removed means its dashboards can still be used to confirm each preceding removal completed cleanly.
6. **DPN Authentication Service** — remove **last**, after Health Monitoring Service. Health Monitoring's `oauth2-proxy`-gated dashboards (OpenSearch, Jaeger, Perses, Portal) require Keycloak SSO to log in — removing Authentication Service any earlier would lock the organisation out of those dashboards before they've been used to confirm the preceding removals completed cleanly.

Parts 1–5 below are ordered to match this sequence (Part 4 covers both gateways) — follow them top to bottom rather than picking an order of convenience. Part 5a (Authentication Service) follows Part 5, matching step 6 above.

---

## Pre-Uninstallation Checklist

Before starting the uninstallation process, confirm the following.

- All data exchanges with partner organisations have been stopped
- No active files are currently being processed
- All data products are stopped in the Self-Service UI, and no business users are creating or managing data products
- Kafka topics have been drained and contain no unprocessed messages, on **both** the main DPN Kafka (used by Federator Gateway / Data Pipeline) and the Health Monitoring Service's separate `otel-logs`/`otel-traces`/`otel-metrics` Kafka in `ns-dpn-health-01`
- All CI/CD pipeline triggers have been disabled in Azure DevOps
- Required data backups have been taken, including a secure offline copy of the certificate bundle if Vault/Certificate Manager are in scope, and any Airflow metadata you need to keep (the Airflow PostgreSQL volume is deleted with its release)

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

This part removes the DPN Data Pipeline in its 2.1.0 single-container Self-Service design, plus Airflow and anything left from earlier releases, using the two uninstall pipelines in the `dpn-data-pipelines` repository. It does not affect the Federator or Certificate Manager components.

| What | Where | Removed by |
|------|-------|------------|
| Producer data products (`dpn-producer-<pathway>-<product_type>` Deployment + HPA, plus their storage containers and Kafka topics), created at runtime by the Self-Service UI — not Helm releases | `ns-dpn-dp-01` | **Delete** in the Self-Service UI — [Step 1](#step-1--delete-data-products-from-the-self-service-ui) |
| Helm releases `dpn-self-service`, `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor`, deployed by `dpn-self-service-cd.yaml` | `ns-dpn-dp-01` | `dpn-self-service-uninstall-cd.yaml` — [Step 2](#step-2--uninstall-the-self-service-ui-and-consumer-releases) |
| Legacy pre-2.1.0 producer/consumer releases, and the Airflow release `dpn-airflow` | `ns-dpn-01` (the `NAMESPACE` value in the pipeline config JSON) | `dsi-data-pipelines-uninstall-cd.yaml` — [Step 3](#step-3--uninstall-legacy-releases-and-airflow) |

---

### Step 1 — Delete Data Products from the Self-Service UI

Producer data products are plain Kubernetes Deployments created by the Self-Service UI, not Helm releases. Neither uninstall pipeline removes them, and once the UI is gone there is nothing left that can clean up their storage containers and topics. Delete them first, while the UI is still running.

1. Sign in to the Self-Service UI with a user holding the `dpnadmin` role (only `dpnadmin` can delete).
2. For each data product, use **Delete**. As described in [Operate a Data Product](../02-configuration/07-configure-dpn-data-pipelines.md#step-07-operate-a-data-product), Delete removes the product's Deployment **and** its Kafka topic(s) and storage container(s). It is irreversible.
3. Confirm no producer Deployments remain:

   ```bash
   kubectl get deployments,hpa -n ns-dpn-dp-01
   ```

   Only `dpn-self-service`, `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` (and `oauth2-proxy`) should be left.

> **Note:** Delete on a consumer pipeline in the UI removes its Deployment only. Remove the consumer pipelines with the uninstall pipeline in Step 2 instead, so that their Helm release records are removed too.

---

### Step 2 — Uninstall the Self-Service UI and Consumer Releases

Create a new Azure DevOps pipeline from the following YAML file in the `dpn-data-pipelines` repository (**Pipelines → New Pipeline → Existing Azure Pipelines YAML file**, then **Save** without running):

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-self-service-uninstall-cd.yaml
```

Run it once per release, with the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `ServiceConnection` | Azure service connection for the target environment |
| `environment` | Target environment (`dev`, `devtest`, `test`, `pdev`, `ptest`, `puat`) |
| `cluster` | `dpn01` or `dpn02` (leave `dpn01` for `pdev`/`ptest`/`puat`) |
| `release_name` | `dpn-self-service`, `dpn-consumer-file-extractor` or `dpn-consumer-topic-extractor` |

The namespace is fixed to `ns-dpn-dp-01`. The pipeline shows the current `helm status` in its **Preview** stage, waits for approval on the environment (`dsi-dev`, `dsi-devtest`, `dsi-test` or `dsi-ppd`) in its **Uninstall** stage, then runs the equivalent of:

```bash
helm uninstall <release_name> -n ns-dpn-dp-01 --wait --timeout 10m
```

Its **Verify** stage lists the Helm releases, Deployments and pods left in `ns-dpn-dp-01`. Uninstall the two consumer releases first and `dpn-self-service` last.

Uninstalling `dpn-self-service` also removes its registry PVC (`dpn-self-service-data`), its `dpn-self-service-external` load balancer and its `oauth2-proxy`. The UI also mirrors its data-product registry to a container in the platform storage account (default name `dpconfig`, overridable with `DPN_REGISTRY_BACKUP_CONTAINER`) and restores from it on start-up. That container is not removed by the pipeline; delete it during [Post-Uninstallation Cleanup](#remove-secrets-and-certificates), otherwise a later reinstall will restore the old registry.

---

### Step 3 — Uninstall Legacy Releases and Airflow

Create a new Azure DevOps pipeline from `dsi-data-pipelines-uninstall-cd.yaml` in the same folder of the `dpn-data-pipelines` repository:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dsi-data-pipelines-uninstall-cd.yaml
```

This pipeline works on the main namespace (the `NAMESPACE` value in `.pipelines/azure-pipelines/config/<environment>-<cluster>.json`, `ns-dpn-01`), not on `ns-dpn-dp-01`. Run it with the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `environment` | Target environment (`dev`, `devtest`, `test`, `pdev`, `ptest`, `puat`) |
| `cluster` | `dpn01` or `dpn02` (leave `dpn01` for `pdev`/`ptest`/`puat`) |
| `ServiceConnection` | Azure service connection for the target environment |
| `uninstallProducer` | Uninstall every release in the namespace whose name starts with `producer` (legacy pre-2.1.0 producers) |
| `uninstallConsumer` | Uninstall every release in the namespace whose name starts with `consumer` (legacy pre-2.1.0 consumers) |
| `uninstallAirflow` | Uninstall the Airflow release `dpn-airflow` |

Tick any combination; the pipeline fails if none is ticked. Its **Approval** stage lists the releases that will be deleted and waits for approval on the environment (`dsi-dev`, `dsi-devtest` or `dsi-ppd`). The **Uninstall** stage then runs the equivalent of:

```bash
helm list -n ns-dpn-01 -q | grep -E '^producer'   # each one: helm uninstall <release> -n ns-dpn-01
helm list -n ns-dpn-01 -q | grep -E '^consumer'   # each one: helm uninstall <release> -n ns-dpn-01
helm uninstall dpn-airflow -n ns-dpn-01
```

> **Notes:**
> - Data products and releases created by the 2.1.0 Self-Service design are in `ns-dpn-dp-01` and are not touched by this pipeline. Pre-2.1.0 data products are not imported into the Self-Service UI; if any are still running, remove them here.
> - Airflow was deployed as `dpn-airflow` in `ns-dpn-01` by the `dpn-data-pipeline-airflow-*-cd.yaml` pipelines of earlier releases (for example `release-internal/2.0.0`); there is no Airflow deployment pipeline on the `develop` branch of `dpn-data-pipelines`. This pipeline only removes the `dpn-airflow` release if it is present (it reports `dpn-airflow not installed` otherwise).
> - Uninstalling `dpn-airflow` deletes its PostgreSQL metadata volume with the release. If a `dpn-airflow-secrets` secret or a `dpn-airflow-*` PVC is still listed afterwards, delete it by hand.

---

### Step 4 — Remove the Data Pipeline Namespace

The namespace `ns-dpn-dp-01` was created by hand in the cluster bootstrap (see [AKS Namespace Configuration](../02-configuration/00-common-dpn-configuration.md#step23-aks-namespace-configuration)) and holds the secrets copied into it for the Data Pipeline: `dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, `producer-file-dp-secret` and `consumer-file-dp-secret` (copied from `ns-dpn-01`), and `dpn-health-ca`. No pipeline removes the namespace.

Once Steps 1–3 are complete, remove it. This deletes every secret and any remaining object in it:

```bash
kubectl get all,secrets,pvc -n ns-dpn-dp-01
kubectl delete namespace ns-dpn-dp-01
```

The secrets copied out of `ns-dpn-01` are only copies; the originals are removed in [Remove Secrets and Certificates](#remove-secrets-and-certificates).

---

### Step 5 — Verify Data Pipeline Removal

```bash
kubectl get namespace ns-dpn-dp-01          # NotFound
helm list -n ns-dpn-01 | grep -E '^(producer|consumer)|dpn-airflow'   # no output
kubectl get deployments -n ns-dpn-01
```

No pods matching the patterns below should remain in any namespace:

- `dpn-self-service-*`
- `dpn-consumer-file-extractor-*`, `dpn-consumer-topic-extractor-*`
- `dpn-producer-<pathway>-<product_type>-*` (data products)
- `producer-*`, `consumer-*` (legacy releases in `ns-dpn-01`)
- `dpn-airflow-*`

---

## Part 3 — Uninstall DPN Federator Certificate Manager

This part removes the Federator Certificate Manager and the HashiCorp Vault service deployed from the `dpn-federator-certificate-manager` repository. The Certificate Manager's own keystore/truststore are built in memory only — there is no shared file share or `/tls` mount to clean up for this component. Vault's **own** persistent volume (its secret storage, separate from the removed certificate file share) is removed along with the Vault Helm release itself.

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

This removes the Certificate Manager deployment, the Vault deployment (including Vault's own persistent volume), and associated Kubernetes services. If the pipeline completes successfully, the following message will appear:

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

## Part 4a — Uninstall DPN REST Federator Gateway

This part removes the optional REST Federator Gateway, deployed from the `dpn-rest-federator-gateway` repository as two separate Helm releases (`dpn-redis`, `dpn-rest-federator`). No dedicated uninstall CD pipeline was found for this repository — the following commands are the manual equivalent, matching the pattern used for [Health Monitoring Service](#part-5--uninstall-dpn-health-monitoring-service) where no dedicated pipeline exists. Skip this part entirely if this optional component was never deployed.

```bash
helm uninstall dpn-rest-federator -n <namespace>
helm uninstall dpn-redis -n <namespace>
```

**Verify removal:**

```bash
kubectl get pods -n <namespace>
kubectl get svc -n <namespace>
```

No pods with names matching the patterns below should remain:

- `dpn-rest-federator-server-1-*`
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

## Part 5a — Uninstall DPN Authentication Service

This part removes the Keycloak-based DPN Authentication Service and its own PostgreSQL instance, deployed from the `dpn-authentication-service` repository as a single Helm release in `ns-dpn-01`. It is removed **last**, per [Uninstallation Sequence](#uninstallation-sequence), since Health Monitoring Service's `oauth2-proxy`-gated dashboards depend on it for SSO login while confirming the preceding removals.

A dedicated uninstall pipeline exists for this repository, `dpn-keycloak-uninstall-cd.yaml`:

```
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-keycloak-uninstall-cd.yaml
```

Trigger the pipeline manually and provide the following runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `ServiceConnection` | Azure service connection for the target environment |
| `environment` | Target environment |
| `dpnCluster` | Target DPN cluster (`dpn02` is disabled for `pdev`/`ptest`/`puat`, which only have one DPN) |
| `deletePvc` | **Destructive** — also deletes the PostgreSQL PVC, permanently losing every realm, user, and client. Leave `false` if any other environment or a future reinstall needs the existing realm data preserved |

The pipeline internally executes the equivalent of:

```bash
helm uninstall dpn-keycloak -n ns-dpn-01
```

If `deletePvc: true` was passed, the PostgreSQL PVC is also removed after the Helm uninstall completes.

**Verify removal:**

```bash
kubectl get pods -n ns-dpn-01   # no dpn-keycloak-* or dpn-keycloak-postgres-* pods should remain
kubectl get pvc -n ns-dpn-01    # confirm the PostgreSQL PVC is gone, if deletePvc was true
```

> **Downstream impact:** once removed, Federator Gateway's Kafka OAuth/Kafka UI, Data Pipeline's Airflow SSO, and Health Monitoring Service's `oauth2-proxy` gateways can no longer authenticate — this is expected, since those components should already be removed by this point in the sequence. If any of them are still running for another reason, confirm that is intentional before removing Authentication Service.

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
- `dpn-rest-federator-server` (if the optional REST Federator Gateway was deployed)
- `dpn-file-scan-service`
- `dsi/dpn-self-service`
- `dsi/dpn-producer-file-adaptor-generic`, `dsi/dpn-producer-topic-adaptor-generic`
- `dsi/dpn-consumer-file-extractor`, `dsi/dpn-consumer-topic-extractor`
- the Airflow image, if Airflow was deployed from ACR
- legacy pre-2.1.0 images: `producer-<processType>-<adaptor|mapper>-*`, `consumer-<processType>-<extractor|mapper>`

If any component was deployed using DSI-provided GHCR images (`ghcr.io/energy-dsi/...`), no image deletion is required on the `energy-dsi` GHCR itself — those images are shared, DSI-managed packages. Only remove the `ghcr-pull-secret` Kubernetes secret used to authenticate against it, per [Remove Secrets and Certificates](#remove-secrets-and-certificates).

---

### Remove Kafka Topics

If the Kafka namespace and cluster have been fully removed by the Federator uninstall pipeline, Kafka topics will have been deleted automatically. Topics of data products deleted from the Self-Service UI ([Part 2, Step 1](#step-1--delete-data-products-from-the-self-service-ui)) are already gone. If any topics persist, remove them via the Kafka UI before the namespace is deleted.

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

There is no certificate file share or PVC to clean up for the Certificate Manager, Federator Gateway, or REST Federator Gateway — their keystore/truststore material is built in memory only. If Vault itself was decommissioned, its own persistent volume claim (Vault's secret storage) is removed with the rest of its Helm release:

```bash
kubectl delete pvc --all -n <namespace>
```

If a component is being decommissioned while Vault is **retained** for other components, revoke that component's AppRole identity so its `role_id`/`secret_id` can no longer authenticate, rather than leaving an orphaned credential:

```bash
kubectl exec -n <namespace> <vault-pod> -- vault delete auth/approle/role/<component>
```

Then remove that component's `VAULT-APPROLE-SECRET-ID` (and `VAULT-TOKEN`, if it was still using the root token) from Azure Key Vault, along with any other certificates and secrets no longer required, following the organisation's secrets management policy. This includes the Airflow secrets (`fernetKey`, `webSecretKey`, `airPostgresPassword`, `AIRFLOW-ADMIN-PASSWORD`), if Airflow was deployed.

Delete the Data Pipeline storage left behind in the storage accounts: the Self-Service registry backup container (`dpconfig` by default, or the value of `DPN_REGISTRY_BACKUP_CONTAINER`), any data product containers that were not deleted from the UI, and containers used by legacy pre-2.1.0 pipelines. Rotate or revoke the storage account keys held in `producer-file-dp-secret` and `consumer-file-dp-secret` if the accounts are kept.

---

### Remove Azure DevOps Pipelines

Delete all Azure DevOps pipelines associated with the DPN node once uninstallation is confirmed complete. These include:

- Federator CI and CD pipelines
- Federator uninstall CD pipeline
- REST Federator Gateway CI and CD pipelines (`rest-federator-ci.yaml`, `rest-federator-cd.yml`), if the optional component was deployed — no dedicated uninstall pipeline exists for it (see [Part 4a](#part-4a--uninstall-dpn-rest-federator-gateway))
- Authentication Service CD and uninstall CD pipelines (`dpn-keycloak-cd.yaml`, `dpn-keycloak-uninstall-cd.yaml`) — see [Part 5a](#part-5a--uninstall-dpn-authentication-service)
- Certificate Manager CI, CD, and uninstall CD pipelines
- Data Pipeline CI, CD and uninstall pipelines (`dpn-self-service-ci.yaml`, `dpn-self-service-cd.yaml`, `dpn-self-service-uninstall-cd.yaml`, `dsi-data-pipelines-uninstall-cd.yaml`), and any Airflow or legacy data pipeline CD pipelines still registered
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

After all parts are complete, confirm the following conditions are met before closing the decommissioning activity. Run these checks against the main DPN namespace, `ns-dpn-dp-01` (which should no longer exist after [Part 2, Step 4](#step-4--remove-the-data-pipeline-namespace)) and `ns-dpn-health-01`, if Health Monitoring Service was in scope.

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
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 | 
