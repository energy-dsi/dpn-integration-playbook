# DPN Vault Service Installation Process

This document covers the installation of the **DPN HashiCorp Vault service** into a single target environment on Azure Kubernetes Service (AKS).

> **Full instructions live in the configuration guide.** The end-to-end Vault flow — prerequisites, the values/config to populate, the deployment pipelines, post-deployment auto-unseal, and verification — is documented in one place:
>
> **[Configure DPN Vault Service](../02-configuration/01-configure-dpn-vault-service.md)**
>
> This installation page is a quick-reference summary that points to that guide.

---
## Containerized Deployment Using DSI Provided Container Images


This section covers deployment using the **pre-built container image** published by DSI to `ghcr.io/energy-dsi`. Organisations using this approach pull the DSI-provided image directly rather than building from source via CI pipelines. 

---

### DSI Provided Image Inventory

#### Vault Service Image

| Image Name | GHCR Path | Tag |
|---|---|---|
| HashiCorp Vault | `ghcr.io/energy-dsi/vault` | `<latest or DSI provided stable version>` |

#### Platform & Third-Party Images

The Vault service depends on the following platform image which should already be available from the DPN Federator Certificate Manager deployment:

| Purpose | GHCR Path |
|---|---|
| Certificate Manager | `ghcr.io/energy-dsi/dpn-certificate-manager:<latest or DSI provided stable version>` |

> **Note:** Vault is deployed as a standalone service. The Certificate Manager is a separate component that connects to Vault for certificate lifecycle management — it is not bundled in the Vault image itself.

---

### Verify Image Pull ability

Confirm the cluster nodes have outbound HTTPS access to `ghcr.io`, then test a pull:

```bash
kubectl run ghcr-pull-test --rm -it \
  --image=ghcr.io/energy-dsi/vault: \
  --namespace= \
  --command -- echo "Image pull successful"
```

No `imagePullSecrets` are needed if images are public.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 15-May-2026 | DSI Assurance    | Draft  | V0.1.0 |
