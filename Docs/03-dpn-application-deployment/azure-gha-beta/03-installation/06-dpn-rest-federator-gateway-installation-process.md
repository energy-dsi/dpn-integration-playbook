# DPN REST Federator Gateway Installation Process

This document covers the installation of the **DPN REST Federator Gateway** (the REST/HTTPS federation gateway and its `dpn-redis` cache) into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end REST Federator Gateway flow — overview, prerequisites, secrets, the values to populate, Vault AppRole setup, autoscaling, and deployment — is documented in one place:

**[Configure DPN REST Federator Gateway](../02-configuration/06-configure-dpn-rest-federator-gateway.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault and the Certificate Manager.** Complete [Vault installation](01-dpn-vault-installation-process.md) and [Certificate Manager installation](04-dpn-certificate-manager-installation-process.md) first — the gateway reads its certificate material and keystore/truststore passwords directly from Vault, and its rendered config depends on the `certificate-manager-secrets` Kubernetes secret already existing in the namespace at deploy time (see the configuration guide's [Step2](../02-configuration/06-configure-dpn-rest-federator-gateway.md#step2-configure-secrets)).

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CD](#step2-execute-cd)
  - [Step2a. Configure GHCR Image Access](#step2a-configure-ghcr-image-access)
  - [Step2b. One-Time Vault AppRole Setup](#step2b-one-time-vault-approle-setup)
  - [Step2c. Execute CD Workflow](#step2c-execute-cd-workflow)
  - [Step2d. Verify CD Workflow](#step2d-verify-cd-workflow)
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

```text
root/
└── .pipelines/
  └── github-actions-pipelines/
      └── workflows/
          ├── dpn-gha-rest-federator-cd.yml
          └── dpn-gha-rest-federator-role-id-creation.yaml
```

Key points, detailed in the configuration guide:
- Unlike the gRPC Federator Gateway, this component authenticates to Vault with **AppRole**, not the root token — set up once per environment/cluster via [Step2b](#step2b-one-time-vault-approle-setup) before the first deploy.
- The backend API key and the Vault truststore password come from **Azure Key Vault** (`KEY_VAULT_NAME`), read at deploy time via `az keyvault secret show` and a dedicated `ServiceAccount`/`SecretProviderClass` in the chart. Unlike the AWS path, this CD workflow does **not** create the Key Vault entries automatically — `BACKEND_API_KEY` and `VAULT-TRUSTSTORE-PASSWORD` must already exist in Key Vault before the first deploy.
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
- **Vault AppRole configured for this component** — run the one-time workflow in [Step2b](#step2b-one-time-vault-approle-setup) before the first deploy

**Note:** Organisations must review the CI/CD workflow code for the following.

- If running your own CI, keep only the relevant build, unit test, and image-push steps
- The container image is appropriate and referred from GHCR repository unless the Organisation plans to use a separate image repository of their own
- The config JSON's environment parameters are pointing to the correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required firewall rules are applied
- The CD pipeline is verified for the above prerequisites before execution

---

## Step2: Execute CD

### Step2a. Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`. Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably.

Create a GitHub Personal Access Token with `read:packages` scope, then create a Kubernetes secret from it:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

### Step2b. One-Time Vault AppRole Setup

**Run this once per `<environment>-<cluster>` combination, before the first `dpn-gha-rest-federator-cd.yml` run**, and again whenever the AppRole `secret-id` needs rotating.

Go to **root/.pipelines/github-actions-pipelines/workflows/dpn-gha-rest-federator-role-id-creation.yaml**, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |

This enables the `approle` Vault auth method, writes the `rest-federator-policy`, creates/updates the `rest-federator` AppRole role, and publishes the generated `secret-id` to **Azure Key Vault** as `VAULT-APPROLE-SECRET-ID-REST-FEDERATOR` (stamped with a +355-day expiry to satisfy the governance policy requiring Key Vault secrets to carry a maximum validity period) and the `role-id` alongside it. Unlike the AWS path, the CD workflow does **not** fetch this `role-id` automatically on Azure — once the workflow completes, copy the `role-id` it prints in the run summary into the chart's Azure values file under `restFederatorServer.vault.appRole.roleId`, then redeploy. See [Configure DPN REST Federator Gateway, Step3b](../02-configuration/06-configure-dpn-rest-federator-gateway.md#step3b-configure-vault-authentication) for the full detail and prerequisites (Vault must already be deployed and unsealed, with its admin token in Key Vault as `VAULT-TOKEN`).

### Step2c. Execute CD Workflow

Go to following location to find the CD pipeline and execute on Github Runner

```text
root/
└── .pipelines/
  └── github-actions-pipelines/
      └── workflows/
          └── dpn-gha-rest-federator-cd.yaml
```

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `imageTag` | The image tag pushed in Step2a |

The workflow runs **deploy-redis** then **deploy-rest-federator**. On Azure, **deploy-rest-federator** fetches the Vault truststore password from Key Vault (`VAULT-TRUSTSTORE-PASSWORD`) before running Helm — the AppRole `role-id` is read from the checked-in values file (populated manually in [Step2b](#step2b-one-time-vault-approle-setup)) rather than fetched from a secrets backend. On success, the deployed image digest is captured as a workflow artifact.

### Step2d. Verify CD Workflow

```bash
kubectl get pods -n <namespace>
kubectl logs -f dpn-rest-federator-server-1-XXXXXXXXX
kubectl get svc -n <namespace>   # confirm the gateway's internal Load Balancer IP
kubectl get hpa -n <namespace>   # confirm the HPA picked up the deployment
```

The kubectl logs should not show any `[error]` messages if the deployment is successful.

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
| REST Federator Server | `ghcr.io/energy-dsi/dpn-rest-federator-server` | `<version>` |

The REST Federator Gateway's 3rd party platform images are found in GHCR with the following names:

| Purpose | GHCR Path |
|---|---|
| Redis | `ghcr.io/energy-dsi/redis:<latest or DSI provided stable version>` |

There is no separate GHCR-specific workflow to run — [Step2c](#step2c-execute-cd-workflow) above already deploys from these images by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
