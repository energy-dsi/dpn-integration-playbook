# DPN Monitoring Service Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Steps](#installation-steps)
  - [Step1: Run `monitoring-master-cd.yaml`](#step1-run-monitoring-master-cdyaml)
    - [Step1a: Prepare runtime parameters](#step1a-prepare-runtime-parameters)
    - [Step1b: Execute CD Pipeline](#step1b-execute-cd-pipeline)
    - [Step1c: Approve Stage's Deployment Gate](#step1c-approve-stages-deployment-gate)
  - [Step2: Post Deployment Verification](#step2-post-deployment-verification)
- [Step3: Troubleshooting](#step3-troubleshooting)
  - [Config File Not Found for Specific Environment](#config-file-not-found-for-specific-environment)
  - [Deployed Resources Show the Wrong Environment Label](#deployed-resources-show-the-wrong-environment-label)
  - [Kafka/Zookeeper Image Pull Fails](#kafkazookeeper-image-pull-fails)
- [Review Notes](#review-notes)

---

## Overview

This describes installation of the DPN Health Monitoring Service via `monitoring-master-cd.yaml`, whose multi-stage orchestration (Init → Approval → Kafka → OpenSearch → Prometheus → Thanos → Data Prepper → Jaeger → Perses → OTel → dpn-portal image → OAuth2 Proxy → Validate) deploys every component into `ns-dpn-health-01`. The pipeline is driven by `environment` and `cluster` runtime parameters and supports all provided environments — `dev`, `devtest`, `test` (each with `dpn01` or `dpn02`) and `pdev`, `ptest`, `puat` (single-cluster, `dpn01` only). The deployment approval gate resolves to the environment's approver group automatically (`dsi-dev`, `dsi-devtest`, or `dsi-ppd`).

For the configuration this installation depends on — the environment config file and the required secrets — see [Configure DPN Health Monitoring Service](../02-configuration/03-configure-dpn-health-monitoring-service.md).

## Prerequisites

- An AKS cluster matching the target environment's config, with `ns-dpn-health-01` already created.
- The Azure DevOps Service Connection for the target environment.
- Access to the environment-specific ACR for Kafka/Zookeeper images, and to Docker Hub/Quay.io for everything else.
- The approval Environment resource for the target environment configured with its approval check — the pipeline resolves the group per environment (`dsi-dev`, `dsi-devtest`, or `dsi-ppd`).
- The per-environment config file (`config/<env>-<cluster>.json`, including `OBSERVABILITY_LB_IP`) prepared as described in [Configure DPN Health Monitoring Service → Step 1](../02-configuration/03-configure-dpn-health-monitoring-service.md#step-1-prepare-environment-configuration-file).
- The required secrets created as described in [Configure DPN Health Monitoring Service → Step 2](../02-configuration/03-configure-dpn-health-monitoring-service.md#step-2-prepare-secrets-configuration): `dpn-mon-storage-connection-string` (Thanos object-storage config, including the storage account/SAS token), the pre-existing `dpn-health-tls` secret, and `KC-SERVICE-CLIENT-SECRET` in the environment's Key Vault (required for the oauth2-proxy and Kafka UI logins — a fresh environment fails the pipeline's Validate stage without it).
- SMTP relay details and an alert recipient address.
- The metrics-server running in the cluster (standard on AKS) — required for the OTEL Collector's HPA.

---

## Installation Steps

### Step1: Run `monitoring-master-cd.yaml`

#### Step1a: Prepare runtime parameters

The CD Pipeline provided needs to be modified in the following places to point to the Organisation's service connection and environment.

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` — `dev`, `devtest`, `test`, `pdev`, `ptest`, or `puat` |
| `cluster` | `dpn01` or `dpn02` (DSI provides two dpn configurations per environment for `dev`/`devtest`/`test`; `pdev`/`ptest`/`puat` are single-cluster and only accept `dpn01`) |
| `imageTag` | Image tag for the OTel Collector (default `0.95.0`) |
| `dpnPortalImageTag` | Image tag for the dpn-portal image — **no default; must be supplied** (the short git SHA from a `dpn-portal-ci.yaml` run) |

![Pipeline Parameters](../../../04-dpn-architecture/images/dpn_pipeline_parameters.png)

**Note:** Organisations must review the CD Pipeline code for the following. 

- The agent pool name has been modified to Organisation required agent pool name
- There should not be any `<<Your specific value>>` in the parameters. The DSI package has provided this specific paramter to ensure configuration is modified by Organisations
- The container image is appropriate and referred from GHCR repository unless Organisation plans to use a separate image repository on their own
- The environment parameters are pointing to correct deployment environment
- The DSM endpoints are correctly pointing to the target deployment environment
- Required Firewall rules are applied

#### Step1b: Execute CD Pipeline

Create and run CD Pipeline for monitoring service from the following CD pipeline yaml file

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── monitoring-master-cd.yaml
```
---

#### Step1c: Approve Stage's Deployment Gate

Organisations should maintain an approval gate for the deployment. The CD Pipeline prompts for approval under the target environment's approver group, which it resolves automatically — `dsi-dev` for `dev`, `dsi-devtest` for `devtest`/`test`, and `dsi-ppd` for `pdev`/`ptest`/`puat`. The corresponding Azure DevOps Environment needs to be created by the Organisation to allow only authorised personnel to perform deployment.

---

### Step2: Post Deployment Verification

1. Confirm all pods `Running`.
2. Confirm the init pods completed the job (e.g. the OpenSearch dashboard init job).
3. Confirm resource labels reflect the correct environment name.
4. Confirm the four `oauth2-proxy` gateways (OpenSearch Dashboards, Jaeger, Perses, Portal) each have a ready replica and a LoadBalancer address — the pipeline's Validate stage asserts this and fails the run if any is not serving.

---

## Step3: Troubleshooting

Every troubleshooting entry (Kafka naming-regression checks in `kafka-cd.yaml`, the OTel→Kafka dependency check, CrashLoop from a missing `health_check` extension, HPA `<unknown>` targets) applies unchanged, since it's chart-level logic. Additional entries specific to this reconciliation:

### Config File Not Found for Specific Environment

Confirm `<env>-<cluster>.json` exists under `.pipelines/azure-pipelines/config/` with this exact naming (e.g. `pdev-dpn01.json`) — prepared per [Configure DPN Health Monitoring Service → Step 1](../02-configuration/03-configure-dpn-health-monitoring-service.md#step-1-prepare-environment-configuration-file).

### Deployed Resources Show the Wrong Environment Label

Confirm Step 1 used the **corrected** `ENV_NAME` values

### Kafka/Zookeeper Image Pull Fails

Confirm `BASE_REGISTRY` in the config file hosted under .pipelines root folder must uses a fully-resolved hostname like `acrdpnXXXX.azurecr.io`,, not a literal like only `acrdpnXXXX` placeholder 

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
