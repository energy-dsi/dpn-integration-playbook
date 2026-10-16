# DPN Vault Service Installation Process

This document covers the installation of the **DPN HashiCorp Vault service** into a single target environment on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Vault flow — prerequisites, the values/config to populate, the deployment pipelines, post-deployment auto-unseal, and verification — is documented in one place:

**[Configure DPN Vault Service](../02-configuration/01-configure-dpn-vault-service.md)**
This installation page is a quick-reference summary that points to that guide.

---

## Table of Contents

- [Certificate Bootstrapping and Edge Certificates](#certificate-bootstrapping-and-edge-certificates)
  - [Bootstrapping the Federator Certificate](#bootstrapping-the-federator-certificate)
  - [Edge Certificate (Server Sign Certificate)](#edge-certificate-server-sign-certificate)
- [Containerized Deployment Using DSI Provided Container Images](#containerized-deployment-using-dsi-provided-container-images)
  - [Configure GHCR Image Access](#configure-ghcr-image-access)
  - [Verify Image Pull Capability](#verify-image-pull-capability)
  - [Execute CD Pipeline](#execute-cd-pipeline)
  - [Verify CD Pipeline](#verify-cd-pipeline)
- [Review Notes](#review-notes)

---

## Certificate Bootstrapping and Edge Certificates

Every DPN node's certificate is generated and signed from the DSI portal's Certificate Management page,see the [DSI Certificate Management UI Guide](../../../05-dpn-user-interfaces/10-dsi-certificate-management-ui-operations.md) for the full walkthrough. This section places the two certificate paths in the context of the Vault installation.

### Bootstrapping the Federator Certificate

1. Generate a key pair and `.csr` file on the DPN node (`openssl genrsa` + `openssl req`).
2. Request a **Federator bootstrap certificate** (portal `Type: BOOTSTRAP`, short-lived) from the DSI portal's Certificate Management page — see [DSI Certificate Management UI Guide, Step 6](../../../05-dpn-user-interfaces/10-dsi-certificate-management-ui-operations.md#3-walkthrough-issuing-a-certificate).
3. Upload the signed bundle (`bootstrap.key`, `certificate.pem`, `ca-chain.pem`) to Azure DevOps Secure Files and load it into Vault — see [Configure DPN Vault Service, Step 3C](../02-configuration/01-configure-dpn-vault-service.md#step-3c-configure-certificate-bundle-vault-load-bundle-cd).

Once installed, the Certificate Manager renews this certificate automatically — no manual re-bootstrap is required afterwards.

### Edge Certificate (Server Sign Certificate)

For organisations that front their DPN deployment with an edge proxy (e.g. Cloudflare) instead of exposing the Federator directly:

1. Generate a **server sign certificate** CSR on the edge component, requested with a **60-day TTL** longer than the Federator bootstrap certificate's short-lived default, since this certificate fronts the edge listener rather than bootstrapping the Federator.
2. Request an **Edge component certificate** from the DSI portal's Certificate Management page — see [DSI Certificate Management UI Guide, Step 6](../../../05-dpn-user-interfaces/10-dsi-certificate-management-ui-operations.md#3-walkthrough-issuing-a-certificate).
3. Install the signed bundle at the edge component.

Unlike the Federator bootstrap certificate, the edge certificate is **not** renewed automatically — it must be manually reinstated at the edge on every renewal.

---

## Containerized Deployment Using DSI Provided Container Images

This section covers deployment using **custom and 3rd party open source container images** published by DSI to `ghcr.io/energy-dsi`. Organisations using this approach pull DSI-provided images directly rather than building from source via CI pipelines.

The DPN Hashicorp Vault service 3rd party platform images are found in GHCR with following names

| Purpose | GHCR Path |
|---|---|
| Vault | `ghcr.io/energy-dsi/vault:<latest or DSI provided stable version>` |


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

There is **no separate GHCR-specific pipeline file** for Vault — the same `vault-https-cd.yaml` pipeline is used for both ACR-built and GHCR-sourced images. Point it at the GHCR image by setting `image.repository: ghcr.io/energy-dsi/vault` in `charts/vault-https/values-<env>-<cluster>.yaml` (see [Configure DPN Vault Service, Step 2b](../02-configuration/01-configure-dpn-vault-service.md#step-2b-vault-helm-values--chartsvault-httpsvalues-env-clusteryaml)), then create/run the CD pipeline from:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── vault-https-cd.yaml
```

The CD Pipeline requires the following runtime parameters — see [Configure DPN Vault Service, Step 3B](../02-configuration/01-configure-dpn-vault-service.md#step-3b-configuration-to-initialise-vault-vault-https-cd) for full details:

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | A given Service Connection able to deploy the services |
| `environment` | Environment abbreviation |
| `dpnCluster` | `dpn01` (DSI provides two DPN configurations per environment. Organisations may keep only one, such as `dpn01`, to run a single DPN cluster) |
| `vaultImageTag` | Release version or image tag to be pulled from GHCR, default `1.16` |
| `testMode` | Leave `false` for a normal deployment |
| `runVaultInit` | `true` to also run Vault init (KV v2 + audit logging) on this run |
| `storeRootTokenInAkv` | `true` on the first deploy, so the bundle-load pipeline can read the root token |

Execute this CD Pipeline to perform deployment.

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
| May-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 | 
