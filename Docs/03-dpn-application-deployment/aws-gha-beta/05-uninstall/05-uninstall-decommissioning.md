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
  - [Step 3 — Remove Legacy Pre-2.1.0 Data Pipeline Releases](#step-3--remove-legacy-pre-210-data-pipeline-releases)
  - [Step 4 — Uninstall Airflow](#step-4--uninstall-airflow)
  - [Step 5 — Remove the Data Pipeline Namespace](#step-5--remove-the-data-pipeline-namespace)
  - [Step 6 — Verify Data Pipeline Removal](#step-6--verify-data-pipeline-removal)
- [Part 3 — Uninstall DPN Federator Certificate Manager](#part-3--uninstall-dpn-federator-certificate-manager)
  - [Step 1 — Remove the Certificate Manager](#step-1--remove-the-certificate-manager)
  - [Step 2 — Verify Certificate Manager Removal](#step-2--verify-certificate-manager-removal)
- [Part 4 — Uninstall DPN Federator Gateway](#part-4--uninstall-dpn-federator-gateway)
  - [Step 1 — Remove the Federator Gateway](#step-1--remove-the-federator-gateway)
  - [Step 2 — Verify Federator Gateway Removal](#step-2--verify-federator-gateway-removal)
- [Part 5 — Uninstall DPN Health Monitoring Service](#part-5--uninstall-dpn-health-monitoring-service)
  - [Step 1 — Remove Health Monitoring Sub-Components](#step-1--remove-health-monitoring-sub-components)
  - [Step 2 — Verify Health Monitoring Service Removal](#step-2--verify-health-monitoring-service-removal)
- [Part 5a — Uninstall DPN Authentication Service](#part-5a--uninstall-dpn-authentication-service)
- [Part 6 — Post-Uninstallation Cleanup](#part-6--post-uninstallation-cleanup)
  - [Remove Container Images from ECR / GHCR](#remove-container-images-from-ecr--ghcr)
  - [Remove Kafka Topics](#remove-kafka-topics)
  - [Remove Secrets and Certificates](#remove-secrets-and-certificates)
  - [Remove AWS Resources Created by the Workflows](#remove-aws-resources-created-by-the-workflows)
  - [Disable the Deployment Workflows](#disable-the-deployment-workflows)
- [Final Verification](#final-verification)
- [Review Notes](#review-notes)

---

## Overview

This document describes the procedure for **completely uninstalling the DPN platform** from an organisation's AWS environment.

The uninstallation process removes the following components:

- DPN File Scanning Service
- DPN Data Pipeline — the Self-Service UI, the two consumer pipelines, the producer data products created from the UI, any legacy pre-2.1.0 producer/consumer releases, and Airflow
- DPN Federator Certificate Manager and Vault service
- DPN Federator Gateway (Kafka, Zookeeper, Redis, Federator Server and Client), and the optional REST Federator Gateway
- DPN Health Monitoring Service (Kafka, OpenTelemetry Collector, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, DPN Portal and the `oauth2-proxy` gateways)
- DPN Authentication Service (Keycloak and its PostgreSQL instance)
- Kubernetes resources, Helm releases and namespaces
- AWS resources created by the deployment workflows (IRSA roles, Secrets Manager entries, S3 buckets)
- Container images in Amazon ECR / GHCR

The central deployment repository (`dpn-containerised-deployment-service`) has **no uninstall workflow** for any component — only CD (deploy) workflows. Uninstallation is performed with `helm uninstall` commands run directly against the target cluster (from a machine with the right OIDC/kubeconfig access, or as an ad-hoc job on the shared self-hosted runner), targeted at the specific Helm release each component owns. The one exception is the Self-Service UI and consumer releases, which have their own uninstall workflow in `dpn-data-pipelines` (see [Part 2, Step 2](#step-2--uninstall-the-self-service-ui-and-consumer-releases)).

Unless stated otherwise, the main DPN namespace is the `NAMESPACE` value in `.github/config/aws/<environment>-<cluster>.json` (`ns-dpn-01` in every shipped config). Health Monitoring Service runs in `ns-dpn-health-01` and the 2.1.0 Data Pipeline in `ns-dpn-dp-01`.

The goal of the procedure is to ensure that **all components of the DPN node are safely removed** without leaving orphaned infrastructure resources.

---

## Uninstallation Scope

All DPN services deployed as part of the DSI package are in scope for this uninstallation process. If an Organisation has chosen to bring their own (BYO) version of a component instead of the DSI-provided one, uninstallation of that component is the Organisation's own responsibility and is not covered here.

- DPN File Scan Service
- DPN Data Pipelines (Self-Service UI, consumer pipelines, data products, legacy releases)
- Airflow (`dpn-airflow`)
- DPN Federator Certificate Manager and Vault
- DPN Federator Gateway (and the optional REST Federator Gateway)
- DPN Health Monitoring Service
- DPN Authentication Service

---

## Uninstallation Approach

Apart from the Self-Service uninstall workflow mentioned above, every part below is a direct `helm uninstall <release> -n <namespace>` command, scoped to the Helm release that component owns, leaving other components unaffected. Release names are the ones each CD workflow passes to `helm upgrade --install`. [Part 5](#part-5--uninstall-dpn-health-monitoring-service) gives the same pattern applied per sub-component, following the removal order described below.

`helm uninstall` removes only the Kubernetes objects in the release. AWS resources created by the workflows themselves (IRSA roles, Secrets Manager entries, S3 buckets) are not removed — see [Remove AWS Resources Created by the Workflows](#remove-aws-resources-created-by-the-workflows).

---

## Uninstallation Sequence

**Uninstallation must be performed in the following order**, to respect the same runtime dependencies used elsewhere in DPN's documentation (see the dependency chain in the Rollback and Recovery Process):

```
File Scanning Service -> Data Pipeline (incl. Airflow) -> Federator Certificate Manager + Vault -> Federator Gateway -> Health Monitoring Service -> Authentication Service
```

Because uninstallation removes components rather than reverting them, work **up the chain, from the most dependent component to the most foundational one** — the reverse of the order you would use to install them:

1. **File Scanning Service** — remove first. It depends on the Data Pipeline's `dp-consumer-stage` bucket already existing; removing it first avoids scan results being written into a bucket that may be mid-removal.
2. **Data Pipeline and Airflow** — has no other DPN component depending on it for its own removal, and no longer has anything writing into it once File Scanning Service is gone. Data products must be deleted from the Self-Service UI **before** the UI itself is uninstalled.
3. **Federator Certificate Manager (and Vault, removed together)** — safe to remove once nothing downstream still expects it to issue or renew certificates.
4. **Federator Gateway** — remove **immediately after** step 3. Once the Certificate Manager and Vault are gone, the Gateway can no longer renew or synchronise certificates, so leaving it running afterward serves no purpose and it will begin to fail on its own.
5. **Health Monitoring Service** — remove next-to-last. It has no other DPN component depending on it to function, and keeping it in place while the components above are removed means its dashboards can still be used to confirm each preceding removal completed cleanly.
6. **Authentication Service** — remove last. Health Monitoring Service's `oauth2-proxy` gateways and the Self-Service UI login depend on Keycloak; removing it earlier locks you out of those UIs while you still need them.

Parts 1–5a below are ordered to match this sequence — follow them top to bottom rather than picking an order of convenience.

---

## Pre-Uninstallation Checklist

Before starting the uninstallation process, confirm the following.

- All data exchanges with partner organisations have been stopped
- No active files are currently being processed
- All data products are stopped in the Self-Service UI, and no business users are creating or managing data products
- Kafka topics have been drained and contain no unprocessed messages, on **both** the main DPN Kafka (used by Federator Gateway / Data Pipeline) and the Health Monitoring Service's separate `otel-logs`/`otel-traces`/`otel-metrics` Kafka in `ns-dpn-health-01`
- Any scheduled or automated triggers for the CI/CD workflows have been disabled
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

This part removes the DPN File Scanning Service deployed by the `dpn-file-scan-cd.yml` workflow. It is removed first, per [Uninstallation Sequence](#uninstallation-sequence), since it depends on the Data Pipeline's `dp-consumer-stage` bucket.

---

### Step 1 — Remove the File Scanning Service

```bash
helm uninstall dpn-file-scan-service -n ns-dpn-01
```

---

### Step 2 — Verify File Scanning Service Removal

After the command completes, confirm the File Scanning Service pod has been removed:

```bash
kubectl get pods -n ns-dpn-01
```

No pods matching the pattern below should remain:

- `dpn-file-scan-service-*`

Confirm the SNS topic, SQS queue, and GuardDuty Malware Protection plan used by the File Scanning Service are also removed or disabled — `helm uninstall` does not clean these up. They were provisioned manually (see [Configure DPN File Scan Service, Step2](../02-configuration/08-configure-dpn-file-scan-service.md#step2-aws-resource-setup-snssqsguardduty)); `dpn-file-scan-prerequisites-cd.yml` only verifies them. That workflow does create the IRSA role `dpn-file-scan-service-secrets-role` and the Secrets Manager entries under `dpn/<environment>-<cluster>/file-scan-service/`, which are removed in [Remove AWS Resources Created by the Workflows](#remove-aws-resources-created-by-the-workflows).

---

## Part 2 — Uninstall DPN Data Pipeline

This part removes the DPN Data Pipeline in its 2.1.0 single-container Self-Service design, plus Airflow and anything left from earlier releases. It does not affect the Federator or Certificate Manager components.

| What | Where | Deployed by | Removed by |
|------|-------|-------------|------------|
| Producer data products (`dpn-producer-<pathway>-<product_type>` Deployment + HPA, plus their S3 buckets and Kafka topics) | `ns-dpn-dp-01` | Self-Service UI, at runtime (not Helm releases) | **Delete** in the Self-Service UI — [Step 1](#step-1--delete-data-products-from-the-self-service-ui) |
| Helm releases `dpn-self-service`, `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor` | `ns-dpn-dp-01` | `dpn-self-service-cd.yaml` in `dpn-data-pipelines` | `dpn-self-service-uninstall-cd.yaml` or `helm uninstall` — [Step 2](#step-2--uninstall-the-self-service-ui-and-consumer-releases) |
| Legacy pre-2.1.0 producer/consumer releases (`dpn-producer-*`, `dpn-consumer-*`) | `ns-dpn-01` | `dpn-cd-data-pipelines.yml` (central repo) | `helm uninstall` — [Step 3](#step-3--remove-legacy-pre-210-data-pipeline-releases) |
| Helm release `dpn-airflow` | `ns-dpn-01` | `dpn-cd-airflow.yml` (central repo) | `helm uninstall` — [Step 4](#step-4--uninstall-airflow) |

---

### Step 1 — Delete Data Products from the Self-Service UI

Producer data products are plain Kubernetes Deployments created by the Self-Service UI, not Helm releases. Uninstalling the `dpn-self-service` release does **not** remove them, and once the UI is gone there is nothing left that can clean up their buckets and topics. Delete them first, while the UI is still running.

1. Sign in to the Self-Service UI with a user holding the `dpnadmin` role (only `dpnadmin` can delete).
2. For each data product, use **Delete**. As described in [Operate a Data Product](../02-configuration/07-configure-dpn-data-pipelines.md#step-07-operate-a-data-product), Delete removes the product's Deployment **and** its Kafka topic(s) and S3 bucket(s). It is irreversible.
3. Confirm no producer Deployments remain:

   ```bash
   kubectl get deployments,hpa -n ns-dpn-dp-01
   ```

   Only `dpn-self-service`, `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` (and `oauth2-proxy`, if enabled) should be left.

> **Note:** Delete on a consumer pipeline in the UI removes its Deployment only. Remove the consumer pipelines with `helm uninstall` in Step 2 instead, so that their Helm release records are removed too.

---

### Step 2 — Uninstall the Self-Service UI and Consumer Releases

The Self-Service UI and the two consumer pipelines are three separate Helm releases in `ns-dpn-dp-01`, deployed by `dpn-self-service-cd.yaml` (see [Execute Data Pipeline CD Workflow](../03-installation/07-dpn-data-pipeline-installation-process.md#step-02c-execute-data-pipeline-cd-workflow)):

- `dpn-self-service`
- `dpn-consumer-file-extractor`
- `dpn-consumer-topic-extractor`

**Option A — uninstall workflow.** `dpn-data-pipelines` provides **DPN Self-Service — Uninstall (AWS EKS)** (`.pipelines/github-actions-pipelines/aws-pipelines/cd-pipelines/dpn-self-service-uninstall-cd.yaml`). Like the AWS CD workflow, it is not on the `develop` branch; restore it from the repository's git history (the commit before `Temporarily remove AWS GitHub Actions pipelines`). Run it once per release, with:

| Input | Value |
|-------|-------|
| `environment` | `dev` / `devtest` |
| `cluster` | `dpn01` / `dpn02` |
| `roleToAssume` | ARN of the IAM role assumed through GitHub OIDC |
| `release_name` | `dpn-self-service`, `dpn-consumer-file-extractor` or `dpn-consumer-topic-extractor` |

The workflow previews `helm status`, waits for approval on the GitHub Environment `dpn-self-service-<environment>`, then runs `helm uninstall <release_name> -n ns-dpn-dp-01 --wait --timeout 10m` and lists what remains in the namespace.

**Option B — manual.** The equivalent commands are:

```bash
helm uninstall dpn-consumer-file-extractor -n ns-dpn-dp-01
helm uninstall dpn-consumer-topic-extractor -n ns-dpn-dp-01
helm uninstall dpn-self-service -n ns-dpn-dp-01
```

Uninstalling `dpn-self-service` also removes its registry PVC (`dpn-self-service-data`), its `dpn-self-service-external` load balancer and, if enabled, its `oauth2-proxy`. The UI also mirrors its data-product registry to an S3 bucket (default name `dpconfig`, overridable with `DPN_REGISTRY_BACKUP_CONTAINER`) and restores from it on start-up. That bucket is not removed by `helm uninstall`; delete it in [Remove AWS Resources Created by the Workflows](#remove-aws-resources-created-by-the-workflows), otherwise a later reinstall will restore the old registry.

---

### Step 3 — Remove Legacy Pre-2.1.0 Data Pipeline Releases

Data products from before the 2.1.0 Self-Service design were deployed one Helm release per chart by the central `dpn-cd-data-pipelines.yml` workflow (and `dpn-cd-data-pipelines-aws-poc.yml`), into the main namespace. They are not managed by the Self-Service UI. Skip this step if they were never deployed.

The release names follow the workflow's naming:

- Producer: `dpn-producer-<processType>-<adaptor|mapper>-<schemaType>`
- Consumer: `dpn-consumer-<processType>-<extractor|mapper>`

(a `schema_mapper` chart folder becomes `mapper` in the release name). List and remove them:

```bash
helm list -n ns-dpn-01 -q | grep -E '^dpn-(producer|consumer)-'
helm uninstall <release-name> -n ns-dpn-01
```

Repeat for every release listed. For the `file` pathway this workflow also created AWS resources that `helm uninstall` leaves behind: one IRSA role per chart, named `<serviceAccount-name>-s3-role` (for example `dpn-consumer-file-extractor-s3-role`), and S3 buckets named `<containerName>-<environment>-<NN>-<account-id>-<region>`. Remove them in [Remove AWS Resources Created by the Workflows](#remove-aws-resources-created-by-the-workflows).

---

### Step 4 — Uninstall Airflow

Airflow is deployed by the central `dpn-cd-airflow.yml` workflow (**DPN CD - Airflow**) as the Helm release `dpn-airflow`, from the chart `dpn-data-pipelines/charts/airflow`, into the main namespace (`ns-dpn-01`). There is no Airflow uninstall workflow.

```bash
helm uninstall dpn-airflow -n ns-dpn-01
```

This removes the Airflow webserver, scheduler, worker and triggerer, its Redis and PostgreSQL, the `dpn-airflow-init` Job, the `dpn-airflow-webserver` and `dpn-airflow-webserver-external` (load balancer) services, the `dpn-airflow` ServiceAccount, the `dpn-airflow-kv-secrets` SecretProviderClass and the PostgreSQL PVC `dpn-airflow-postgres-pvc`. All Airflow metadata in that PostgreSQL volume is lost.

Confirm nothing is left behind:

```bash
kubectl get pods,svc,jobs,pvc -n ns-dpn-01 | grep dpn-airflow
kubectl get secret dpn-airflow-secrets -n ns-dpn-01
```

`dpn-airflow-secrets` is synced from Secrets Manager by the CSI driver and is normally removed once no pod mounts it. If it is still present, delete it:

```bash
kubectl delete secret dpn-airflow-secrets -n ns-dpn-01 --ignore-not-found
```

On AWS the workflow also created the IRSA role `dpn-airflow-secrets-role` (inline policy `dpn-airflow-permissions`) and four Secrets Manager entries under `dpn/<environment>-<cluster>/airflow/` (`FERNET_KEY`, `WEB_SECRET_KEY`, `AIR_POSTGRES_PASSWORD`, `AIRFLOW_ADMIN_PASSWORD`). Remove them in [Remove AWS Resources Created by the Workflows](#remove-aws-resources-created-by-the-workflows).

---

### Step 5 — Remove the Data Pipeline Namespace

The namespace `ns-dpn-dp-01` was created by hand in the cluster bootstrap (see [EKS Namespace Configuration](../02-configuration/00-common-dpn-configuration.md#step23-eks-namespace-configuration)) and holds the secrets copied into it for the Data Pipeline:

| Secret | How it got there |
|--------|------------------|
| `dpn-tls`, `tls-auth-secret` | Copied automatically by `dpn-tls-cd.yaml`, if the namespace existed when it ran |
| `dpn-keycloak-secrets` | Copied manually from `ns-dpn-01` |
| `aws-access-secret` | Created manually (S3 credentials for the UI, producers and consumer file extractor) |
| `dpn-health-ca` | Created manually (OTEL collector CA bundle) |
| `ghcr-pull-secret` | Created manually (GHCR pull secret) |

Once Steps 1–2 are complete, remove the namespace. This deletes every secret and any remaining object in it:

```bash
kubectl get all,secrets,pvc -n ns-dpn-dp-01
kubectl delete namespace ns-dpn-dp-01
```

> **Note:** If `dpn-tls-cd.yaml` is run again while the namespace still exists, it re-copies `dpn-tls` and `tls-auth-secret` into it. Delete the namespace after the last run of that workflow, or delete the two secrets again.

The secrets copied out of `ns-dpn-01` are only copies; the originals are removed with the main namespace in [Remove Secrets and Certificates](#remove-secrets-and-certificates). Deactivate the IAM access key held in `aws-access-secret` as described there.

---

### Step 6 — Verify Data Pipeline Removal

```bash
kubectl get namespace ns-dpn-dp-01          # NotFound
helm list -n ns-dpn-01 | grep -E 'dpn-(producer|consumer)-|dpn-airflow'   # no output
kubectl get deployments -n ns-dpn-01 | grep -E 'dpn-(producer|consumer)-|dpn-airflow'   # no output
```

No pods matching the patterns below should remain in any namespace:

- `dpn-self-service-*`
- `dpn-consumer-file-extractor-*`, `dpn-consumer-topic-extractor-*`
- `dpn-producer-<pathway>-<product_type>-*` (data products)
- `dpn-producer-*`, `dpn-consumer-*` (legacy releases in `ns-dpn-01`)
- `dpn-airflow-*`

---

## Part 3 — Uninstall DPN Federator Certificate Manager

This part removes the Federator Certificate Manager and the HashiCorp Vault service. The Certificate Manager release also owns the shared certificate PVC `pvc-dpn-certs-fileshare` (EFS, created when `fileShare.create` is `true`), which the Federator Server and Client mount at `/tls`. Removing the release removes that PVC and the P12 keystore and truststore on it.

> **Warning:** Once the Certificate Manager and Vault are removed, the Federator Gateway will no longer be able to renew or synchronise certificates. Per [Uninstallation Sequence](#uninstallation-sequence), proceed directly to [Part 4](#part-4--uninstall-dpn-federator-gateway) immediately after this step.

---

### Step 1 — Remove the Certificate Manager

The Certificate Manager and Vault are separate Helm releases: `dpn-certificate-manager-cd.yml` deploys `dpn-certificate-manager`, `dpn-vault-https-cd.yml` deploys `vault-https`, and the older `dpn-vault-cd.yml` deploys `vault`. Remove the ones that exist:

```bash
helm uninstall dpn-certificate-manager -n ns-dpn-01
helm uninstall vault-https -n ns-dpn-01
helm uninstall vault -n ns-dpn-01        # only if dpn-vault-cd.yml was used
```

This removes the Certificate Manager deployment, the Vault deployment (including Vault's own data PVC), and their associated Kubernetes services.

---

### Step 2 — Verify Certificate Manager Removal

After the commands complete, confirm that the Certificate Manager and Vault pods have been removed:

```bash
kubectl get pods -n ns-dpn-01
```

Confirm the associated services and the shared certificate PVC have been removed:

```bash
kubectl get svc -n ns-dpn-01
kubectl get pvc pvc-dpn-certs-fileshare -n ns-dpn-01
```

No pods with names matching the patterns below should remain:

- `dpn-certificate-manager-*`
- `vault-*`

---

## Part 4 — Uninstall DPN Federator Gateway

This part removes all Federator Gateway components deployed by `dpn-federator-gateway-cd.yml`, including Kafka, Zookeeper, Redis, and the Federator Server and Client. Per [Uninstallation Sequence](#uninstallation-sequence), this should be performed immediately after [Part 3](#part-3--uninstall-dpn-federator-certificate-manager).

---

### Step 1 — Remove the Federator Gateway

```bash
helm uninstall dpn-platform -n ns-dpn-01
```

This removes all Federator Gateway Helm-managed resources in the single release, including Kafka, Zookeeper, Redis, Federator Server, and Federator Client. If the REST Federator Gateway (`dpn-rest-federator-cd.yml`) was also deployed, remove its two releases separately, and the demo runner releases (`dpn-demo-runner-cd.yml`) if they were deployed:

```bash
helm uninstall dpn-rest-federator -n ns-dpn-01
helm uninstall dpn-redis -n ns-dpn-01
helm uninstall dpn-demo-runner-client -n ns-dpn-01   # only if deployed
helm uninstall dpn-demo-runner-server -n ns-dpn-01   # only if deployed
```

`dpn-rest-federator-cd.yml` also created the IRSA role `dpn-rest-federator-secrets-role` and Secrets Manager entries under `dpn/<environment>-<cluster>/rest-federator/` — see [Remove AWS Resources Created by the Workflows](#remove-aws-resources-created-by-the-workflows).

---

### Step 2 — Verify Federator Gateway Removal

After the commands complete, confirm all Federator pods have been removed:

```bash
kubectl get pods -n ns-dpn-01
```

Confirm all services have been removed:

```bash
kubectl get svc -n ns-dpn-01
```

Confirm no Helm releases remain:

```bash
helm list -n ns-dpn-01
```

No pods with names matching the patterns below should remain:

- `dpn-federator-server-1-*`
- `dpn-federator-client-1-*`
- `dpn-kafka-src-*`
- `dpn-kafka-target-*`
- `dpn-zookeeper-src-*`
- `dpn-zookeeper-target-*`
- `dpn-kafka-ui-*`
- `dpn-redis-*`
- `dpn-rest-federator-*` (if deployed)

---

## Part 5 — Uninstall DPN Health Monitoring Service

This part removes the Health Monitoring Service stack deployed in `ns-dpn-health-01` by the `dpn-health-monitoring-cd-install.yml` orchestrator. There is no uninstall workflow — the following commands are the manual equivalent, run per sub-component. This is removed after the components above, per [Uninstallation Sequence](#uninstallation-sequence), so it remains available to confirm the earlier removals completed cleanly.

---

### Step 1 — Remove Health Monitoring Sub-Components

Remove each Helm release in the **reverse of the deployment order** used by the orchestrator (`Kafka → OpenSearch → Prometheus → Thanos → Data Prepper → Jaeger → Perses → OTel → DPN Portal → oauth2-proxy`), so no component is left pointing at a dependency that's already gone. The release names are the ones set in each `dpn-cd-*.yml` workflow:

```bash
helm uninstall dpn-oauth2-proxy-portal -n ns-dpn-health-01
helm uninstall dpn-oauth2-proxy-perses -n ns-dpn-health-01
helm uninstall dpn-oauth2-proxy-jaeger -n ns-dpn-health-01
helm uninstall dpn-oauth2-proxy-osd -n ns-dpn-health-01
helm uninstall dpn-redis-ui-health -n ns-dpn-health-01
helm uninstall dpn-portal -n ns-dpn-health-01
helm uninstall dpn-otel-collector-health -n ns-dpn-health-01
helm uninstall dpn-perses -n ns-dpn-health-01
helm uninstall dpn-jaeger -n ns-dpn-health-01
helm uninstall dpn-data-prepper -n ns-dpn-health-01
helm uninstall dpn-thanos -n ns-dpn-health-01
helm uninstall dpn-prometheus -n ns-dpn-health-01
helm uninstall dpn-opensearch -n ns-dpn-health-01
helm uninstall dpn-kafka-stack -n ns-dpn-health-01
```

> **Note:** `dpn-portal` (a tile landing page linking out to the observability UIs) has replaced the retired `nginx-observability` reverse proxy; it is fronted by its own `oauth2-proxy` gateway. The `oauth2-proxy` releases share the `dpn-redis-ui-health` session store, so remove it after them. Kafka UI uses native Keycloak OIDC login on its own internal load balancer, so removing these releases does not affect Kafka UI access. Complete the Kafka topic checks from the [Pre-Uninstallation Checklist](#pre-uninstallation-checklist) before proceeding regardless.

`dpn-cd-oauth2-proxy.yml` also created the IRSA role `dpn-oauth2-proxy-secrets-role` and Secrets Manager entries under `dpn/<environment>-<cluster>/oauth2-proxy/` — see [Remove AWS Resources Created by the Workflows](#remove-aws-resources-created-by-the-workflows).

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

Remove the namespace itself, if no longer required. This also deletes the secrets `dpn-tls`, `tls-auth-secret` and `dpn-health-tls` that `dpn-tls-cd.yaml` placed there:

```bash
kubectl delete namespace ns-dpn-health-01
```

---

## Part 5a — Uninstall DPN Authentication Service

This part removes the Keycloak-based DPN Authentication Service and its PostgreSQL instance, deployed by `dpn-keycloak-cd.yml` as the single Helm release `dpn-keycloak` in `ns-dpn-01`. It is removed **last**, per [Uninstallation Sequence](#uninstallation-sequence). There is no uninstall workflow.

```bash
helm uninstall dpn-keycloak -n ns-dpn-01
```

This removes the PostgreSQL PVC `dpn-keycloak-postgres-data` with the release, permanently losing every realm, user and client. Keycloak itself runs as a StatefulSet; its per-replica PVCs (`keycloak-data-*`) are not deleted by `helm uninstall`. Remove them if no longer required:

```bash
kubectl get pvc -n ns-dpn-01 | grep keycloak
kubectl delete pvc -n ns-dpn-01 -l app.kubernetes.io/instance=dpn-keycloak
```

**Verify removal:**

```bash
kubectl get pods -n ns-dpn-01   # no dpn-keycloak-* or dpn-keycloak-postgres-* pods should remain
kubectl get pvc -n ns-dpn-01    # no keycloak PVCs should remain
```

> **Note:** If the label selector above matches nothing, delete the `keycloak-data-*` PVCs by name. The Keycloak admin and client secrets that `dpn-keycloak-cd.yml` reads from Secrets Manager live under `dpn/<environment>-<cluster>/keycloak/`.

---

## Part 6 — Post-Uninstallation Cleanup

After Parts 1–5a have completed successfully, perform the following manual cleanup steps to remove residual resources from AWS and the Kubernetes cluster.

---

### Remove Container Images from ECR / GHCR

Remove container images from your own Amazon ECR repositories if they are no longer required (skip this if you deploy exclusively from DSI-provided GHCR images).

List all repositories:

```bash
aws ecr describe-repositories --region <AWS_REGION>
```

Delete each repository as required:

```bash
aws ecr delete-repository \
  --repository-name <image-name> \
  --region <AWS_REGION> \
  --force
```

Repeat for all DPN-related images, including:

- `dpn-federator-server`
- `dpn-federator-client`
- `dpn-federator-certificate-manager`
- `dpn-file-scan-service`
- `dpn-self-service`
- `dpn-producer-file-adaptor-generic`, `dpn-producer-topic-adaptor-generic`
- `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor`
- `dpn-airflow`
- legacy pre-2.1.0 images: `dpn-producer-<processType>-<adaptor|mapper>-<schemaType>`, `dpn-consumer-<processType>-mapper`

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
kubectl get secrets -n ns-dpn-01
kubectl delete secrets --all -n ns-dpn-01
```

This includes the `ghcr-pull-secret` used for GHCR image pulls and the secrets created by `dpn-tls-cd.yaml` (`cert-manager-truststore`, `dpn-tls`, `fed-gateway-tls`, `dpn-health-tls`, `tls-auth-secret`). Copies in `ns-dpn-health-01` and `ns-dpn-dp-01` are removed with those namespaces ([Part 5](#step-2--verify-health-monitoring-service-removal), [Part 2, Step 5](#step-5--remove-the-data-pipeline-namespace)).

Remove any persistent volume claims not deleted with their release:

```bash
kubectl get pvc -n ns-dpn-01
kubectl delete pvc --all -n ns-dpn-01
```

Deactivate and delete the IAM access key held in `aws-access-secret` (used by the Data Pipeline for S3), and remove the IAM user if it was created only for DPN.

Remove the namespace itself once it is empty:

```bash
kubectl delete namespace ns-dpn-01
```

---

### Remove AWS Resources Created by the Workflows

The CD workflows create the following AWS resources. `helm uninstall` does not remove any of them.

**Secrets Manager entries.** Every workflow writes under the prefix `dpn/<environment>-<cluster>/` (for example `dpn/dev-dpn01/airflow/FERNET_KEY`): `dpn-tls-cd.yaml` (TLS material), `dpn-cd-airflow.yml` (`airflow/`), `dpn-cd-oauth2-proxy.yml` (`oauth2-proxy/`), `dpn-rest-federator-cd.yml` (`rest-federator/`), `dpn-file-scan-prerequisites-cd.yml` (`file-scan-service/`), the two Vault AppRole workflows (`dpn-certificate-manager-role-id-creation.yml`, `dpn-rest-federator-role-id-creation.yml`), plus the Keycloak secrets under `keycloak/`. List and delete them:

```bash
aws secretsmanager list-secrets --region <AWS_REGION> \
  --filters Key=name,Values=dpn/<environment>-<cluster>/ \
  --query 'SecretList[].Name' --output text

aws secretsmanager delete-secret --region <AWS_REGION> \
  --secret-id <secret-name> --recovery-window-in-days 7
```

**IRSA roles.** Delete each role's inline policies, then the role:

| Role | Created by |
|------|------------|
| `dpn-airflow-secrets-role` | `dpn-cd-airflow.yml` |
| `dpn-oauth2-proxy-secrets-role` | `dpn-cd-oauth2-proxy.yml` |
| `dpn-rest-federator-secrets-role` | `dpn-rest-federator-cd.yml` |
| `dpn-file-scan-service-secrets-role` | `dpn-file-scan-prerequisites-cd.yml` |
| `<serviceAccount-name>-s3-role` (one per legacy file-pathway chart) | `dpn-cd-data-pipelines.yml` |

```bash
aws iam list-role-policies --role-name <role-name>
aws iam delete-role-policy --role-name <role-name> --policy-name <policy-name>
aws iam delete-role --role-name <role-name>
```

The Vault auto-unseal KMS key and its role `dpn-vault-kms-unseal-role` were created manually, not by a workflow (see the comment in `dpn-federator-cert-manager/charts/vault-https/values/aws/<environment>-<cluster>.yaml`). Remove them according to your key-management policy; schedule the KMS key for deletion only once you are sure Vault data is no longer needed.

**S3 buckets.** Empty and delete:

- The Self-Service registry backup bucket (`dpconfig` by default, or the value of `DPN_REGISTRY_BACKUP_CONTAINER`)
- Legacy pre-2.1.0 data pipeline buckets created by `dpn-cd-data-pipelines.yml` (`<containerName>-<environment>-<NN>-<account-id>-<region>`, and the `dp-consumer-stage` bucket)
- Data product buckets that were not deleted from the UI
- The File Scanning Service buckets (`FILESCAN_SOURCE_BUCKET`, `FILESCAN_DEST_BUCKET` in the config JSON), which were created manually

```bash
aws s3 rb s3://<bucket-name> --force
```

**SNS / SQS / GuardDuty.** Delete the File Scanning Service SNS topic and SQS queue (`FILESCAN_SNS_TOPIC_NAME`, `FILESCAN_SQS_QUEUE_NAME` in the config JSON) and disable the GuardDuty Malware Protection plan, as described in [Part 1, Step 2](#step-2--verify-file-scanning-service-removal).

---

### Disable the Deployment Workflows

Unlike ADO pipelines, GitHub Actions workflows are just version-controlled files (`.github/workflows/*.yml`) — there's no separate "registered pipeline" object to delete. Once uninstallation is confirmed complete:

- If this organisation's DPN was the only consumer of that repository's workflows, remove the `oidc_github_runner_admin` IAM role (or its trust policy) in the target AWS account and revoke EKS cluster access (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role)) so the workflows can no longer authenticate, rather than deleting the workflow files themselves (other environments may still use them). Do the same for the role passed as `roleToAssume` to the Self-Service workflows in `dpn-data-pipelines`.
- If you want to actively prevent accidental re-runs, disable the individual workflows from the GitHub UI (**Actions → select workflow → "..." → Disable workflow**) rather than deleting the files.

---

## Final Verification

After all parts are complete, confirm the following conditions are met before closing the decommissioning activity. Run the Kubernetes checks against `ns-dpn-01`, `ns-dpn-dp-01` and `ns-dpn-health-01` (each should be gone, or empty if you kept it).

| Verification | Command | Expected Result |
|-------------|---------|-----------------|
| Namespaces removed | `kubectl get namespace ns-dpn-01 ns-dpn-dp-01 ns-dpn-health-01` | NotFound |
| No pods running | `kubectl get pods -n <namespace>` | No resources found |
| No services remaining | `kubectl get svc -n <namespace>` | No resources found |
| No deployments remaining | `kubectl get deployments -n <namespace>` | No resources found |
| No Helm releases | `helm list -n <namespace>` | No releases found |
| No persistent volume claims | `kubectl get pvc -n <namespace>` | No resources found |
| No secrets remaining | `kubectl get secrets -n <namespace>` | No resources found |
| Secrets Manager cleared | `aws secretsmanager list-secrets --filters Key=name,Values=dpn/<environment>-<cluster>/` | No entries listed |
| IRSA roles removed | `aws iam list-roles --query "Roles[?starts_with(RoleName,'dpn-')].RoleName"` | No DPN roles listed |
| ECR repositories cleared | `aws ecr describe-repositories --region <AWS_REGION>` | No DPN repositories listed |

If all commands return no DPN resources, the DPN platform has been successfully decommissioned.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
