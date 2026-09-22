# DPN Certificate Manager Installation Process

This document covers the installation of the **DPN Federator Certificate Manager (CLM)** into a single target environment on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Certificate Manager flow — overview, prerequisites, the values/secrets to populate, deployment, and post-deployment verification — is documented in one place:

**[Configure DPN Certificate Manager](../02-configuration/03-configure-dpn-certificate-manager.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault.** The Certificate Manager cannot run until the DPN HashiCorp Vault service is deployed, initialised, and loaded with the certificate bundle. Complete [Vault installation](01-dpn-vault-installation-process.md) first.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CI/CD](#step2-execute-cicd)
  - [Step2a. CI (component source repository)](#step2a-ci-component-source-repository)
  - [Step2b. Configure GHCR Image Access](#step2b-configure-ghcr-image-access)
  - [Step2c. Execute CD Workflow](#step2c-execute-cd-workflow)
  - [Step2d. Verify CD Workflow](#step2d-verify-cd-workflow)
- [Step3: Troubleshooting](#step3-troubleshooting)
  - [Invalid Keystore/Trustore Password](#invalid-keystoretrustore-password)
  - [PKIX Certificate validation error](#pkix-certificate-validation-error)
  - [401 Unauthorised error from DSM Auth endpoint](#401-unauthorised-error-from-dsm-auth-endpoint)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager is deployed with a single GitHub Actions CD workflow, `dpn-certificate-manager-cd.yml`, in `dpn-containerised-deployment-service`. It is a headless Spring Boot service that renews the DSM-signed certificate and persists it in Vault; the Certificate Manager and the Federator Gateway each build their own mTLS keystore/truststore in memory from that same Vault material — no shared file share is used.

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        └── dpn-certificate-manager-cd.yml
```
---

## Step1: Verify Prerequisites

Confirm the prerequisites before starting — see [Configure DPN Certificate Manager → Prerequisites](../02-configuration/03-configure-dpn-certificate-manager.md#step1-meet-the-prerequisites). 

In summary the following prerequisites must be met.

- Vault deployed/initialised/loaded with bootstrap certificate
- `cert-manager-truststore` secret present
- Vault credentials ready — `VAULT-TOKEN` (root token) or an AppRole identity from `dpn-certificate-manager-role-id-creation.yml`, plus `TRUSTSTORE-PASSWORD` (renamed from `VAULT-TRUSTSTORE-PASSWORD` — see [Configure DPN Certificate Manager, Step3a](../02-configuration/03-configure-dpn-certificate-manager.md#step3a-set-up-helm-values))
- Health monitoring service is running state and OTEL Collector healthy
- IDP client ID received from DSM
- Populated config JSON and values file for the `<environment>-<cluster>` combination

**Note:** Organisations must review the CI/CD workflow code for the following. 

- If running your own CI, keep only the relevant build, unit test, and image-push steps — DSI's own CI examples include tool usage such as CheckMarx, SonarQube, and JFrog Xray that your organisation may not need
- The container image is appropriate and referred from GHCR repository unless Organisation plans to use a separate image repository on their own
- The config JSON's environment parameters are pointing to correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- Both CI and CD are verified for the above prerequisites before execution


---

## Step2: Execute CI/CD

### Step2a. CI (component source repository)

CI (build, test, security scan, and image push to GHCR) runs as GitHub Actions workflows in the `dpn-federator-certificate-manager` source repository itself — separately from the CD workflow below. Where already migrated, this repository ships `maven.yml` (build/test), `oss-checker.yml` (license/dependency scan), and `docker-ghcr.yml` (build and push the image to GHCR). Once CI pushes a new tag, note it for use as `imageTag` in Step2c.

```text
dpn-federator-certificate-manager:<image tag>
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

### Step2c. Execute CD Workflow

Go to **Actions → DPN CD - Certificate Manager → Run workflow** in `dpn-containerised-deployment-service`, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `imageTag` | The image tag pushed in Step2a |

On success, the deployed image digest is captured as a workflow artifact.

---

### Step2d. Verify CD Workflow

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begin. 

```bash
kubectl get pods -n <namespace> # check for dpn-certificate-manager-XXXXXX
kubectl logs -f dpn-certificate-manager-XXXXXXXXX
```
The kubectl logs should not showcase any [error] message if the deployment is successful. 

---

**Certificate material available in Vault** — the keystore/truststore are built in memory, so there are no P12 files on disk to inspect; confirm the material itself instead:

```bash
kubectl -n <namespace> logs -f deployment/dpn-certificate-manager | grep -i "keystore\|vault"
# expect no Vault authentication or "keystore" build errors
```

**First-run note (Vault):** On the very first start, the log-verification step may show Vault access errors if Vault configuration has not fully completed. Ensure Vault is initialised and the bundle is loaded, then restart the Certificate Manager pod:

```bash
kubectl rollout status deployment/dpn-certificate-manager -n <namespace> --timeout=300s
kubectl get pods -n <namespace> -l app=dpn-certificate-manager -o wide
```

---

## Step3: Troubleshooting

While working with the Federator Certificate Manager some common problem may arise. These are given below.

### Invalid Keystore/Trustore Password

This is a common known error occuring due to password mismatch. Confirm that `/tls/keystore.p12` and `/tls/truststore.p12` files in the dpn-certificate-manager kubernettes container are in sync with the loaded certificates in Hashicorp vault by checking their timestamps. If not delete the files from inside the container.

### PKIX Certificate validation error

Sometimes there could be some sync issue between certificate, ca-chain and key-pair files in the hashicorp vault which can lead to the `PKIX certificate validation` error. In that case please refresh/resync the certificates in vault by downloading a bootstrap bundle from DSM and uploading it again to vault. Also make sure to delete existing contents from vault before uploading the bootstrap certificates.

### 401 Unauthorised error from DSM Auth endpoint

Sometimes the certificate entries in the management-node could get out of sync with the certificates in vault leading to the 401 error from IDP endpoint. In that case please refresh/resync the certificates in vault by downloading a bootstrap bundle from DSM and uploading it again to vault. Also make sure to delete existing contents from vault before uploading the bootstrap certificates.

---

Federator Certificate Manager custom image is found in GHCR with following name

| Image Name | GHCR Path | Tag |
|---|---|---|
| dpn-certificate-manager-service | `ghcr.io/energy-dsi/dpn-certificate-manager` | `e.g. 1.0.0` |

There is no separate GHCR-specific workflow to run — [Step2c](#step2c-execute-cd-workflow) above already deploys from this image by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 31-Jul-2026 | DSI Assurance    | Final  | V1.0.0 |
