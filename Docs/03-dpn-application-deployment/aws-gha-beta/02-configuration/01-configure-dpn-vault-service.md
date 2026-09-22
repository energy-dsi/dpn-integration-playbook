# DPN Vault Service Configuration

This section describes how to configure **DPN HashiCorp Vault service**. HashiCorp Vault is the secret store used by DPN Certificate Manager to hold Intermediate CA, CA chain, key pair, certificate, and keystore/truststore passwords. These secrets are used to build the certificate P12 files for mutual TLS (mTLS).

DSI provides an **automated method** (GitHub Actions workflows) that generates the required CSR, certificate, and key material and configures Vault end to end — this is the only supported deployment method for this airgapped AWS path, run on the shared self-hosted GitHub Actions runner, the same way as the Azure airgap path.

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
    - [Step 3A: Configure Bootstrap Vault TLS (`dpn-gha-vault-tls-bootstrap-cd.yml`)](#step-3a-configure-bootstrap-vault-tls-dpn-vault-tls-bootstrap-cdyml)
    - [Step 3B: Deploy and Initialise Vault (`dpn-gha-vault-https-cd.yml`)](#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml)
    - [Step 3C: Configure Certificate Bundle (`dpn-gha-vault-load-bundle-cd.yml`)](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml)
    - [Step 3D: Deploy Certificate Manager (`dpn-gha-certificate-manager-cd.yml`)](#step-3d-deploy-certificate-manager-dpn-certificate-manager-cdyml)
  - [Step 3E: Configure AppRole Authentication (planned, not yet available)](#step-3e-configure-approle-authentication-planned-not-yet-available)
- [Appendix — AWS KMS auto-unseal configuration](#appendix--aws-kms-auto-unseal-configuration)
- [Requesting a DPN Server Certificate](#requesting-a-dpn-server-certificate)
  - [How this differs from the Federator Gateway's certificate](#how-this-differs-from-the-federator-gateways-certificate)
  - [Step1: Create a key pair](#step1-create-a-key-pair)
  - [Step2: Create a CSR](#step2-create-a-csr)
  - [Step3: Request the signed server certificate](#step3-request-the-signed-server-certificate)
  - [Certificate properties](#certificate-properties)
  - [Renewal](#renewal)
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

> **Cloud provider.** The `vault-https` chart is `cloudProvider`-aware (`aws` or `azure`) — it selects the auto-unseal seal stanza, the ServiceAccount/IRSA wiring, the internal load-balancer annotations, and (see [Step 2b](#step-2b-vault-helm-values)) the CSI `SecretProviderClass` backend accordingly. Set `cloudProvider: aws` explicitly in the environment values file — the chart's own default is `azure`.
>
> **Legacy plain-HTTP `vault` chart.** An older, non-TLS `vault` Helm chart and a `dpn-gha-vault-cd.yml` workflow alongside `vault-https`. They are **not** part of the documented/supported flow below — `vault-https` (HTTPS-only, as described in this guide) is the only Vault deployment path DSI documents and supports on this path.

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

The automated flow uses four GitHub Actions workflows:

| Order | Workflow | Purpose |
|-------|----------|---------|
| 1 | `dpn-gha-vault-tls-bootstrap-cd.yml` | Generate the Vault server TLS certificate/key + Certificate Manager truststore, and publish them to Key Vault and Kubernetes |
| 2 | `dpn-gha-vault-https-cd.yml` | Deploy Vault via Helm, then initialise it and enable the KV v2 engine |
| 3 | `dpn-gha-vault-load-bundle-cd.yml` | Load the DSM-signed client certificate bundle into Vault |
| 4 | `dpn-gha-certificate-manager-cd.yml` | Deploy the Certificate Manager, which reads and renews certificates from Vault |

A fifth capability, **AppRole setup**, is planned but not yet available as a GitHub Actions workflow for this path — see [Step 3E](#step-3e-configure-approle-authentication-planned-not-yet-available).

```text
└── github-pipeline/
    └── workflows/
        ├── dpn-gha-vault-tls-bootstrap-cd.yml
        ├── dpn-gha-vault-https-cd.yml
        ├── dpn-gha-vault-load-bundle-cd.yml
        └── dpn-gha-certificate-manager-cd.yml
```

---

### Step 1: Prerequisites (before Vault can be deployed)

Ensure the following are in place **before** running any workflow:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **EKS cluster** provisioned and reachable | Target cluster for the deployment |
| 2 | **Namespaces, `efs-sc` StorageClass, `federator-server` ServiceAccount, `ghcr-pull-secret`** | See [Step2.3: EKS Namespace Configuration](00-common-dpn-configuration.md#step23-eks-namespace-configuration) |
| 3 | **AWS KMS key + IAM role for auto-unseal, and an IRSA ServiceAccount** | See [Appendix — AWS KMS auto-unseal configuration](#appendix--aws-kms-auto-unseal-configuration) — required for the pipeline path to work at all, since it has no interactive unseal step |
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
| `cloudProvider` | **Set to `aws`.** Selects AWS KMS auto-unseal, the IRSA ServiceAccount, the AWS-native `SecretProviderClass`, and the NLB service annotations below; the chart's own default is `azure` | `aws` |
| `image.repository` | Complete URL of the Vault image | `ghcr.io/energy-dsi/1.0.1/vault` |
| `image.tag` | Vault image tag (also overridable at runtime) | `1.16` |
| `namespace` | Kubernetes namespace | `ns-dpn-01` |
| `persistence.storageClassName` | Persistent volume StorageClass — an EBS-backed class (`gp2`/`gp3`), **not** the `efs-sc` class used by Certificate Manager's file share; Vault needs a `ReadWriteOnce` volume | `gp3` |
| `seal.awsKms.region` | Region of the auto-unseal KMS key | `<AWS_REGION>` |
| `seal.awsKms.kmsKeyArn` | Auto-unseal KMS key ARN (an alias also works) | `arn:aws:kms:<region>:<account-id>:key/<key-id>` |
| `serviceAccount.create` | Create the IRSA-annotated ServiceAccount used for KMS auto-unseal | `true` |
| `serviceAccount.name` | ServiceAccount name (default `dpn-vault`) | `dpn-vault` |
| `serviceAccount.irsaRoleArn` | IAM role ARN whose trust policy scopes `sts:AssumeRoleWithWebIdentity` to `system:serviceaccount:<namespace>:<serviceAccount.name>`, granting `kms:Encrypt`/`kms:Decrypt`/`kms:DescribeKey` on the unseal key | `arn:aws:iam::<account-id>:role/<role-name>` |
| `secretsManager.secretPrefix` | AWS Secrets Manager prefix the CSI `SecretProviderClass` reads the Vault TLS cert/key from (`<prefix>/VAULT_TLS_CERT`, `<prefix>/VAULT_TLS_KEY`), mounted at `/vault/tls` via the pod's default IAM identity | `dpn/<environment>-<cluster>/vault-https` |

> **Note:** Keep `replicaCount: 1` — Vault uses a `ReadWriteOnce` persistent volume. The Vault TLS certificate and key are **not** set as literal values here; they are generated in [Step 3A](#step-3a-configure-bootstrap-vault-tls-dpn-vault-tls-bootstrap-cdyml) and read at runtime via the `SecretProviderClass`.
>
> **Known limitation — TLS material publish is Azure Key Vault-only today.** [Step 3A](#step-3a-configure-bootstrap-vault-tls-dpn-vault-tls-bootstrap-cdyml)'s publish step currently writes `VAULT-TLS-CERT`/`VAULT-TLS-KEY` only to Azure Key Vault (`KEY_VAULT_NAME`), even when `cloud: aws` is selected — it has not yet been updated to also publish to AWS Secrets Manager. Until that lands, choose one of:
> - Keep `KEY_VAULT_NAME` populated in `.github/config/aws/<environment>-<cluster>.json` (see [Step 2a](#step-2a-environment-config-json)) and continue using it cross-cloud, or
> - Manually publish the cert/key produced by Step 3A's downloadable artifact to `<secretsManager.secretPrefix>/VAULT_TLS_CERT` and `.../VAULT_TLS_KEY` in Secrets Manager (e.g. `aws secretsmanager create-secret`) if you want the native AWS `SecretProviderClass` path used above.

---

### Step 3: Deployment Configuration

Trigger the following workflows in order, via **Actions → &lt;workflow name&gt; → Run workflow** . Each resolves `.github/config/aws/<environment>-<cluster>.json` and the matching Helm values file automatically from the `environment`/`cluster`/`cloud` inputs.

#### Step 3A: Configure Bootstrap Vault TLS (`dpn-gha-vault-tls-bootstrap-cd.yml`)

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

> **Truststore password comes from a repository secret, not a workflow input.** The truststore password is read from the repository secret `DPN_TLS_TRUSTSTORE_PASSWORD` (the same secret `dpn-tls-cd.yaml` uses) and published to Key Vault as `VAULT-TRUSTSTORE-PASSWORD`. There is no `truststorePassword` workflow input — GitHub Actions has no secret-typed `workflow_dispatch` input, and a plain string input would always be visible in the "Run workflow" form regardless of log masking. Set `DPN_TLS_TRUSTSTORE_PASSWORD` as a repository (or environment) secret before running this workflow.

On completion it publishes:
- `VAULT-TLS-CERT`, `VAULT-TLS-KEY`, `VAULT-TRUSTSTORE-PASSWORD` → Azure Key Vault
- `truststore.jks` → Kubernetes secret `cert-manager-truststore`
- The full working set (including private keys) as a 1-day-retention workflow artifact — download and secure it, then delete the artifact

#### Step 3B: Deploy and Initialise Vault (`dpn-gha-vault-https-cd.yml`)

This workflow deploys the `vault-https` Helm chart and runs: **Checkout** → **Cloud Login** (also establishes the EKS context) → **EKS Context** (a second, retried connectivity check with diagnostics — the shared self-hosted runner's connection to a given cluster's VPC is not always reliable) → **Helm Lint + Dry Run** → **Helm Deploy** (`helm upgrade --install`) → **Vault HTTPS Seal Status Check** → **Vault Init** (runs `vault-init.sh` to enable the KV v2 engine at `pki-client` and audit logging).

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `vaultImageTag` | Vault image tag (default `1.16`) |
| `vaultImageRepository` | Optional — overrides `image.repository` for this run only (path after `ghcr.io/energy-dsi/`) |
| `runVaultInit` | Run the init step (default `true`; idempotent — safe to re-run on an existing vault) |
| `storeRootTokenInSecretsBackend` | Store the Vault root token in the cloud secrets backend. On AWS this creates/updates the AWS Secrets Manager secret `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN`; on Azure it stores `VAULT-TOKEN` in Key Vault. **Set `true` on the first deploy** if you intend to authenticate the bundle-load workflow (Step 3C) with the root token — on AWS, Step 3C instead authenticates via the Certificate Manager's AppRole by default (see [Step 3C](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml)) |

> **Auto-unseal is what makes this workflow viable — set it up before this step, not after.** The pipeline has no interactive unseal step; if Vault comes back sealed, the Vault Init step will simply fail. Configure **AWS KMS auto-unseal** (`seal.awsKms.*` and the `serviceAccount.*` IRSA wiring in the chart's AWS values — [Step 2b](#step-2b-vault-helm-values)) before running this workflow; see [Appendix](#appendix--aws-kms-auto-unseal-configuration) for the exact KMS key/IAM role setup.
>
> **No `--wait`/`--timeout` on `helm upgrade` for this path.** Long-lived watches against the EKS API from the self-hosted runner were unreliable and timed out even when the rollout had actually completed on the cluster. The Helm Deploy step instead fires the upgrade without waiting, then polls `kubectl rollout status --timeout=60s` up to five times with a short pause between attempts — a deploy that reports failure after all five attempts prints diagnostic `helm status`/pods/`describe pods`/PVC/`SecretProviderClass`/namespace-events output before failing the job.
>
> The init step publishes the full init output (**root token + recovery keys**) as the `vault-init-output-<environment>-<cluster>` workflow artifact (1-day retention). Download it, store the recovery keys securely per Organisation's secrets policy, then delete the artifact. There is no ADO-style approval gate on this workflow by default — if you want a manual sign-off before this step runs, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

#### Step 3C: Configure Certificate Bundle (`dpn-vault-load-bundle-cd.yml`)

This workflow needs the DSM client bundle set as **GitHub Actions secrets** (repository or environment level) using these exact names:

| Secret | Content |
|-------------|---------|
| `VAULT_KEY` | Your DPN client **private key** |
| `CERTIFICATE_PEM` | The **DSM-signed certificate** |
| `CA_CHAIN_PEM` | The **CA chain** from DSM |

The workflow resolves the Vault pod, obtains a Vault token, and writes `pki-client/node-net/client/{keypair,certificate,ca-chain}`. **How it obtains the Vault token differs by cloud:**

- **Azure:** reads the Vault root token from Key Vault (`VAULT-TOKEN`, placed by Step 3B with `storeRootTokenInSecretsBackend: true`).
- **AWS:** authenticates via **AppRole login**, not the root token — it reads the Certificate Manager's AppRole `role_id`/`secret_id` from AWS Secrets Manager (`dpn/<environment>-<cluster>/certificate-manager/VAULT_APPROLE_ROLE_ID` and `.../VAULT_APPROLE_SECRET_ID`, published by `dpn-certificate-manager-role-id-creation.yml` — see [Configure DPN Certificate Manager, Step2](04-configure-dpn-certificate-manager.md#step2-configure-vault-authentication)), then runs `vault write auth/approle/login` inside the Vault pod. This works because the Certificate Manager's AppRole policy already grants create/read/update/list on `pki-client/data/node-net/client/*` — the exact path this workflow writes to — so no root token needs to leave Vault init on AWS.

`workflow_dispatch` inputs: `environment`, `cluster`, `cloud`.

> **Prerequisites for this step:**

- Vault deployed and unsealed (Step 3B)
- KV v2 enabled at `pki-client`
- Above secrets set in GitHub Actions
- **Azure:** `VAULT-TOKEN` present in Key Vault (from Step 3B with `storeRootTokenInSecretsBackend: true`)
- **AWS:** `dpn-certificate-manager-role-id-creation.yml` already run for the `certificate-manager` component, so its `role_id`/`secret_id` exist in Secrets Manager (see [Configure DPN Certificate Manager, Step2](04-configure-dpn-certificate-manager.md#step2-configure-vault-authentication))

#### Step 3D: Deploy Certificate Manager (`dpn-gha-certificate-manager-cd.yml`)

See [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) for the full configuration and workflow inputs for this step.

---

### Step 3E: Configure AppRole Authentication (planned, not yet available)

The Vault root token is a single, all-privileges credential — every component that needs it (Certificate Manager, Federator Gateway) ends up holding full access to Vault. **AppRole** is the recommended alternative: each component authenticates with its own scoped identity (a `role_id` plus a `secret_id`) and receives a short-lived, auto-renewed token restricted to that component's own policy.

> **Certificate Manager already has one; other components don't yet — but can reuse it.** `dpn-certificate-manager-role-id-creation.yml` exists today and provisions a scoped AppRole identity for the `certificate-manager` component specifically (see [Configure DPN Certificate Manager, Step2](04-configure-dpn-certificate-manager.md#step2-configure-vault-authentication) for the authoritative, up-to-date description, including its AWS Secrets Manager output paths) — it's also used by [Step 3C](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml) above to authenticate the bundle-load workflow on AWS. A dedicated, generic per-component AppRole-setup workflow for **other** Vault-consuming components (e.g. the Federator Gateway). The design below documents the intended behaviour for those components so they can adopt the same pattern once a workflow is added for them.
>
> That said, Vault token authentication is **not** the only option available today: the Federator Gateway's real AWS environment already runs on AppRole by **pointing `vaultConfig.appRole.roleId` directly at the Certificate Manager's own `role_id`** and reusing its `secret_id` — no dedicated provisioning workflow needed, since the identity already exists. This shares one component's scoped credential with another rather than giving the Federator Gateway its own least-privilege policy, so treat it as a pragmatic stopgap rather than the end-state design below — but it works, and is what's actually deployed. See [Configure DPN Federator Gateway, Step1](05-configure-dpn-federator-gateway.md#step1-meet-prerequisites).

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

This is a **required prerequisite**, not an optional add-on — per [Step 3B](#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml) above, the pipeline has no interactive unseal step, so without this Vault comes back sealed after every pod restart and the Vault Init step fails outright. Set this up as part of [Step 1](#step-1-prerequisites-before-vault-can-be-deployed), before your first run of `dpn-gha-vault-https-cd.yml`:

1. Create a symmetric KMS CMK, e.g. alias `alias/dpn-vault-unseal`.
2. Create an IAM role whose trust policy allows
   `sts:AssumeRoleWithWebIdentity` from your cluster's OIDC provider for
   `system:serviceaccount:ns-dpn-01:<serviceAccount.name>` (the dedicated
   Vault ServiceAccount, default `dpn-vault` — **not** `federator-server`),
   granting `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` on that CMK.
3. Set `serviceAccount.create: true`, `serviceAccount.name`, and
   `serviceAccount.irsaRoleArn` (that role's ARN) in the chart's
   `values/aws/<environment>-<cluster>.yaml` — the chart creates and
   annotates the ServiceAccount for you (see [Step 2b](#step-2b-vault-helm-values)).
4. Add a seal stanza to the same values file
   (`seal.awsKms.*`, mirroring `seal.azureKeyVault.*` on the Azure side — see
   [Step 2b](#step-2b-vault-helm-values)):
   ```hcl
   seal "awskms" {
     region     = "<AWS_REGION>"
     kms_key_id = "alias/dpn-vault-unseal"
   }
   ```

---

## Requesting a DPN Server Certificate

A **server certificate** is a long-TTL (60 day) certificate issued by the DSM Management Node for a participant's own edge/server-facing endpoints — for example, a Cloudflare-fronted server. It is issued and downloaded in a single call and is **not** renewed automatically. This is a different Vault and a different certificate from everything else on this page: it is signed by the **Management Node's own separate Vault PKI engine**, not the `pki-client` KV store this page otherwise configures. This is the raw-API version of the same "edge component certificate" concept introduced under [Certificate Lifecycle and Management](#certificate-lifecycle-and-management) above — useful for automation/scripting, or for understanding what the DSI portal's Certificate Management screen does under the hood.

> **This is not the Federator Gateway's mTLS certificate.** The gRPC Federator Gateway's producer/consumer certificate is obtained and continuously renewed automatically by the [Certificate Manager](04-configure-dpn-certificate-manager.md) against a different Management Node endpoint (`/api/v1/certificate/csr/sign`) and requires no manual action. The server certificate described here is a **separate, manually-requested** certificate for a participant's own edge infrastructure — the Management Node's own API documentation is explicit that it **must not be used by DPN Federator server or client containers**.

All endpoints below are under `/api/v1/certificate` on the DSM Management Node and require a bearer token with the appropriate authority (see each step).

> **Prefer the DSI portal for day-to-day use.** The steps below call the Management Node API directly. Most participants will instead use the DSI portal's own **Certificate Management** screen (Your Organisation → DPN → Certificate Management), where this certificate is labelled **"Edge component certificate."** See the [DSI Certificate Management UI Guide](../../../05-dpn-user-interfaces/10-dsi-certificate-management-ui-operations.md).

> **Bootstrap certificates are a different, Federator-side concept.** The Certificate Manager's *automatic* Federator certificate renewal (linked above) marks a participant's very first Federator certificate as a "bootstrap certificate" (a custom OID in its SAN, per `dpn-federator-certificate-manager`'s `docs/certificate-lifecycle.md`) so it gets replaced on the very next renewal cycle rather than running its full validity. That mechanism is unrelated to the server certificate on this page — a server certificate is never auto-renewed and never carries a bootstrap marker; it must always be requested fresh via [Step3](#step3-request-the-signed-server-certificate) before it expires.

### How this differs from the Federator Gateway's certificate

| | Federator Gateway certificate | Server certificate (this section) |
|---|---|---|
| Requested via | Certificate Manager's automatic renewal job (`/api/v1/certificate/csr/sign`) | Manual, single call (`/api/v1/certificate/server-certificate`) |
| TTL | 24 hours by default — renewed continuously, well before expiry | 60 days |
| Renewal | Automatic | **Manual** — you must request a new one before it expires |
| JWKS rotation | Yes, on every renewal | **Never** |
| Delivery | Persisted to Vault directly by the Certificate Manager | Returned to the caller as a ZIP download (`certificate.pem` + `ca-chain.pem`) |
| Intended use | The gRPC Federator Gateway's own producer/consumer mTLS endpoints | The participant's own edge/server endpoints (e.g. a Cloudflare-fronted server) — never the Federator Gateway itself |

Both certificate types are ultimately signed by the same underlying Certificate Authority — HashiCorp Vault's PKI secrets engine on the Management Node side — just against different signing roles (different TTL and SAN policy).

### Step1: Create a key pair

```
GET /api/v1/certificate/keyPair
```

Requires authority `ROLE_management-node:create_keys`.

Returns a fresh RSA 2048-bit key pair:

| Field | Description |
|---|---|
| `publicKeyPem` | The public key, PEM-encoded |
| `privateKeyPem` | The private key, PEM-encoded — handle this as a secret; the Management Node does not retain a copy |
| `algorithm` | `RSA` |
| `createdAt` | Generation timestamp |

### Step2: Create a CSR

```
POST /api/v1/certificate/csr/create
```

Requires authority `ROLE_management-node:create_keys`.

| Field | Description | Required |
|---|---|---|
| `publicKeyPem` / `privateKeyPem` | The key pair from [Step1](#step1-create-a-key-pair) | Yes |
| `commonName` | The certificate's CN — typically the server's fully-qualified hostname | Yes |
| `organization` | Subject `O` | No |
| `organizationalUnit` | Subject `OU` | No |
| `country` | Subject `C` | No |
| `dnsSans` | Additional DNS Subject Alternative Names to cover (e.g. alternate hostnames) | No |

Returns a CSR PEM.

> **Reusing an existing CSR:** if you already generated a CSR for this organisation's client/bootstrap certificate, the same CSR PEM may be reused directly in [Step3](#step3-request-the-signed-server-certificate) instead of repeating Steps 1–2 — the server-certificate request has the identical shape as the bootstrap (client) certificate request.

### Step3: Request the signed server certificate

```
POST /api/v1/certificate/server-certificate
```

Requires authority `ROLE_management-node:request_bootstrap_certificate` (the same authority used for the client/bootstrap certificate — there is no dedicated server-certificate authority).

| Field | Description |
|---|---|
| `organisationId` | The requesting organisation's ID |
| `csr` | The CSR PEM from [Step2](#step2-create-a-csr) |

The response is a `200 OK` with `Content-Type: application/zip` (`Content-Disposition: attachment; filename="server_certificate.zip"`), containing:

- `certificate.pem` — the signed server certificate
- `ca-chain.pem` — the issuing CA chain

This is a **single generate-and-download call** — there is no separate "sign" step to invoke afterward, and no polling required.

### Certificate properties

| Property | Value |
|---|---|
| Key algorithm | RSA 2048 (from the CSR generated in [Step1](#step1-create-a-key-pair)/[Step2](#step2-create-a-csr)) |
| Validity (TTL) | 60 days |
| Signing authority | HashiCorp Vault's PKI secrets engine on the Management Node, against a dedicated server-certificate signing role (separate from the Federator Gateway's signing role) |
| JWKS rotation | Never triggered by this certificate |
| Renewal | Manual — none of this flow is automatic |

### Renewal

There is no automatic renewal for a server certificate. Track its 60-day expiry yourself and repeat [Step1](#step1-create-a-key-pair) through [Step3](#step3-request-the-signed-server-certificate) (or just Step3, reusing an existing CSR) to obtain a replacement before the current one expires.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
