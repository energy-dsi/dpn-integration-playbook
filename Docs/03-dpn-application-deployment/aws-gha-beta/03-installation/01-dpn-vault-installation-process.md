# DPN Vault Service Installation Process

This document covers the installation of the **DPN HashiCorp Vault service** into a single target environment on Amazon Elastic Kubernetes Service (EKS).

**Full instructions live in the configuration guide.** The end-to-end Vault flow — prerequisites, the values/config to populate, the deployment pipelines, post-deployment auto-unseal, and verification — is documented in one place:

**[Configure DPN Vault Service](../02-configuration/01-configure-dpn-vault-service.md)**
This installation page is a quick-reference summary that points to that guide.

---

## Table of Contents

- [Containerized Deployment Using DSI Provided Container Images](#containerized-deployment-using-dsi-provided-container-images)
  - [Configure GHCR Image Access](#configure-ghcr-image-access)
  - [Verify Image Pull Capability](#verify-image-pull-capability)
  - [Execute CD Pipeline](#execute-cd-pipeline)
  - [Verify CD Pipeline](#verify-cd-pipeline)
- [Review Notes](#review-notes)

---

## Containerized Deployment Using DSI Provided Container Images

This section covers deployment using **custom and 3rd party open source container images** published by DSI to `ghcr.io/energy-dsi`. Organisations using this approach pull DSI-provided images directly rather than building from source via CI pipelines.

The DPN Hashicorp Vault service 3rd party platform images are found in GHCR with following names

| Purpose | GHCR Path |
|---|---|
| Vault | `ghcr.io/energy-dsi/vault:<latest or DSI provided stable version>` (the repository is set by `image.repository` in `charts/vault-https/values/aws/<environment>-<cluster>.yaml` in the `dpn-federator-certificate-manager` repository, and matches `IMAGE_REGISTRY` in `.github/config/aws/<environment>-<cluster>.json`) |


---

### Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`.

Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably. Unauthenticated pulls are subject to strict rate limits and may fail in automated environments.

Create a GitHub Personal Access Token with `read:packages` scope. Once the token is available, create a kubernetes secret from the same.This secret will be used during the image pull.

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

---

### Verify Image Pull Capability

Confirm the cluster nodes have outbound HTTPS access to `ghcr.io`, then test a pull:

```bash
kubectl run ghcr-pull-test --rm -it \
  --image=ghcr.io/energy-dsi/vault:<version> \
  --namespace=<namespace> \
  --command -- echo "Image pull successful"
```

---

### Execute CD Pipeline

Trigger the `dpn-gha-vault-https-cd.yaml` GitHub Actions workflow from the `dpn-federator-certificate-manager` repository. It's already pointing at the GHCR repository by default and fetches the image tag you specify — no separate GHCR-specific workflow variant exists. It deploys the `vault-https` chart from `charts/vault-https` (release `vault-https`) with the values file `charts/vault-https/values/aws/<environment>-<cluster>.yaml`.

```text
dpn-federator-certificate-manager/
└── .github/
    └── workflows/
        └── dpn-gha-vault-https-cd.yaml
```

> **Run the TLS workflow first.** The Vault TLS certificate/key must already be in AWS Secrets Manager (`dpn/<environment>-<cluster>/vault-https/VAULT_TLS_CERT` / `VAULT_TLS_KEY`), published by `dpn-gha-tls-cd.yml` — see [Configure DPN Vault Service, Step 3A](../02-configuration/01-configure-dpn-vault-service.md#step-3a-configure-vault-tls-dpn-tls-cdyaml).

Go to **Actions → DPN CD - Vault HTTPS → Run workflow** and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluster) |
| `cloud` | `aws` |
| `vaultImageTag` | Release version or image tag to pull from GHCR — default `1.16` |
| `vaultImageRepository` | Optional — overrides `image.repository` for this run only (path after `ghcr.io/energy-dsi/`, e.g. `1.0.1/vault`) — leave blank to use the environment's configured repository |
| `runVaultInit` | Enable KV v2 + audit logging — default `true`, safe to re-run |
| `storeRootTokenInSecretsBackend` | Store the Vault root token in the cloud secrets backend — on AWS, the Secrets Manager secret `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN` (default `false`; set `true` on the first deploy, because the bundle-load and AppRole setup workflows read the token from there). See [Configure DPN Vault Service, Step 3B](../02-configuration/01-configure-dpn-vault-service.md#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml) |

> **Prerequisite:** AWS KMS auto-unseal must already be configured — see [Configure DPN Vault Service, Step 1](../02-configuration/01-configure-dpn-vault-service.md#step-1-prerequisites-before-vault-can-be-deployed) — otherwise this workflow's Vault Init step will fail against a sealed Vault.

Run the workflow to perform deployment.

---

### Verify CD Pipeline

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begin. 

```bash
kubectl get pods -n <namespace> # check for dpn-vault-https-XXXXXX
kubectl logs -f dpn-vault-https-XXXXXXXXX
```
The kubectl logs should not showcase any [error] message if the deployment is successful. 

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
