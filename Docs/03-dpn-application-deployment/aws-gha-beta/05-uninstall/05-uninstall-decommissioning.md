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
  - [Step 1 — Remove the Data Pipeline](#step-1--remove-the-data-pipeline)
  - [Step 2 — Verify Data Pipeline Removal](#step-2--verify-data-pipeline-removal)
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
  - [Remove Container Images from ECR / GHCR](#remove-container-images-from-ecr--ghcr)
  - [Remove Kafka Topics](#remove-kafka-topics)
  - [Remove Secrets and Certificates](#remove-secrets-and-certificates)
  - [Disable the Deployment Workflows](#disable-the-deployment-workflows)
- [Final Verification](#final-verification)
- [Review Notes](#review-notes)

---

## Overview

This document describes the procedure for **completely uninstalling the DPN platform** from an organisation's AWS environment.

The uninstallation process removes the following components:

- DPN File Scanning Service
- DPN Data Pipeline containers (adaptors, mappers, extractors)
- DPN Federator Certificate Manager and Vault service
- DPN Federator Gateway (Kafka, Zookeeper, Redis, Federator Server and Client)
- DPN Health Monitoring Service (Kafka-health, OpenTelemetry Collector, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, Nginx-observability)
- Kubernetes resources and Helm releases
- Container images in Amazon ECR / GHCR

**None of the DPN components have a dedicated uninstall GitHub Actions workflow today** — uninstallation is performed with `helm uninstall` commands run directly against the target cluster (via `kubectl`/`helm` from a machine with the right OIDC/kubeconfig access, or as an ad-hoc job on the shared self-hosted runner), targeted at the specific Helm release each component owns. This approach ensures that only the components you intend to remove are affected.

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

There is no uninstall workflow for any component — only CD (deploy) workflows exist. For every part below, uninstallation is a direct `helm uninstall <release> -n <namespace>` command, scoped to the Helm release that component owns, leaving other components unaffected. [Part 5](#part-5--uninstall-dpn-health-monitoring-service) gives the same pattern applied per sub-component, following the removal order described below.

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

Confirm the SNS topic, SQS queue, and GuardDuty Malware Protection plan created for the File Scanning Service are also removed or disabled — `helm uninstall` does not clean these up, since they were provisioned manually (see [Configure DPN File Scan Service, Step2](../02-configuration/06-configure-dpn-file-scan-service.md#step2-aws-resource-setup-snssqsguardduty)), not by this Helm release.

---

## Part 2 — Uninstall DPN Data Pipeline

This part removes all producer and consumer data pipeline containers deployed from `dpn-data-pipelines`. Uninstalling targets only the Helm releases associated with the data pipeline and does not affect the Federator or Certificate Manager components.

---

### Step 1 — Remove the Data Pipeline

Each producer/consumer chart was installed as its own Helm release (per the `dpn-cd-data-pipelines.yml` workflow's discovery convention). List releases in the namespace, then uninstall each one belonging to the data pipeline:

```bash
helm list -n <namespace>
helm uninstall <data-pipeline-release> -n <namespace>
```

Repeat for every producer/consumer release you deployed — there's no single release name that covers all of them, since each product/pathway combination gets its own.

---

### Step 2 — Verify Data Pipeline Removal

After the commands complete, confirm that all data pipeline pods have been removed:

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

### Step 1 — Remove the Certificate Manager

The Certificate Manager and Vault are separate Helm releases (`dpn-vault-cd.yml`/`dpn-vault-https-cd.yml` and `dpn-certificate-manager-cd.yml` deploy them independently) — remove both:

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

This removes all Federator Gateway Helm-managed resources in the single release, including Kafka, Zookeeper, Redis, Federator Server, and Federator Client. If the REST Federator Gateway (`dpn-rest-federator-cd.yml`) was also deployed, remove its two releases separately:

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

After Parts 1–5 have completed successfully, perform the following manual cleanup steps to remove residual resources from AWS and the Kubernetes cluster.

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
- `producer-file-adaptor-*`
- `producer-file-mapper-*`
- `consumer-file-extractor-*`
- `consumer-file-mapper-*`

If any component was deployed using DSI-provided GHCR images (`ghcr.io/energy-dsi/...`), no image deletion is required on the `energy-dsi` GHCR itself — those images are shared, DSI-managed packages. Only remove the `ghcr-pull-secret` Kubernetes secret used to authenticate against it, per [Remove Secrets and Certificates](#remove-secrets-and-certificates).

---

### Remove Kafka Topics

If the Kafka namespace and cluster have been fully removed by the `helm uninstall dpn-platform` command in [Part 4](#part-4--uninstall-dpn-federator-gateway), Kafka topics will have been deleted automatically. If any topics persist, remove them via the Kafka UI before the namespace is deleted.

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

### Disable the Deployment Workflows

Unlike ADO pipelines, GitHub Actions workflows are just version-controlled files (`.github/workflows/*.yml`) — there's no separate "registered pipeline" object to delete. Once uninstallation is confirmed complete:

- If this organisation's DPN was the only consumer of that repository's workflows, remove the `oidc_github_runner_admin` IAM role (or its trust policy) in the target AWS account and revoke EKS cluster access (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role)) so the workflows can no longer authenticate, rather than deleting the workflow files themselves (other environments may still use them).
- If you want to actively prevent accidental re-runs, disable the individual workflows from the GitHub UI (**Actions → select workflow → "..." → Disable workflow**) rather than deleting the files.

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
| ECR repositories cleared | `aws ecr describe-repositories --region <AWS_REGION>` | No DPN repositories listed |

If all commands return no DPN resources, the DPN platform has been successfully decommissioned.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
