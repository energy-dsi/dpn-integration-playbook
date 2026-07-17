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
- [Step4: Containerized Deployment Using DSI Provided Container Images](#step4-containerized-deployment-using-dsi-provided-container-images)
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

### Step1: Run `monitoring-master-cd.yaml`

#### Step1a: Prepare runtime parameters

The CD Pipeline provided needs to be modified in the following places to point to the Organisation's service connection and environment.

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |

![Pipeline Parameters](../../../04-dpn-architecture/images/dpn_pipeline_parameters.png)

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

Organisations should maintain an approval gate for the deployment. The CD Pipleine prompts for the approval under dsi-ppd environment.The environment needs to be created by Organisation to allow only authorised personnel to perform deployment. 

---

### Step2: Post Deployment Verification

1. Confirm all pods `Running`.
2. Confirm the init pods completed the job
2. Confirm resource labels reflect the correct environment name (not `puat` everywhere, if deploying `pdev`/`ptest` — this is exactly what Step 1's correction prevents).

**Note: The nginx pod may appear in error state initially as it also grants access to kafka-ui under federator service. Once federator service is up, the nginx will automatically be in run state. If not then the issue to be investigated.

---

## Step3: Troubleshooting

Every troubleshooting entry (Kafka naming-regression checks in `kafka-cd.yaml`, the OTel→Kafka dependency check, CrashLoop from a missing `health_check` extension, HPA `<unknown>` targets) applies unchanged, since it's chart-level logic. Additional entries specific to this reconciliation:

### Config File Not Found for Specific Environment

Confirm `values-{environment}-{cluster}.json` actually exist under this exact naming — they don't ship with either branch as-is; Step 1 creates them.

### Deployed Resources Show the Wrong Environment Label

Confirm Step 1 used the **corrected** `ENV_NAME` values

### Kafka/Zookeeper Image Pull Fails

Confirm `BASE_REGISTRY` in the config file hosted under .pipelines root folder must uses a fully-resolved hostname like `acrdpnXXXX.azurecr.io`,, not a literal like only `acrdpnXXXX` placeholder 

---

## Step4: Containerized Deployment Using DSI Provided Container Images

<<Tamanna to update>>



## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
