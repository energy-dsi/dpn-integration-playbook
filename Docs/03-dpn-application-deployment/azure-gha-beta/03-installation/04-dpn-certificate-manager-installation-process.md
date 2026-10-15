Release : 2.1.0 - Oct 2026

# DPN Certificate Manager Installation Process

This document covers the installation of the **DPN Federator Certificate Manager (CLM)** into a single target environment on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Certificate Manager flow — overview, prerequisites, the values/secrets to populate, deployment, and post-deployment verification — is documented in one place:

**[Configure DPN Certificate Manager](../02-configuration/04-configure-dpn-certificate-manager.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault.** The Certificate Manager cannot run until the DPN HashiCorp Vault service is deployed, initialised, and loaded with the certificate bundle. Complete [Vault installation](01-dpn-vault-installation-process.md) first.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CD](#step2-execute-cd)
  - [Step2a. Configure GHCR Image Access](#step2a-configure-ghcr-image-access)
  - [Step2b. Execute CD Workflow](#step2b-execute-cd-workflow)
  - [Step2c. Verify CD Workflow](#step2c-verify-cd-workflow)
- [Step3: Troubleshooting](#step3-troubleshooting)
  - [Invalid Keystore/Trustore Password](#invalid-keystoretrustore-password)
  - [PKIX Certificate validation error](#pkix-certificate-validation-error)
  - [401 Unauthorised error from DSM Auth endpoint](#401-unauthorised-error-from-dsm-auth-endpoint)
  - [Pod Fails to Trust Vault's HTTPS Endpoint (`VAULT_SSL_TRUST_STORE_PASSWORD` missing)](#pod-fails-to-trust-vaults-https-endpoint-vault_ssl_trust_store_password-missing)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager is deployed with a single GitHub Actions CD workflow, `dpn-gha-certificate-manager-cd.yaml`. It is a headless Spring Boot service that renews the DSM-signed certificate and persists it in Vault; the Certificate Manager and the Federator Gateway each build their own mTLS keystore/truststore in memory from that same Vault material — no shared file share is used, see [Configure DPN Certificate Manager](../02-configuration/04-configure-dpn-certificate-manager.md#overview).

The deployment CD workflow and the `certificate-manager` Helm chart both live in the `dpn-federator-certificate-manager` repository. The chart is at `charts/certificate-manager` (release `dpn-certificate-manager`), with values file `charts/certificate-manager/values/azure/<environment>-<cluster>.yaml`.

```text
dpn-federator-certificate-manager/
└── .github/
    └── workflows/
        └── dpn-gha-certificate-manager-cd.yaml
```

---

## Step1: Verify Prerequisites

Confirm the prerequisites before starting — see [Configure DPN Certificate Manager → Prerequisites](../02-configuration/04-configure-dpn-certificate-manager.md#step1-meet-the-prerequisites). 

In summary the following prerequisites must be met.

- Vault deployed/initialised/loaded with bootstrap certificate
- `cert-manager-truststore` and `tls-auth-secret` secrets present (both created by `dpn-gha-tls-cd.yml`; `cert-manager-truststore` alone is also created by `dpn-gha-vault-tls-bootstrap-cd.yaml`)
- Vault credentials ready — an AppRole identity from `dpn-gha-certificate-manager-role-id-creation.yaml` (Key Vault secret `VAULT-APPROLE-SECRET-ID`, with the printed `role_id` copied into `vault.appRole.roleId`), or the root token (`VAULT-TOKEN`) when `vault.authentication: TOKEN`
- Health monitoring service is running state and OTEL Collector healthy
- IDP client ID received from DSM
- Populated config JSON (`.github/config/azure/<environment>-<cluster>.json`) and values file for the `<environment>-<cluster>` combination, with `keyvault.enabled: true` set

**Note:** Organisations must review the CI/CD workflow code for the following. 

- If running your own CI, keep only the relevant build, unit test, and image-push steps — DSI's own CI examples include tool usage such as CheckMarx, SonarQube, and JFrog Xray that your organisation may not need
- The container image is appropriate and referred from GHCR repository unless Organisation plans to use a separate image repository on their own
- The config JSON's environment parameters are pointing to correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- The CD workflow is verified for the above prerequisites before execution


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

### Step2b. Execute CD Workflow

Go to **Actions → DPN CD - Certificate Manager → Run workflow** in `dpn-federator-certificate-manager`, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `imageTag` | The Certificate Manager image tag to deploy (required, no default) |
| `imageRepository` | Optional — overrides `image.repository` for this run only (path after `ghcr.io/energy-dsi/`) — leave blank to use the environment's configured repository |

On success, the deployed image digest is captured as the `deployed-image-digest` workflow artifact.

> **No `--wait`/`--timeout` on `helm upgrade` for this path.** Long-lived watches against the AKS API from the self-hosted runner were unreliable and timed out even when the rollout had actually completed. The Deploy and rolling-restart steps instead fire the Helm/kubectl command without waiting, then poll `kubectl rollout status --timeout=60s` up to five times with a short pause between attempts, printing `kubectl describe`/PVC/`SecretProviderClass`/namespace-events diagnostics if all five attempts fail.

---

### Step2c. Verify CD Workflow

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

To roll back or remove `dpn-certificate-manager` and/or `vault-https`, use `dpn-gha-certificate-manager-rollback.yaml` (**DPN Rollback - Certificate Manager**) or `dpn-gha-certificate-manager-uninstall.yaml` (**DPN Uninstall - Certificate Manager**) with `cloud: azure` (both default to `aws`) — see [Rollback Procedures, Part 3](../04-rollback/04-rollback-procedures.md#part-3--dpn-federator-certificate-manager-rollback) and [Uninstall and Decommissioning, Part 3](../05-uninstall/05-uninstall-decommissioning.md#part-3--uninstall-dpn-federator-certificate-manager).

---

## Step3: Troubleshooting

While working with the Federator Certificate Manager some common problem may arise. These are given below.

### Invalid Keystore/Trustore Password

This is a common known error occuring due to password mismatch. Confirm that `/tls/keystore.p12` and `/tls/truststore.p12` files in the dpn-certificate-manager kubernettes container are in sync with the loaded certificates in Hashicorp vault by checking their timestamps. If not delete the files from inside the container.

### PKIX Certificate validation error

Sometimes there could be some sync issue between certificate, ca-chain and key-pair files in the hashicorp vault which can lead to the `PKIX certificate validation` error. In that case please refresh/resync the certificates in vault by downloading a bootstrap bundle from DSM and uploading it again to vault. Also make sure to delete existing contents from vault before uploading the bootstrap certificates.

### 401 Unauthorised error from DSM Auth endpoint

Sometimes the certificate entries in the management-node could get out of sync with the certificates in vault leading to the 401 error from IDP endpoint. In that case please refresh/resync the certificates in vault by downloading a bootstrap bundle from DSM and uploading it again to vault. Also make sure to delete existing contents from vault before uploading the bootstrap certificates.

### Pod Fails to Trust Vault's HTTPS Endpoint (`VAULT_SSL_TRUST_STORE_PASSWORD` missing)

The app reads the truststore password as `VAULT_SSL_TRUST_STORE_PASSWORD` — not `SPRING_CLOUD_VAULT_SSL_TRUST_STORE_PASSWORD`. The Deployment sets it (and `OTEL_TRUSTSTORE_PASSWORD`) directly from the `tls-auth-secret` Kubernetes secret, key `TRUSTSTORE_PASSWORD`, which `dpn-gha-tls-cd.yml` creates. It does not come from the `SecretProviderClass` or `certificate-manager-secrets`. If Vault TLS handshakes fail at startup, confirm `tls-auth-secret` exists in the namespace and that its password matches the `cert-manager-truststore` it was created with:

```bash
kubectl get secret tls-auth-secret -n <namespace> -o jsonpath='{.data.TRUSTSTORE_PASSWORD}' | base64 -d
```

---

Federator Certificate Manager custom image is found in GHCR with following name

| Image Name | GHCR Path | Tag |
|---|---|---|
| dpn-federator-certificate-manager | `ghcr.io/energy-dsi/dpn-federator-certificate-manager` | `e.g. 2.0.0` |

There is no separate GHCR-specific workflow to run — [Step2b](#step2b-execute-cd-workflow) above already deploys from this image by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| Oct-2026    | DSI Assurance    | Final  | V1.0.0  |
