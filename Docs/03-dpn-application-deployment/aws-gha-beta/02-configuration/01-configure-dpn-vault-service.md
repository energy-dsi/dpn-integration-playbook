# DPN Vault Service Configuration

This section describes how to configure **DPN HashiCorp Vault service**. HashiCorp Vault is the secret store used by DPN Certificate Manager to hold Intermediate CA, CA chain, key pair, certificate, and keystore/truststore passwords. These secrets are used to build the certificate P12 files for mutual TLS (mTLS).

DSI provides an **automated method** (GitHub Actions workflows in `dpn-containerised-deployment-service`) that generates the required CSR, certificate, and key material and configures Vault end to end — this is the only supported deployment method for this airgapped AWS path, run on the shared self-hosted GitHub Actions runner, the same way as the Azure airgap path.

> **Environment and cluster:** These instructions target one `<environment>`/`<cluster>` combination (`dev`/`test` × `dpn01`/`dpn02`). Substitute your actual values in:
>
> - config file `.github/config/aws/<environment>-<cluster>.json`
> - values file `<chart-dir>/values/aws/<environment>-<cluster>.yaml`
>
> Repeat the deployment once per environment/cluster combination you run — don't merge multiple environments into one file.

---

## Table of Contents

- [Overview](#overview)
- [Automated Vault Configuration](#automated-vault-configuration)
  - [Step 1: Prerequisites (before Vault can be deployed)](#step-1-prerequisites-before-vault-can-be-deployed)
  - [Step 2: Reference Configuration Data (populate before deployment)](#step-2-reference-configuration-data-populate-before-deployment)
    - [Step 2a. Environment config JSON](#step-2a-environment-config-json)
    - [Step 2b. Vault Helm values](#step-2b-vault-helm-values)
  - [Step 3: Deployment Configuration](#step-3-deployment-configuration)
    - [Step 3A: Configure Bootstrap Vault TLS (`dpn-vault-tls-bootstrap-cd.yml`)](#step-3a-configure-bootstrap-vault-tls-dpn-vault-tls-bootstrap-cdyml)
    - [Step 3B: Deploy and Initialise Vault (`dpn-vault-https-cd.yml`)](#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml)
    - [Step 3C: Configure Certificate Bundle (`dpn-vault-load-bundle-cd.yml`)](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml)
    - [Step 3D: Deploy Certificate Manager (`dpn-certificate-manager-cd.yml`)](#step-3d-deploy-certificate-manager-dpn-certificate-manager-cdyml)
  - [Step 3E: Configure AppRole Authentication (planned, not yet available)](#step-3e-configure-approle-authentication-planned-not-yet-available)
- [Appendix — AWS KMS auto-unseal configuration](#appendix--aws-kms-auto-unseal-configuration)
- [Review Notes](#review-notes)

---

## Overview

HashiCorp Vault stores the cryptographic material the Certificate Manager needs to establish mTLS with the DSI DSM and other DPNs. Certificate Manager reads and writes the following KV v2 paths under the `pki-client` mount:

| Path (`pki-client/node-net/client/…`) | Content | Written by |
|---------------------------------------|---------|------------|
| `keypair` | Client RSA private + public key | Bundle load (Step 3C) |
| `certificate` | DSM-signed client certificate | Bundle load (Step 3C) |
| `ca-chain` | CA chain from DSM | Bundle load (Step 3C) |
| `intermediate-ca` | Intermediate CA certificate | Certificate Manager (renewal) |
| `keystore-password` | Password for the generated `keystore.p12` | Certificate Manager |
| `truststore-password` | Password for the generated `truststore.p12` | Certificate Manager |

Vault serves over **HTTPS (TLS 1.2+)** internally and uses **AWS KMS auto-unseal** so it unseals itself on start-up — see [Appendix — AWS KMS auto-unseal configuration](#appendix--aws-kms-auto-unseal-configuration). DSI provides the community edition of the Vault container; organisations may substitute an enterprise edition per their licensing strategy.

Vault is deployed and configured entirely through **[Automated Vault Configuration](#automated-vault-configuration)** — four GitHub Actions workflows generate the TLS material, deploy and initialise Vault, load the certificate bundle, and deploy the Certificate Manager. There is no manual deployment path for this component.

### Certificate Lifecycle and Management

DPN-to-DPN and DPN-to-DSM communications are secured using mutual TLS (mTLS), meaning both parties in every connection must present a valid certificate to authenticate themselves. Each DPN therefore requires a DSI-issued certificate to participate in the network — without one, it cannot establish any connection with another DPN or with the DSM.

During initial DPN setup, a participant uploads a Certificate Signing Request (CSR) through the DSM user interface. The DSM signs the CSR and returns a bootstrap certificate bundle for download. The participant installs this bundle into their DPN's Vault via [Step 3C](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml), after which certificate renewal is handled automatically — the DPN manages its own certificate lifecycle without further manual intervention under normal operating conditions.

If a certificate expires before automatic renewal has taken place — for example due to the DPN being offline during the renewal window — the participant will need to return to the DSM user interface, upload a new CSR, and download a fresh bootstrap certificate to restore connectivity. As with the initial setup, the downloaded certificate bundle should be saved at the point of download since it cannot be retrieved from the platform again once the session ends.

Organisations should factor this recovery process into their operational runbooks so that certificate expiry does not result in extended loss of connectivity to the DSI network.

While the DSM is capable of issuing short-lived certificates and the DPN includes built-in capability to renew them automatically before expiry, the current certificate validity period is set to 60 days. This decision is driven by a known constraint affecting organisations that deploy their DPN behind Cloudflare or an equivalent reverse proxy or edge security layer. In such deployments, enterprise security policies may be configured to terminate mTLS at the Cloudflare boundary rather than passing it through end-to-end. Where mTLS is terminated at Cloudflare, the certificate installed at that layer is outside the DPN's automated renewal process — meaning that when a certificate is renewed by the DPN, the updated certificate must also be manually installed at the Cloudflare boundary. A shorter certificate lifetime would increase the frequency of this manual intervention. Setting the validity period to 60 days balances the security benefit of certificate rotation against the operational burden of manual installation at the proxy layer.

This constraint is under active review. Solutions have been identified that are expected to address 24 hrs certificate TTL back from 60 days while issuing a different certificate for proxy-terminated mTLS deployments. The additional long term TTL certificate to be provided from a different endpoint and serves only the purpose of client authentication at edge proxies for DPN. This longer TTL certificate can not be used for DSM authentication or any client certificate. This change is targeted for delivery in PI4.

_**Note:** Organisations operating DPNs behind Cloudflare or equivalent infrastructure should factor the current manual renewal process into their operational runbooks until this capability is available and also actively monitor the expiry of the certificate installed outside the DPN certificate manager component since DSI does not generate any alert on certificate expiry at this moment._

---

## Automated Vault Configuration

The automated flow uses four GitHub Actions workflows in `dpn-containerised-deployment-service`:

| Order | Workflow | Purpose |
|-------|----------|---------|
| 1 | `dpn-vault-tls-bootstrap-cd.yml` | Generate the Vault server TLS certificate/key + Certificate Manager truststore, and publish them to Key Vault and Kubernetes |
| 2 | `dpn-vault-https-cd.yml` | Deploy Vault via Helm, then initialise it and enable the KV v2 engine |
| 3 | `dpn-vault-load-bundle-cd.yml` | Load the DSM-signed client certificate bundle into Vault |
| 4 | `dpn-certificate-manager-cd.yml` | Deploy the Certificate Manager, which reads and renews certificates from Vault |

A fifth capability, **AppRole setup**, is planned but not yet available as a GitHub Actions workflow for this path — see [Step 3E](#step-3e-configure-approle-authentication-planned-not-yet-available).

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        ├── dpn-vault-tls-bootstrap-cd.yml
        ├── dpn-vault-https-cd.yml
        ├── dpn-vault-load-bundle-cd.yml
        └── dpn-certificate-manager-cd.yml
```

---

### Step 1: Prerequisites (before Vault can be deployed)

Ensure the following are in place **before** running any workflow:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **EKS cluster** provisioned and reachable | Target cluster for the deployment |
| 2 | **Namespaces, `efs-sc` StorageClass, `federator-server` ServiceAccount, `ghcr-pull-secret`** | See [Step2.3: EKS Namespace Configuration](00-common-dpn-configuration.md#step23-eks-namespace-configuration) |
| 3 | **AWS KMS key + IAM role for auto-unseal** | See [Appendix — AWS KMS auto-unseal configuration](#appendix--aws-kms-auto-unseal-configuration) — required for the pipeline path to work at all, since it has no interactive unseal step |
| 4 | **GitHub Actions OIDC role** for the AWS account (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role)) — the shared self-hosted runner already has `openssl`, `keytool`, `aws`, `kubectl`, and `helm` | No agent setup needed per environment |
| 5 | **Environment config and values files populated** | See [Step 2](#step-2-reference-configuration-data-populate-before-deployment) |
| 6 | **DSM-signed client bundle available** | The client private key, DSM-signed certificate, and CA chain — loaded in [Step 3C](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml) |

> **One-time setup:** Before running any workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration). In particular the workflows **do not create the namespace** — create it first (`kubectl create namespace <NAMESPACE>`), populate `.github/config/aws/<environment>-<cluster>.json`, and (for the bundle load) set the required GitHub Actions secrets.

---

### Step 2: Reference Configuration Data (populate before deployment)

Two files must be populated for each environment/cluster combination. **Use your own values — the examples below are placeholders only.**

#### Step 2a. Environment config JSON

The workflows resolve environment settings from `.github/config/aws/<environment>-<cluster>.json` (see [AWS Environment Configuration](00-common-dpn-configuration.md#step22-aws-environment-configuration)). Vault uses the following keys:

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `AWS_REGION` | Region hosting the infrastructure | `eu-west-2` |
| `AWS_ACCOUNT_ID` | AWS account ID | `<account-id>` |
| `EKS_CLUSTER` | EKS cluster name | `eks-dpn-<env>-<region>` |
| `NAMESPACE` | Kubernetes namespace | `ns-dpn-01` |
| `KEY_VAULT_NAME` | Azure Key Vault for secrets and certificates — still used cross-cloud, see [Step2.2](00-common-dpn-configuration.md#step22-aws-environment-configuration) | `kv-dpn-<env>-<region>-<seq>` |

#### Step 2b. Vault Helm values

Set the values below in your environment/cluster's values file. DSI proposes only these selective changes; other parameters may be customised if required.

```text
dpn-federator-cert-manager/
  └── charts/
        └── vault-https/
              ├── values.yaml                            <- Reference file; do not edit directly
              └── values/aws/<environment>-<cluster>.yaml <- Your environment overrides
```

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `image.repository` | Complete URL of the Vault image | `ghcr.io/energy-dsi/vault` |
| `image.tag` | Vault image tag (also overridable at runtime) | `1.16` |
| `namespace` | Kubernetes namespace | `ns-dpn-01` |
| `seal.awskms.region` | Region of the auto-unseal KMS key | `<AWS_REGION>` |
| `seal.awskms.kmsKeyId` | Auto-unseal KMS key alias/ARN | `alias/dpn-vault-unseal` |
| `storageClassName` | Persistent volume StorageClass | `efs-sc` |

> **Note:** Keep `replicaCount: 1` — Vault uses a `ReadWriteOnce` persistent volume. The Vault TLS certificate and key are **not** set here; they are generated and published in [Step 3A](#step-3a-configure-bootstrap-vault-tls-dpn-vault-tls-bootstrap-cdyml).

---

### Step 3: Deployment Configuration

Trigger the following workflows in order, via **Actions → &lt;workflow name&gt; → Run workflow** in `dpn-containerised-deployment-service`. Each resolves `.github/config/aws/<environment>-<cluster>.json` and the matching Helm values file automatically from the `environment`/`cluster`/`cloud` inputs.

#### Step 3A: Configure Bootstrap Vault TLS (`dpn-vault-tls-bootstrap-cd.yml`)

This workflow generates a Root CA, the Vault server certificate/key, and the Certificate Manager truststore in a single run, then publishes them to Key Vault and Kubernetes.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `country` | CSR subject Country (C) — default `GB` |
| `org` | CSR subject Organisation (O) — default `DSI` |
| `sans` | Comma-separated DNS SANs for the Vault URL. **Must include the internal Kubernetes DNS name**, e.g. `vault-https.<namespace>.svc.cluster.local` |
| `truststorePassword` | Password published to Key Vault as `VAULT-TRUSTSTORE-PASSWORD` — default `changeit` |

On completion it publishes:
- `VAULT-TLS-CERT`, `VAULT-TLS-KEY`, `VAULT-TRUSTSTORE-PASSWORD` → Azure Key Vault
- `truststore.jks` → Kubernetes secret `cert-manager-truststore`
- The full working set (including private keys) as a 1-day-retention workflow artifact — download and secure it, then delete the artifact

#### Step 3B: Deploy and Initialise Vault (`dpn-vault-https-cd.yml`)

This workflow deploys the `vault-https` Helm chart and runs: **Helm Lint + Dry Run** → **Helm Deploy** (`helm upgrade --install`) → **Vault HTTPS Seal Status Check** → **Vault Init** (runs `vault-init.sh` to enable the KV v2 engine at `pki-client` and audit logging).

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `vaultImageTag` | Vault image tag (default `1.16`) |
| `runVaultInit` | Run the init step (default `true`; idempotent — safe to re-run on an existing vault) |
| `storeRootTokenInAkv` | Store the Vault root token in Key Vault as `VAULT-TOKEN`. **Set `true` on the first deploy** — the bundle-load workflow (Step 3C) always needs it |

> **Auto-unseal is what makes this workflow viable — set it up before this step, not after.** The pipeline has no interactive unseal step; if Vault comes back sealed, the Vault Init step will simply fail. Configure **AWS KMS auto-unseal** (`seal.awskms.*` in the chart's AWS values — [Step 2b](#step-2b-vault-helm-values)) before running this workflow; see [Appendix](#appendix--aws-kms-auto-unseal-configuration) for the exact KMS key/IAM role setup.
>
> The init step publishes the full init output (**root token + recovery keys**) as the `vault-init-output-<environment>-<cluster>` workflow artifact (1-day retention). Download it, store the recovery keys securely per Organisation's secrets policy, then delete the artifact. There is no ADO-style approval gate on this workflow by default — if you want a manual sign-off before this step runs, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

#### Step 3C: Configure Certificate Bundle (`dpn-vault-load-bundle-cd.yml`)

This workflow needs the DSM client bundle set as **GitHub Actions secrets** (repository or environment level) using these exact names:

| Secret | Content |
|-------------|---------|
| `VAULT_KEY` | Your DPN client **private key** |
| `CERTIFICATE_PEM` | The **DSM-signed certificate** |
| `CA_CHAIN_PEM` | The **CA chain** from DSM |

The workflow reads the Vault root token from Key Vault (`VAULT-TOKEN`, placed by Step 3B), resolves the Vault pod, and writes `pki-client/node-net/client/{keypair,certificate,ca-chain}`.

`workflow_dispatch` inputs: `environment`, `cluster`, `cloud`.

> **Prerequisites for this step:**

- Vault deployed and unsealed (Step 3B)
- `VAULT-TOKEN` present in Key Vault (from Step 3B with `storeRootTokenInAkv: true`)
- KV v2 enabled at `pki-client`
- Above secrets set in GitHub Actions

#### Step 3D: Deploy Certificate Manager (`dpn-certificate-manager-cd.yml`)

See [Configure DPN Certificate Manager](03-configure-dpn-certificate-manager.md) for the full configuration and workflow inputs for this step.

---

### Step 3E: Configure AppRole Authentication (planned, not yet available)

The Vault root token is a single, all-privileges credential — every component that needs it (Certificate Manager, Federator Gateway) ends up holding full access to Vault. **AppRole** is the recommended alternative: each component authenticates with its own scoped identity (a `role_id` plus a `secret_id`) and receives a short-lived, auto-renewed token restricted to that component's own policy.

> **Not yet available on this path.** A dedicated AppRole-setup GitHub Actions workflow does not exist yet in `dpn-containerised-deployment-service` for the airgap pipeline. The design below documents the intended behaviour so components can adopt it once the workflow is added; today, Vault **token** authentication (Step 3B/3C) is the only supported method for the airgap path.

Once available, the workflow would run once per component, per environment, **after** Vault is deployed and initialised (Step 3B), taking `environment`, `cluster`, `cloud`, and `component` (the Vault-consuming component to provision an AppRole identity for, e.g. `certificate-manager`) as inputs. It would run `setup-approle.sh` inside the Vault pod (using the admin `VAULT-TOKEN` from Key Vault) to:

1. Write a least-privilege policy scoped to that component's own paths under `pki-client/node-net/client/*`.
2. Create/update an AppRole role bound to that policy (`token_ttl=1h`, `token_max_ttl=4h`, non-expiring `secret_id`).
3. Publish the generated **secret-id** to Key Vault as `VAULT-APPROLE-SECRET-ID` (consumed automatically by the component's `SecretProviderClass`), and print the **role-id** for you to copy into that component's Helm values.

> **Key Vault governance note:** the `VAULT-APPROLE-SECRET-ID` Key Vault secret is stamped with a 355-day expiry to satisfy Key Vault's maximum-validity policy. The underlying Vault secret-id itself does not expire — **re-run this pipeline before the Key Vault copy expires** to rotate it, then redeploy the component to pick up the refreshed value.

To switch a component over once its AppRole identity exists, set in its environment values file:

```yaml
vault:
  authMethod: approle   # was: token
  appRole:
    roleId: <role_id from the setup output>
    useSecretIdRef: true
    secretIdSecretName: <component>-secrets   # synced from Key Vault via the CSI driver
    secretIdSecretKey: VAULT_APPROLE_SECRET_ID
```

`token` remains required for the bundle-load workflow (Step 3C) regardless, which authenticates as the Vault admin — AppRole (once available) would be for the long-running application components that read certificate material at runtime.

---

## Appendix — AWS KMS auto-unseal configuration

This is a **required prerequisite**, not an optional add-on — per [Step 3B](#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml) above, the pipeline has no interactive unseal step, so without this Vault comes back sealed after every pod restart and the Vault Init step fails outright. Set this up as part of [Step 1](#step-1-prerequisites-before-vault-can-be-deployed), before your first run of `dpn-vault-https-cd.yml`:

1. Create a symmetric KMS CMK, e.g. alias `alias/dpn-vault-unseal`.
2. Create an IAM role whose trust policy allows
   `sts:AssumeRoleWithWebIdentity` from your cluster's OIDC provider for
   `system:serviceaccount:ns-dpn-01:federator-server`, granting
   `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` on that CMK.
3. Annotate the `federator-server` ServiceAccount with that role's ARN.
4. Add a seal stanza to the chart's `values/aws/<environment>-<cluster>.yaml`
   (`seal.awskms.*`, mirroring `seal.azureKeyVault.*` on the Azure side — see
   [Step 2b](#step-2b-vault-helm-values)):
   ```hcl
   seal "awskms" {
     region     = "<AWS_REGION>"
     kms_key_id = "alias/dpn-vault-unseal"
   }
   ```

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
