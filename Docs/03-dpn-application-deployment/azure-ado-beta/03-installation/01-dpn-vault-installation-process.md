# DPN Vault Service Installation Process

This document covers the installation of the **DPN HashiCorp Vault service** into a single target environment on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Vault flow — prerequisites, the values/config to populate, the deployment pipelines, post-deployment auto-unseal, and verification — is documented in one place:

**[Configure DPN Vault Service](../02-configuration/01-configure-dpn-vault-service.md)**
This installation page is a quick-reference summary that points to that guide.

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

Create a CD pipeline from the following yaml file. The CD Pipeline is already pointing to GHCR repository. This CD pipeline fetches the latest image. In case Organisation need to use a specific version then it should be modified inside the CD pipeline.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-vault-https-ghcr-cd.yaml
```
The CD Pipeline would require the following run time parameters. 

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |
| `Vault Image Tag` | Provides the release version or image tag to be pulled from GHCR , default is 1.16 |

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

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
