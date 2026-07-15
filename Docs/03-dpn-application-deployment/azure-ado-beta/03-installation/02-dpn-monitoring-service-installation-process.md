# DPN Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Steps](#installation-steps)
  - [1. Create the Corrected Environment Config Files](#1-create-the-corrected-environment-config-files)
  - [2. Provision the Namespace and Registry Access](#2-provision-the-namespace-and-registry-access)
  - [3. Remediate the Committed Dashboard Credential](#3-remediate-the-committed-dashboard-credential)
  - [4. Configure Environment Approval Gates](#4-configure-environment-approval-gates)
  - [5. Provision the Thanos Object Storage Secret](#5-provision-the-thanos-object-storage-secret)
  - [6. Configure Alerting](#6-configure-alerting)
  - [7. Run `monitoring-master-cd.yaml`](#7-run-monitoring-master-cdyaml)
  - [8. Approve Each Stage's Deployment Gate](#8-approve-each-stages-deployment-gate)
  - [9. Verify the HPA on the OTEL Collector](#9-verify-the-hpa-on-the-otel-collector)
  - [10. Verify the Deployment](#10-verify-the-deployment)
- [Troubleshooting](#troubleshooting)
  - [Config File Not Found for `pdev`/`ptest`/`puat`](#config-file-not-found-for-pdevptestpuat)
  - [Deployed Resources Show the Wrong Environment Label](#deployed-resources-show-the-wrong-environment-label)
  - [Kafka/Zookeeper Image Pull Fails](#kafkazookeeper-image-pull-fails)
  - [Dashboard Login Still Accepts an Old/Default Credential](#dashboard-login-still-accepts-an-olddefault-credential)
- [Review Notes](#review-notes)

---

## Overview

This describes installation using pipeline structure (`environment`+`cluster` parameters, `monitoring-master-cd.yaml`'s 11-stage orchestration, the OTEL Collector HPA) against `release-internal`'s three real environments — `pdev`, `ptest`, `puat` — each treated as its own single-cluster (`dpn01`) deployment under that structure.

## Prerequisites

- An AKS cluster matching the target environment's config (see [Step 1](#step-1--create-the-corrected-environment-config-files) for the corrected values), with `ns-dpn-health-01` already created.
- The Azure DevOps Service Connection for the target environment.
- Access to the environment-specific ACR for Kafka/Zookeeper images, and to Docker Hub/Quay.io for everything else.
- The `dsi-ppd` Environment resource (or the per-environment split recommended in the Configuration Guide) configured with its approval check.
- A **freshly generated** `.htpasswd` for the dashboard proxy — do not reuse anything currently committed in `release-internal`. See [Step 3](#step-3--remediate-the-committed-dashboard-credential).
- The real Thanos storage account name/key for the target environment.
- SMTP relay details and an alert recipient address.
- The metrics-server running in the cluster (standard on AKS) — required for the OTEL Collector's HPA.

---

## Installation Steps

### 1. Create the Corrected Environment Config Files

pipeline expects `values-{environment}-{cluster}.json`. Create three new files using `release-internal`'s values, corrected per [Environment Configuration](./config.md#environment-configuration-pdev--ptest--puat) in the Configuration Guide:

```
.pipelines/azure-pipelines/config/values-<env>-<cluster>.json
```

Each should match the shape of existing `values-<env>-<cluster>.json` (including the `KAFKA_BROKER` field, which `release-internal`'s originals omit), populated with the corrected `pdev`/`ptest`/`puat` values from the Configuration Guide's table — **not** copied directly from `release-internal`'s source JSONs, which still contain the `ENV_NAME` and `BASE_REGISTRY` bugs.

---

### 2. Provision the Namespace and Registry Access

```bash
kubectl create namespace ns-dpn-health-01
```

Confirm the target environment's AKS node pool can pull from its own ACR (per the corrected `BASE_REGISTRY` value) for Kafka/Zookeeper, and from Docker Hub/Quay.io for everything else.

---

### 3. Remediate the Committed Dashboard Credential

Do this before deploying nginx-observability, regardless of environment:

1. Remove `config/nginx/.htpasswd` from `release-internal`'s tree; confirm the `.gitignore` entry exists.
2. Generate a new credential:
   ```bash
   htpasswd -nbB admin "$(openssl rand -base64 24)"
   ```
3. Apply it directly as a Secret:
   ```bash
   kubectl create secret generic dpn-nginx-basic-auth \
     --from-literal=.htpasswd="<output from the command above>" \
     -n ns-dpn-health-01
   ```
4. Treat the previously committed credential as compromised regardless of remediation timing.

---

### 4. Configure Environment Approval Gates

Confirm the `dsi-ppd` Environment resource (or the `dsi-pdev`/`dsi-ptest`/`dsi-ppd` split recommended in the Configuration Guide) exists and is configured before triggering `monitoring-master-cd.yaml`.

---

### 5. Provision the Thanos Object Storage Secret

```bash
kubectl create secret generic thanos-objstore-config \
  --from-file=objstore.yml=charts/thanos/thanos-objstore-config.yaml \
  -n ns-dpn-health-01
```

Edit that file first to replace the dev placeholder storage account with the real `pdev`/`ptest`/`puat` value and populate `storage_account_key`.

---

### 6. Configure Alerting

Copy `config/.env.example` to `.env` (not committed) and set `ALERT_EMAIL`, `SMTP_HOST`/`SMTP_PORT`/`SMTP_FROM`, optional `SMTP_USER`/`SMTP_PASS`, and `ALERT_SEVERITIES`.

---

### 7. Run `monitoring-master-cd.yaml`

environment values:

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `sc-dpn-<env>-ppd-001` |
| `environment` | `pdev` / `ptest` / `puat` |
| `cluster` | `dpn01` (the only cluster defined for these environments under this reconciliation) |
| `imageTag` | defaults to `0.95.0` |

---

### 8. Approve Each Stage's Deployment Gate

Approve each of the nine `deployment:` jobs as they come up.

---

### 9. Verify the HPA on the OTEL Collector

```bash
kubectl get hpa -n ns-dpn-health-01
```

Confirm real CPU/memory percentages, `MINPODS`/`MAXPODS` reading `1`/`10`. For `puat`, confirm the chart's static starting `replicaCount: 3` was honoured before the HPA took over scaling from there.

---

### 10. Verify the Deployment

1. Confirm all pods `Running`.
2. Confirm resource labels reflect the correct environment name (not `puat` everywhere, if deploying `pdev`/`ptest` — this is exactly what Step 1's correction prevents).
3. Confirm Thanos writes successfully to the configured Azure Blob container.
4. Confirm a test alert reaches the configured `ALERT_EMAIL`.
5. Confirm the dashboard proxy accepts only the newly generated credential from Step 3.
6. Trigger a known event upstream and confirm metrics/logs/traces all arrive at their respective dashboards, consistent with the corrected data flow (both logs and traces should show up via their Kafka-backed paths, not the diagram's direct-delivery paths).

---

## Troubleshooting

Every troubleshooting entry (Kafka naming-regression checks in `kafka-cd.yaml`, the OTel→Kafka dependency check, CrashLoop from a missing `health_check` extension, HPA `<unknown>` targets) applies unchanged, since it's chart-level logic. Additional entries specific to this reconciliation:

### Config File Not Found for `pdev`/`ptest`/`puat`

Confirm `values-{pdev,ptest,puat}-dpn01.json` actually exist under this exact naming — they don't ship with either branch as-is; Step 1 creates them.

### Deployed Resources Show the Wrong Environment Label

Confirm Step 1 used the **corrected** `ENV_NAME` values, not values copied directly from `release-internal`'s buggy source JSONs.

### Kafka/Zookeeper Image Pull Fails

Confirm `BASE_REGISTRY` in the new config file is a fully-resolved hostname, not a literal `$(ACR_NAME)` placeholder — this was the root cause of the same failure mode on `release-internal`'s original `pdev.json`/`ptest.json`.

### Dashboard Login Still Accepts an Old/Default Credential

Confirm Step 3 was completed and the live Secret's content matches the newly generated credential.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
