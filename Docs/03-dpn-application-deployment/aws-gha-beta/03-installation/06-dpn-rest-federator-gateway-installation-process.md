# DPN REST Federator Gateway Installation Process

This document covers the installation of the **DPN REST Federator Gateway** (the REST/HTTPS federation gateway and its `dpn-redis` cache) into a single target environment and a single DPN cluster on Amazon Elastic Kubernetes Service (EKS).

**Full instructions live in the configuration guide.** The end-to-end REST Federator Gateway flow — overview, prerequisites, secrets, the values to populate, Vault AppRole setup, autoscaling, and deployment — is documented in one place:

**[Configure DPN REST Federator Gateway](../02-configuration/06-configure-dpn-rest-federator-gateway.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault and the Certificate Manager.** Complete [Vault installation](01-dpn-vault-installation-process.md) and [Certificate Manager installation](03-dpn-certificate-manager-installation-process.md) first — the gateway reads its certificate material and keystore/truststore passwords directly from Vault, and its rendered config depends on the `certificate-manager-secrets` Kubernetes secret already existing in the namespace at deploy time (see the configuration guide's [Step2](../02-configuration/06-configure-dpn-rest-federator-gateway.md#step2-configure-secrets)).

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CI/CD](#step2-execute-cicd)
  - [Step2a. CI (component source repository)](#step2a-ci-component-source-repository)
  - [Step2b. Configure GHCR Image Access](#step2b-configure-ghcr-image-access)
  - [Step2c. One-Time Vault AppRole Setup](#step2c-one-time-vault-approle-setup)
  - [Step2d. Execute CD Workflow](#step2d-execute-cd-workflow)
  - [Step2e. Verify CD Workflow](#step2e-verify-cd-workflow)
- [Step3: Troubleshooting](#step3-troubleshooting)
  - [Invalid Keystore/Truststore Password](#invalid-keystoretruststore-password)
  - [Pod CrashLoop on First Deploy — Empty Truststore Password](#pod-crashloop-on-first-deploy--empty-truststore-password)
  - [403 from the Backend](#403-from-the-backend)
  - [HPA Not Scaling](#hpa-not-scaling)
- [Reference: Container Images Used](#reference-container-images-used)
- [Review Notes](#review-notes)

---

## Overview

The REST Federator Gateway is deployed as **two independently re-runnable jobs** in one GitHub Actions CD workflow run: **deploy-redis** (this chart's own `dpn-redis` cache) followed by **deploy-rest-federator** (the gateway itself).

Both workflows, and the charts they deploy, live in the central `dpn-containerised-deployment-service` repository:

```text
dpn-containerised-deployment-service/
├── .github/
│   ├── workflows/
│   │   ├── dpn-rest-federator-cd.yml                  <- DPN CD - REST Federator Gateway
│   │   └── dpn-rest-federator-role-id-creation.yml    <- DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)
│   └── config/
│       └── aws/<environment>-<cluster>.json
└── dpn-rest-federator-gateway/
    ├── charts/
    │   ├── dpn-rest-federator/values/aws/<environment>-<cluster>.yaml
    │   └── dpn-redis/values/aws/<environment>-<cluster>.yaml
    └── scripts/vault/                                 <- setup-approle.sh, rest-federator-policy.hcl
```

Key points, detailed in the configuration guide:
- Unlike the gRPC Federator Gateway, this component authenticates to Vault with **AppRole** on AWS, not the root token — set up once per environment/cluster via [Step2c](#step2c-one-time-vault-approle-setup) before the first deploy.
- Backend API key and Vault credentials come from **AWS Secrets Manager** under `secretsManager.secretPrefix`, synced via a dedicated `ServiceAccount`/IRSA role and `SecretProviderClass` — both provisioned automatically by the CD workflow.
- A **HorizontalPodAutoscaler** is on by default (`hpa.enabled: true`) — no separate opt-in step.
- `certificate-manager-secrets` must already exist in the namespace at deploy time — the rendered config's Vault truststore password is resolved via a Helm `lookup` against it, not an environment variable read at pod start-up.

---

## Step1: Verify Prerequisites

Confirm the prerequisites are met before starting the REST Federator Gateway installation. See [Configure DPN REST Federator Gateway → Prerequisites](../02-configuration/06-configure-dpn-rest-federator-gateway.md#step1-meet-the-prerequisites).

In summary:

- Vault and Certificate Manager deployed and in running state, with this gateway's endpoint included in the certificate's SANs
- `cert-manager-truststore` and `certificate-manager-secrets` secrets present in the target namespace
- DPN Authentication Service (Keycloak) reachable
- OAuth2 client ID + Management Node URL + IDP URLs received from DSM
- Backend service reachable, with a backend API key available
- Populated config JSON and values file for the `<environment>-<cluster>` combination
- **Vault AppRole configured for this component** — run the one-time workflow in [Step2c](#step2c-one-time-vault-approle-setup) before the first deploy

**Note:** Organisations must review the CI/CD workflow code for the following.

- If running your own CI, keep only the relevant build, unit test, and image-push steps
- The container image is appropriate and referred from GHCR repository unless the Organisation plans to use a separate image repository of their own
- The config JSON's environment parameters are pointing to the correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required firewall rules are applied
- Both CI and CD are verified for the above prerequisites before execution

---

## Step2: Execute CI/CD

### Step2a. CI (component source repository)

CI (build, test, security scan, and image push to GHCR) runs as GitHub Actions workflows in the `dpn-rest-federator-gateway` source repository itself — separately from the CD workflow below.

Once CI pushes a new tag, note it for use as `imageTag` in [Step2d](#step2d-execute-cd-workflow) — the image registry should show:

```text
dpn-rest-federator-server:<image tag>
```

### Step2b. Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`. Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably.

Create a GitHub Personal Access Token with `read:packages` scope, then create a Kubernetes secret from it:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

### Step2c. One-Time Vault AppRole Setup

**Run this once per `<environment>-<cluster>` combination, before the first `dpn-rest-federator-cd.yml` run**, and again whenever the AppRole `secret-id` needs rotating.

Go to **Actions → DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup) → Run workflow** (`dpn-rest-federator-role-id-creation.yml`), and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02` (default `dpn01`) |
| `cloud` | `aws` (default) |

This enables the `approle` Vault auth method, writes the `rest-federator-policy`, creates/updates the `rest-federator` AppRole role, and publishes `VAULT_APPROLE_ROLE_ID`/`VAULT_APPROLE_SECRET_ID` to AWS Secrets Manager under `dpn/<environment>-<cluster>/rest-federator/`. See [Configure DPN REST Federator Gateway, Step3b](../02-configuration/06-configure-dpn-rest-federator-gateway.md#step3b-configure-vault-authentication) for the full detail and prerequisites (Vault must already be deployed and unsealed, with its admin token in Secrets Manager at `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN`).

### Step2d. Execute CD Workflow

Go to **Actions → DPN CD - REST Federator Gateway → Run workflow** (`dpn-rest-federator-cd.yml`), and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02` (default `dpn01`) |
| `cloud` | `aws` (default) |
| `imageTag` | The image tag pushed in Step2a |
| `imageRepository` | Optional. Image path after `ghcr.io/energy-dsi/` (e.g. `1.0.1/dpn-rest-federator-server`). Leave blank to use `<IMAGE_REGISTRY>/dpn-rest-federator-server` from the config JSON |

The workflow runs **deploy-redis** (Helm release `dpn-redis`) then **deploy-rest-federator** (Helm release `dpn-rest-federator`), both into the config JSON's `NAMESPACE`. On AWS, **deploy-rest-federator** additionally provisions the `dpn-rest-federator-secrets-role` IAM role and seeds the `BACKEND_API_KEY`/`VAULT_TRUSTSTORE_PASSWORD` placeholders (idempotent — safe to re-run), then fetches the Vault truststore password and the AppRole `role-id` from Secrets Manager before running **Helm Lint + Dry Run** and **Helm Deploy**.

### Step2e. Verify CD Workflow

```bash
kubectl get pods -n <namespace>
kubectl rollout status deployment/dpn-rest-federator-redis-1 -n <namespace>   # redisCache.name, e.g. -2 on dpn02
kubectl logs -f dpn-rest-federator-server-1-XXXXXXXXX -n <namespace>
kubectl get svc -n <namespace>   # confirm the gateway's internal NLB IP
kubectl get hpa -n <namespace>   # confirm the HPA picked up the deployment
```

The kubectl logs should not show any `[error]` messages if the deployment is successful.

> **Rollback and uninstall:** `dpn-redis` and `dpn-rest-federator` are selectable releases in the central **DPN Rollback - All Components Pipelines** workflow (`dpn-rollback-all-components.yml`, `releaseName` input), and `redis`/`rest-federator` are selectable component types in **DPN Uninstall - All components Pipelines** (`dpn-uninstall-all-components.yml`, `componentType` input). See [Rollback Procedures](../04-rollback/04-rollback-procedures.md) and [Uninstall and Decommissioning](../05-uninstall/05-uninstall-decommissioning.md).

---

## Step3: Troubleshooting

### Invalid Keystore/Truststore Password

A common error caused by a password mismatch. Follow the Certificate Manager troubleshooting steps for this issue — the REST Federator Gateway shares the same Vault-sourced keystore/truststore material.

### Pod CrashLoop on First Deploy — Empty Truststore Password

If the pod fails immediately with a PKCS12/JKS load error on truststore construction, `certificate-manager-secrets` most likely didn't exist in the namespace when this chart was rendered — the config's `vault.truststore.password` is resolved via a Helm `lookup` against that secret at render time, not read live at pod start-up. Deploy Certificate Manager first, then re-run `dpn-rest-federator-cd.yml` so the config is re-rendered with the real password.

### 403 from the Backend

If the gateway returns `403` on every request, confirm the caller's product subscription and allowed-path configuration in the Management Node, and that the caller's certificate hasn't been revoked (OCSP check). See the configuration guide's [Overview](../02-configuration/06-configure-dpn-rest-federator-gateway.md#overview) for the full authorization flow.

### HPA Not Scaling

Confirm the metrics-server (or equivalent) is installed in the cluster — `hpa.enabled: true` renders the `HorizontalPodAutoscaler`, but it can only act on CPU/memory utilisation targets if a metrics source is available. `kubectl describe hpa dpn-rest-federator-server-hpa -n <namespace>` shows the current vs. target utilisation and any scaling events.

---

## Reference: Container Images Used

DPN REST Federator Gateway custom images are found in GHCR with the following names:

| Image Name | GHCR Path | Tag |
|---|---|---|
| REST Federator Server | `<IMAGE_REGISTRY>/dpn-rest-federator-server` (e.g. `ghcr.io/energy-dsi/1.0.1/dpn-rest-federator-server`) | `<version>` |

The REST Federator Gateway's 3rd party platform image is set in the `dpn-redis` chart's values files rather than pulled from GHCR:

| Purpose | Image (`redisCache.image.repository:tag`) |
|---|---|
| Redis | `redis:7.4-alpine` |

There is no separate GHCR-specific workflow to run — [Step2d](#step2d-execute-cd-workflow) above already deploys from these images by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
