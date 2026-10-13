# DPN Vault Service Configuration

This section describes how to configure **DPN HashiCorp Vault service**. HashiCorp Vault is the secret store used by DPN Certificate Manager to hold Intermediate CA, CA chain, key pair, certificate, and keystore/truststore passwords. These secrets are used to build the certificate P12 files for mutual TLS (mTLS).

DSI provides an **automated method** (GitHub Actions workflows) that generates the required CSR, certificate, and key material and configures Vault end to end — this is the only supported deployment method for this AWS path, run on the shared self-hosted GitHub Actions runner, the same way as the Azure path.

> **Environment and cluster:** These instructions target one `<environment>`/`<cluster>` combination (`dev`/`test` × `dpn01`/`dpn02`). Substitute your actual values in:
>
> - config file `.pipelines/github-action-pipelines/config/aws/<environment>-<cluster>.json` 
> - values file `dpn-federator-cert-manager/charts/<chart>/values/aws/<environment>-<cluster>.yaml` 
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
    - [Step 3A: Configure Vault TLS (`dpn-gha-tls-cd.yaml`)](#step-3a-configure-vault-tls-dpn-tls-cdyaml)
    - [Step 3B: Deploy and Initialise Vault (`dpn-gha-vault-https-cd.yml`)](#step-3b-deploy-and-initialise-vault-dpn-vault-https-cdyml)
    - [Step 3C: Configure Certificate Bundle (`dpn-gha-vault-load-bundle-cd.yml`)](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml)
    - [Step 3D: Deploy Certificate Manager (`dpn-gha-certificate-manager-cd.yml`)](#step-3d-deploy-certificate-manager-dpn-certificate-manager-cdyml)
  - [Step 3E: Configure AppRole Authentication (`dpn-certificate-manager-role-id-creation.yml`)](#step-3e-configure-approle-authentication-dpn-certificate-manager-role-id-creationyml)
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

Vault is deployed and configured entirely through **[Automated Vault Configuration](#automated-vault-configuration)** — five GitHub Actions workflows generate the TLS material, deploy and initialise Vault, load the certificate bundle, provision the Certificate Manager's AppRole identity, and deploy the Certificate Manager. There is no manual deployment path for this component.

> **Cloud provider.** The `vault-https` chart is `cloudProvider`-aware (`aws`) — it selects the auto-unseal seal stanza, the ServiceAccount/IRSA wiring, the internal load-balancer annotations, and (see [Step 2b](#step-2b-vault-helm-values)) the CSI `SecretProviderClass` backend accordingly. Set `cloudProvider: aws`.
>
> **Legacy plain-HTTP `vault` chart.** An older, non-TLS `vault` Helm chart (`dpn-federator-cert-manager/charts/vault`) and its `dpn-gha-vault-cd.yml` workflow (**DPN CD - Vault**) still exist alongside `vault-https`. They are **not** part of the documented/supported flow below — `vault-https` (HTTPS-only, as described in this guide) is the only Vault deployment path DSI documents and supports on this path.

### Certificate Lifecycle and Management

DPN-to-DPN and DPN-to-DSM communications are secured using mutual TLS (mTLS), meaning both parties in every connection must present a valid certificate to authenticate themselves. Each DPN therefore requires a DSI-issued certificate to participate in the network — without one, it cannot establish any connection with another DPN or with the DSM.

During initial DPN setup, a participant uploads a Certificate Signing Request (CSR) through the DSM user interface. The DSM signs the CSR and returns a bootstrap certificate bundle for download. The participant installs this bundle into their DPN's Vault via [Step 3C](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml), after which certificate renewal is handled automatically — the DPN manages its own certificate lifecycle without further manual intervention under normal operating conditions.

If a certificate expires before automatic renewal has taken place — for example due to the DPN being offline during the renewal window — the participant will need to return to the DSM user interface, upload a new CSR, and download a fresh bootstrap certificate to restore connectivity. As with the initial setup, the downloaded certificate bundle should be saved at the point of download since it cannot be retrieved from the platform again once the session ends.

Organisations should factor this recovery process into their operational runbooks so that certificate expiry does not result in extended loss of connectivity to the DSI network.

While the DSM is capable of issuing short-lived certificates and the DPN includes built-in capability to renew them automatically before expiry, the current certificate validity period is set to 60 days. This decision is driven by a known constraint affecting organisations that deploy their DPN behind Cloudflare or an equivalent reverse proxy or edge security layer. In such deployments, enterprise security policies may be configured to terminate mTLS at the Cloudflare boundary rather than passing it through end-to-end. Where mTLS is terminated at Cloudflare, the certificate installed at that layer is outside the DPN's automated renewal process — meaning that when a certificate is renewed by the DPN, the updated certificate must also be manually installed at the Cloudflare boundary. A shorter certificate lifetime would increase the frequency of this manual intervention. Setting the validity period to 60 days balances the security benefit of certificate rotation against the operational burden of manual installation at the proxy layer.

This constraint is under active review. Solutions have been identified that are expected to address 24 hrs certificate TTL back from 60 days while issuing a different certificate for proxy-terminated mTLS deployments. The additional long term TTL certificate to be provided from a different endpoint and serves only the purpose of client authentication at edge proxies for DPN. This longer TTL certificate can not be used for DSM authentication or any client certificate. This change is targeted for delivery in PI4.

_**Note:** Organisations operating DPNs behind Cloudflare or equivalent infrastructure should factor the current manual renewal process into their operational runbooks until this capability is available and also actively monitor the expiry of the certificate installed outside the DPN certificate manager component since DSI does not generate any alert on certificate expiry at this moment._

---
### Where secrets live
This page touches five genuinely different secret stores — use this table to check where any given item actually lives before searching for it in the wrong place:
| Item | Where it lives | Notes |
|---|---|---|
| `keypair`, `certificate`, `ca-chain`, `intermediate-ca`, `keystore-password`, `truststore-password` | **Vault's own KV-v2 store** (`pki-client/node-net/client/*`) | Not a Kubernetes Secret, not Secrets Manager — internal to Vault itself |
| `VAULT_TLS_CERT`, `VAULT_TLS_KEY` (`secretsManager.secretPrefix`) | **AWS Secrets Manager**, synced via the CSI `SecretProviderClass` | Mounted into the Vault pod at `/vault/tls` |
| `VAULT-TLS-CERT`, `VAULT-TLS-KEY`, `VAULT-TRUSTSTORE-PASSWORD` (Step 3A's actual publish target today) | **Azure Key Vault only**, even when `cloud: aws` | Known limitation — see [Step 2b](#step-2b-vault-helm-values) |
| `truststore.jks` (Step 3A output) | **Kubernetes Secret** `cert-manager-truststore` | Plain K8s object, not Secrets Manager |
| `vault.csr`, `server.csr`, full Step 3A working set (incl. private keys) | **GitHub Actions workflow artifact** (1-day retention) | Ephemeral CI download — download and delete, not a persistent store |
| `VAULT_TOKEN` (root token, Step 3B) | **AWS Secrets Manager** `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN`, or **Azure Key Vault** `VAULT-TOKEN` | Cloud-branched, only written if `storeRootTokenInSecretsBackend: true` |
| Full Vault init output (root token + recovery keys) | **GitHub Actions workflow artifact** `vault-init-output-<environment>-<cluster>` (1-day retention) | Separate from the `VAULT_TOKEN` copy above |
| `VAULT_KEY`, `CERTIFICATE_PEM`, `CA_CHAIN_PEM` (Step 3C inputs) | **GitHub Actions secrets** (repo/environment level) | A fourth, distinct store |
| `VAULT_APPROLE_ROLE_ID`, `VAULT_APPROLE_SECRET_ID` | **AWS Secrets Manager**, component-suffixed path (e.g. `.../certificate-manager/VAULT_APPROLE_SECRET_ID`) | Or Azure Key Vault, component-suffixed name |
---

## Automated Vault Configuration

The automated flow uses five GitHub Actions workflows:

| Order | Workflow (display name) | Purpose |
|-------|----------|---------|
| 1 | `dpn-gha-tls-cd.yaml` (**DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1**) | Generate the DPN Root CA and the common server certificate/key (used as the Vault server TLS certificate), publish the Vault TLS cert/key to AWS Secrets Manager, and create the `cert-manager-truststore` and `tls-auth-secret` Kubernetes secrets |
| 2 | `dpn-gha-vault-https-cd.yml` (**DPN CD - Vault HTTPS**) | Deploy Vault via Helm, then initialise it and enable the KV v2 engine |
| 3 | `dpn-gha-vault-load-bundle-cd.yml` (**DPN CD - Vault Load Cert Bundle**) | Load the DSM-signed client certificate bundle into Vault |
| 4 | `dpn-certificate-manager-role-id-creation.yml` (**DPN CD - Certificate Manager Role ID Creation (Vault AppRole Setup)**) | Provision the Certificate Manager's Vault AppRole and publish its `role_id`/`secret_id` to AWS Secrets Manager — see [Step 3E](#step-3e-configure-approle-authentication-dpn-certificate-manager-role-id-creationyml) |
| 5 | `dpn-gha-certificate-manager-cd.yml` (**DPN CD - Certificate Manager**) | Deploy the Certificate Manager, which reads and renews certificates from Vault |

> **Run order 4 before order 5 on AWS.** `dpn-gha-certificate-manager-cd.yml` fetches the Certificate Manager's `role_id` from Secrets Manager at deploy time and fails if it is missing, so the AppRole setup ([Step 3E](#step-3e-configure-approle-authentication-dpn-certificate-manager-role-id-creationyml)) must be run before [Step 3D](#step-3d-deploy-certificate-manager-dpn-certificate-manager-cdyml).

```text
.pipelines/
└── .github-actions-pipelines/
    └── workflows/
        ├── dpn-gha-tls-cd.yaml
        ├── dpn-gha-vault-https-cd.yml
        ├── dpn-gha-vault-load-bundle-cd.yml
        ├── dpn-certificate-manager-role-id-creation.yml
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
| 4 | **GitHub Actions OIDC role** for the AWS account (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#aws-iam-oidc-role)) — the `cloud-login` composite action assumes the hub role and then `oidc_github_runner_admin` in the target account, and sets up `kubectl`, `helm` and (if missing) the AWS CLI; the TLS workflow sets up Java/`keytool` itself | No agent setup needed per environment |
| 5 | **Environment config and values files populated** | See [Step 2](#step-2-reference-configuration-data-populate-before-deployment) |
| 6 | **DSM-signed client bundle available** | The client private key, DSM-signed certificate, and CA chain — loaded in [Step 3C](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml) |

> **One-time setup:** Before running any workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration). In particular the workflows **do not create the namespace** — create it first (`kubectl create namespace <NAMESPACE>`), populate `.github/config/aws/<environment>-<cluster>.json`, and set the required GitHub Actions secrets (`DPN_TLS_KEYSTORE_PASSWORD`, `DPN_TLS_TRUSTSTORE_PASSWORD`, `DPN_TLS_CLIENT_P12_PASSWORD` for Step 3A; the bundle secrets for Step 3C).

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

The AWS Secrets Manager names the workflows use are not config JSON keys — they are derived from the inputs as `dpn/<environment>-<cluster>/<component>/<KEY>` (for example `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN`).

#### Step 2b. Vault Helm values

Set the values below in your environment/cluster's values file. DSI proposes only these selective changes; other parameters may be customised if required.

```text
root/
  └── charts/
        └── vault-https/  
          └── values/
              └── aws/          
                 └──<environment>-<cluster>.yaml <- Your environment overrides
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

> **Note:** Keep `replicaCount: 1` — Vault uses a `ReadWriteOnce` persistent volume. The Vault TLS certificate and key are **not** set as literal values here; they are generated in [Step 3A](#step-3a-configure-vault-tls-dpn-tls-cdyaml) and read at runtime via the `SecretProviderClass`.
>
> - Step 3A (`dpn-gha-tls-cd.yaml`) publishes them to `dpn/<environment>-<cluster>/vault-https/VAULT_TLS_CERT` and `.../VAULT_TLS_KEY` in Secrets Manager, so keep `secretsManager.secretPrefix` set to `dpn/<environment>-<cluster>/vault-https` to match.

---

### Step 3: Deployment Configuration

Trigger the following workflows in order, via **Actions → &lt;workflow name&gt; → Run workflow** . Each resolves `.github/config/aws/<environment>-<cluster>.json` and the matching Helm values file automatically from the `environment`/`cluster`/`cloud` inputs.

#### Step 3A: Configure Vault TLS (`dpn-gha-tls-cd.yaml`)

Trigger **Actions → DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1 → Run workflow**. In a single run, this workflow uses `.github/config/scripts/create-dpn-tls.sh` to generate one self-signed DPN Root CA (`CN=dpn-root`) and one common server certificate/key (`CN=dpn-common`, wildcard SANs `*.ns-dpn-01.svc.cluster.local`, `*.ns-dpn-health-01.svc.cluster.local`, `*.ns-dpn-dp-01.svc.cluster.local`, which cover `vault-https.<namespace>.svc.cluster.local`). It then publishes them to AWS Secrets Manager and Kubernetes. The same certificate also serves Keycloak, Kafka and the Federator. See [Common Configuration](00-common-dpn-configuration.md) for the other secrets it creates.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `cloud` | `aws` (default) |
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `targetNamespace` | Namespace for `dpn-tls` + `fed-gateway-tls` — `ns-dpn-01` (default) / `ns-dpn-health-01` |
| `country` | Certificate subject Country (C) — default `GB` |
| `org` | Certificate subject Organisation (O) — default `DSI` |
| `storePasswordsInSecretsBackend` | Also store the cert/store passwords in Secrets Manager — default `true` |
| `createHealthTls` | Also create `dpn-health-tls` in `ns-dpn-health-01` — default `true` |

> **Passwords come from repository secrets, not workflow inputs.** The keystore, truststore and client P12 passwords are read from the repository (or environment) secrets `DPN_TLS_KEYSTORE_PASSWORD`, `DPN_TLS_TRUSTSTORE_PASSWORD` and `DPN_TLS_CLIENT_P12_PASSWORD`. GitHub Actions has no secret-typed `workflow_dispatch` input, and a plain string input would always be visible in the "Run workflow" form regardless of log masking. Set these secrets before running this workflow.

On completion it publishes (Vault-related items):
- `certs/server.crt` / `certs/server.key` → AWS Secrets Manager `dpn/<environment>-<cluster>/vault-https/VAULT_TLS_CERT` and `.../VAULT_TLS_KEY` (read by the `vault-https` `SecretProviderClass` — see [Step 2b](#step-2b-vault-helm-values))
- Truststore password → `dpn/<environment>-<cluster>/certificate-manager/VAULT_TRUSTSTORE_PASSWORD` and `dpn/<environment>-<cluster>/vault-https/VAULT_TRUSTSTORE_PASSWORD` (only when `storePasswordsInSecretsBackend: true`)
- `truststore.jks` → Kubernetes secret `cert-manager-truststore`
- `KEYSTORE_PASSWORD` / `TRUSTSTORE_PASSWORD` / `DPN_CLIENT_P12_PASSWORD` → Kubernetes secret `tls-auth-secret` (the Certificate Manager reads its Vault truststore password from here)
- The full working set, including private keys and the Root CA key, as the `dpn-tls-aws-<environment>-<cluster>` workflow artifact. Download it, secure it, and restrict who can download it.
- `vault.csr` (with `vault.key`) → CSR file for doing bootstrap from DSM (`CN=vault`). Sign it at the DSM, then load `vault.key` + the returned `certificate.pem` + `ca-chain.pem` in [Step 3C](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml)
- `server.csr` → CSR file for server certificate. Although vault.csr can be used as well for server certificate with large TTL

> **Vault-only alternative (superseded).** `dpn-gha-vault-tls-bootstrap-cd.yml` (**DPN CD - Vault TLS Bootstrap**) still exists and generates a Vault-only Root CA (`CN=dpn-vault-root`), Vault certificate/key and `cert-manager-truststore`. It is superseded by the Universal TLS pipeline. Its publish step writes only to Azure Key Vault (`az keyvault secret set`) and has no AWS Secrets Manager branch, so on AWS use `dpn-gha-tls-cd.yaml` above.

#### Step 3B: Deploy and Initialise Vault (`dpn-gha-vault-https-cd.yml`)

Trigger **Actions → DPN CD - Vault HTTPS → Run workflow**. This workflow deploys the `vault-https` Helm chart (`CHART_DIR` `dpn-federator-cert-manager/charts/vault-https`, release `vault-https`, Deployment `dpn-vault-https`) and runs: **Checkout** → **Read Deployment Config** → **Cloud Login** (also establishes the EKS context) → **EKS Context** (a second connectivity check, `timeout 30 kubectl get ns`, that prints `aws eks describe-cluster` diagnostics on failure — the shared self-hosted runner's connection to a given cluster's VPC is not always reliable) → **Helm Lint + Dry Run** → **Helm Deploy** (`helm upgrade --install`) → **Vault HTTPS Seal Status Check** → **Vault Init** (runs `dpn-federator-cert-manager/scripts/vault-init.sh` to initialise Vault, enable the KV v2 engine at `pki-client` and audit logging) → **Sync Root Token to certificate-manager Secret (AWS)** → **Publish Init File** → **Capture Deployed Image Digest** (published as the `deployed-image-digest` artifact).

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `vaultImageTag` | Vault image tag (default `1.16`) |
| `vaultImageRepository` | Optional — overrides `image.repository` for this run only (path after `ghcr.io/energy-dsi/`) |
| `runVaultInit` | Run the init step (default `true`; idempotent — safe to re-run on an existing vault) |
| `storeRootTokenInSecretsBackend` | Store the Vault root token in the cloud secrets backend (default `false`). On AWS this creates/updates the AWS Secrets Manager secret `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN`. **Set `true` on the first deploy** — the bundle-load workflow ([Step 3C](#step-3c-configure-certificate-bundle-dpn-vault-load-bundle-cdyml)) and the AppRole setup workflow ([Step 3E](#step-3e-configure-approle-authentication-dpn-certificate-manager-role-id-creationyml)) both read the root token from this secret and fail if it is missing |

> **Root token sync to the Certificate Manager (AWS).** When `runVaultInit` and `storeRootTokenInSecretsBackend` are both `true`, the **Sync Root Token to certificate-manager Secret (AWS)** step copies the token from `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN` to `dpn/<environment>-<cluster>/certificate-manager/VAULT_TOKEN` (via `aws secretsmanager put-secret-value`, so that secret must already exist). The Certificate Manager's `SecretProviderClass` reads it from there.

> **Auto-unseal is what makes this workflow viable — set it up before this step, not after.** The pipeline has no interactive unseal step; if Vault comes back sealed, the Vault Init step will simply fail. Configure **AWS KMS auto-unseal** (`seal.awsKms.*` and the `serviceAccount.*` IRSA wiring in the chart's AWS values — [Step 2b](#step-2b-vault-helm-values)) before running this workflow; see [Appendix](#appendix--aws-kms-auto-unseal-configuration) for the exact KMS key/IAM role setup.
>
> **No `--wait`/`--timeout` on `helm upgrade` for this path.** Long-lived watches against the EKS API from the self-hosted runner were unreliable and timed out even when the rollout had actually completed on the cluster. The Helm Deploy step instead fires the upgrade without waiting, then polls `kubectl rollout status --timeout=60s` up to five times with a short pause between attempts — a deploy that reports failure after all five attempts prints diagnostic `helm status`/pods/`describe pods`/PVC/`SecretProviderClass`/namespace-events output before failing the job.
>
> The init step publishes the full init output (**root token + recovery keys**) as the `vault-init-output-<environment>-<cluster>` workflow artifact (1-day retention). Download it, store the recovery keys securely per Organisation's secrets policy, then delete the artifact. There is no ADO-style approval gate on this workflow by default — if you want a manual sign-off before this step runs, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

#### Step 3C: Configure Certificate Bundle (`dpn-gha-vault-load-bundle-cd.yml`)

Trigger **Actions → DPN CD - Vault Load Cert Bundle → Run workflow**. This workflow needs the DSM client bundle set as **GitHub Actions secrets** (repository or environment level) using these exact names. Each secret's value is the exact file content:

| Secret | Content |
|-------------|---------|
| `VAULT_KEY` | Your DPN client **private key** (`vault.key`) |
| `CERTIFICATE_PEM` | The **DSM-signed certificate** (`certificate.pem`) |
| `CA_CHAIN_PEM` | The **CA chain** from DSM (`ca-chain.pem`) |

For example: `gh secret set VAULT_KEY --env <environment>-<cluster> < vault.key`.

The workflow runs: **Validate Bundle Secrets** → **Cloud Login** → **EKS Context** → **Resolve Vault Pod** (label `app=dpn-vault-https`) → **Fetch Root Token from Secrets Manager (AWS)** → **Write Bundle to Files** (also derives the public key with `openssl`) → **Copy Bundle + Script into Vault Pod** → **Delete Existing Keys in Vault** (soft KV v2 delete of the three paths) → **Load Bundle into Vault** (runs `dpn-federator-cert-manager/scripts/load-bootstrap-bundle.sh`) → **Cleanup Pod Temp Files**. It writes `pki-client/node-net/client/{keypair,certificate,ca-chain}`.

- **AWS:** authenticates with the **Vault root token**, which it reads from AWS Secrets Manager at `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN` (the secret Step 3B's Vault Init stores when `storeRootTokenInSecretsBackend: true`). If that secret is missing, the workflow fails and asks you to re-run `dpn-vault-https-cd` with `storeRootTokenInSecretsBackend=true`.

`workflow_dispatch` inputs: `environment` (`dev` / `test`), `cluster` (`dpn01` / `dpn02`), `cloud` (`aws`).

> **Prerequisites for this step:**

- Vault deployed and unsealed (Step 3B)
- Root token stored in Secrets Manager as `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN` (Step 3B with `storeRootTokenInSecretsBackend: true`)
- KV v2 enabled at `pki-client`
- Above secrets set in GitHub Actions

#### Step 3D: Deploy Certificate Manager (`dpn-gha-certificate-manager-cd.yml`)

See [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) for the full configuration and workflow inputs for this step. On AWS, run [Step 3E](#step-3e-configure-approle-authentication-dpn-certificate-manager-role-id-creationyml) for the `certificate-manager` component first — this workflow reads `dpn/<environment>-<cluster>/certificate-manager/VAULT_APPROLE_ROLE_ID` from Secrets Manager.

---

<a id="step-3e-configure-approle-authentication-planned-not-yet-available"></a>

### Step 3E: Configure AppRole Authentication (`dpn-certificate-manager-role-id-creation.yml`)

The Vault root token is a single, all-privileges credential — every component that needs it (Certificate Manager, Federator Gateway) ends up holding full access to Vault. **AppRole** is the recommended alternative: each component authenticates with its own scoped identity (a `role_id` plus a `secret_id`) and receives a short-lived, auto-renewed token restricted to that component's own policy.

> **Available for the Certificate Manager and the REST Federator Gateway.** `dpn-certificate-manager-role-id-creation.yml` (**DPN CD - Certificate Manager Role ID Creation (Vault AppRole Setup)**) takes a `component` input — `certificate-manager` (default) or `rest-federator` — and provisions a scoped AppRole identity for that component (see [Configure DPN Certificate Manager, Step2](04-configure-dpn-certificate-manager.md#step2-configure-vault-authentication) for the Certificate Manager's values). A separate `dpn-rest-federator-role-id-creation.yml` (**DPN CD - REST Federator Role ID Creation (AWS Vault AppRole Setup)**) does the same for the REST Federator only. Other Vault-consuming components (e.g. the gRPC Federator Gateway) have no AppRole setup workflow of their own.
>
> That said, Vault token authentication is **not** the only option available today: the Federator Gateway's real AWS environment already runs on AppRole by **pointing `vaultConfig.appRole.roleId` directly at the Certificate Manager's own `role_id`** and reusing its `secret_id` — no dedicated provisioning workflow needed, since the identity already exists. This shares one component's scoped credential with another rather than giving the Federator Gateway its own least-privilege policy, so treat it as a pragmatic stopgap rather than the end-state design below — but it works, and is what's actually deployed. See [Configure DPN Federator Gateway, Step1](05-configure-dpn-federator-gateway.md#step1-meet-prerequisites).

Run the workflow once per component, per environment, **after** Vault is deployed and initialised (Step 3B), via **Actions → DPN CD - Certificate Manager Role ID Creation (Vault AppRole Setup) → Run workflow**, with inputs `component` (`certificate-manager` / `rest-federator`), `environment` (`dev` / `test`), `cluster` (`dpn01` / `dpn02`) and `cloud` (`aws`). It resolves the Vault pod (`app=dpn-vault-https`), reads the admin token from Secrets Manager at `dpn/<environment>-<cluster>/vault-https/VAULT_TOKEN`, and runs the component's `setup-approle.sh` inside the Vault pod (for `certificate-manager`: `dpn-federator-cert-manager/scripts/vault/setup-approle.sh` with `certificate-manager-policy.hcl`) to:

1. Enable the `approle` auth method and write a least-privilege policy scoped to that component's own paths under `pki-client/node-net/client/*`.
2. Create/update an AppRole role bound to that policy (`token_ttl=1h`, `token_max_ttl=4h`, non-expiring `secret_id`).
3. Publish the generated **secret-id** to AWS Secrets Manager as `dpn/<environment>-<cluster>/<component>/VAULT_APPROLE_SECRET_ID` (consumed by the component's `SecretProviderClass`), and the **role-id** as `dpn/<environment>-<cluster>/<component>/VAULT_APPROLE_ROLE_ID`. The role-id is also printed in the run summary.

> **Rotation note:** the AppRole secret-id does not expire (`secret_id_ttl=0`), and Secrets Manager applies no expiry. **Re-run this workflow periodically** to rotate it, then redeploy the component to pick up the refreshed value.

On AWS, the consuming CD workflows (`dpn-gha-certificate-manager-cd.yml`, `dpn-gha-rest-federator-cd.yml`) fetch `VAULT_APPROLE_ROLE_ID` from Secrets Manager and pass it via `--set`, so you don't copy the role-id into the values file by hand.

The bundle-load workflow (Step 3C) still authenticates with the Vault root token on AWS. AppRole is for the long-running application components that read certificate material at runtime.

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
   (`seal.awsKms.*` — see
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

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
