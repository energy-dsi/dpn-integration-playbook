# DPN Vault Service Configuration

This section describes how to configure **DPN HashiCorp Vault service**. HashiCorp Vault is the secret store used by DPN Certificate Manager to hold Intermediate CA, CA chain, key pair, certificate, and keystore/truststore passwords. These secrets are used to build the certificate P12 files for mutual TLS (mTLS).

DSI provides an **automated method** (GitHub Actions workflows) that generates Vault's own TLS certificate/key and initialises Vault, run on the shared self-hosted GitHub Actions runner. This mirrors the Azure/ADO path's `dpn-tls-cd` pipeline conceptually.

> **Environment and cluster:** These instructions target one `<environment>`/`<cluster>` combination (`dev`/`test` × `dpn01`/`dpn02`). Substitute your actual values in:
>
> - config file `.github/config/azure/<environment>-<cluster>.json`
> - values file `<chart-dir>/values/azure/<environment>-<cluster>.yaml`
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
    - [Step 3A: Configure Bootstrap Vault TLS (`dpn-gha-vault-tls-bootstrap-cd.yml`)](#step-3a-configure-bootstrap-vault-tls-dpn-gha-vault-tls-bootstrap-cdyml)
    - [Step 3B: Deploy and Initialise Vault (`dpn-gha-vault-https-cd.yml`)](#step-3b-deploy-and-initialise-vault-dpn-gha-vault-https-cdyml)
    - [Step 3C: Configure Certificate Bundle (`dpn-gha-vault-load-bundle-cd.yml`)](#step-3c-configure-certificate-bundle-dpn-gha-vault-load-bundle-cdyml)
    - [Step 3D: Deploy Certificate Manager (`dpn-gha-certificate-manager-cd.yml`)](#step-3d-deploy-certificate-manager-dpn-gha-certificate-manager-cdyml)
  - [Step 3E: Configure AppRole Authentication](#step-3e-configure-approle-authentication)
- [Manual — DPN-wide TLS material (fills an automation gap)](#manual--dpn-wide-tls-material-fills-an-automation-gap)
  - [Step1: Generate the DPN universal TLS material](#step1-generate-the-dpn-universal-tls-material-1)
  - [Step2: Publish to Azure Key Vault](#step2-publish-to-azure-key-vault)
  - [Step3: Create the Kubernetes secrets](#step3-create-the-kubernetes-secrets)
  - [Step4: Load the DSM-signed certificate bundle](#step4-load-the-dsm-signed-certificate-bundle)
- [Appendix — Azure Key Vault auto-unseal configuration](#appendix--azure-key-vault-auto-unseal-configuration)
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

Vault serves over **HTTPS (TLS 1.2+)** internally and uses **Azure Key Vault auto-unseal** so it unseals itself on start-up — see [Appendix — Azure Key Vault auto-unseal configuration](#appendix--azure-key-vault-auto-unseal-configuration). DSI provides the community edition of the Vault container; organisations may substitute an enterprise edition per their licensing strategy.

Vault's own TLS bootstrap and initialisation are covered by **[Automated Vault Configuration](#automated-vault-configuration)** — GitHub Actions workflows generate that TLS material, deploy and initialise Vault, load the certificate bundle, and deploy the Certificate Manager. The DPN-wide TLS material other components depend on (`dpn-tls`, `dpn-health-tls`, `tls-auth-secret`).

> **Cloud provider note.** The `charts/vault-https` chart's templates (`templates/configmap.yaml`, `templates/secretproviderclass.yaml`) render `seal "azurekeyvault" { ... }` from `.Values.seal.azureKeyVault.*` and set `provider: azure` in the `SecretProviderClass` natively — Azure is the chart's own default `cloudProvider`, so the `charts/vault-https` Azure values files (`values/azure/<environment>-<cluster>.yaml`) are already wired into the chart's templates end-to-end: `cloudProvider: azure`, a `seal.azureKeyVault.*` stanza, a Workload Identity `serviceAccount.*` annotation set, and a `keyVault.name` — all consumed as written, with real, already-provisioned values for each environment.
>
> **Legacy plain-HTTP `vault` chart.** An older, non-TLS `vault` Helm chart and a `dpn-gha-vault-cd.yml` workflow exist alongside `vault-https`. They are **not** part of the documented/supported flow below — `vault-https` (HTTPS-only, as described in this guide) is the only Vault deployment path DSI documents and supports on this path.

### Certificate Lifecycle and Management

DPN-to-DPN and DPN-to-DSM communications are secured using mutual TLS (mTLS), meaning both parties in every connection must present a valid certificate to authenticate themselves. Each DPN therefore requires a DSI-issued certificate to participate in the network — without one, it cannot establish any connection with another DPN or with the DSM.

During initial DPN setup, a participant uploads a Certificate Signing Request (CSR) through the DSM user interface. The DSM signs the CSR and returns a bootstrap certificate bundle for download. The participant installs this bundle into their DPN's Vault via [Step 3C](#step-3c-configure-certificate-bundle-dpn-gha-vault-load-bundle-cdyml), after which certificate renewal is handled automatically — the DPN manages its own certificate lifecycle without further manual intervention under normal operating conditions.

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
| `keypair`, `certificate`, `ca-chain`, `intermediate-ca`, `keystore-password`, `truststore-password` | **Vault's own KV-v2 store** (`pki-client/node-net/client/*`) | Not a Kubernetes Secret, not Key Vault — internal to Vault itself |
| `VAULT-TLS-CERT`, `VAULT-TLS-KEY` (`keyVault.name`) | **Azure Key Vault**, synced via the CSI `SecretProviderClass` | Mounted into the Vault pod at `/vault/tls` |
| `VAULT-TLS-CERT`, `VAULT-TLS-KEY`, `VAULT-TRUSTSTORE-PASSWORD` (Step 3A's publish target) | **Azure Key Vault** | Native path — the chart's own default `cloudProvider` |
| `truststore.jks` (Step 3A output) | **Kubernetes Secret** `cert-manager-truststore` | Plain K8s object, not Key Vault |
| `vault.csr`, `server.csr`, full Step 3A working set (incl. private keys) | **GitHub Actions workflow artifact** (1-day retention) | Ephemeral CI download — download and delete, not a persistent store |
| `VAULT_TOKEN` (root token, Step 3B) | **Azure Key Vault** `VAULT-TOKEN` | Only written if `storeRootTokenInSecretsBackend: true` |
| Full Vault init output (root token + recovery keys) | **GitHub Actions workflow artifact** `vault-init-output-<environment>-<cluster>` (1-day retention) | Separate from the `VAULT_TOKEN` copy above |
| `VAULT_KEY`, `CERTIFICATE_PEM`, `CA_CHAIN_PEM` (Step 3C inputs) | **GitHub Actions secrets** (repo/environment level) | A fourth, distinct store |
| `VAULT_APPROLE_ROLE_ID`, `VAULT_APPROLE_SECRET_ID` | **Azure Key Vault**, component-suffixed name (e.g. `certificate-manager-VAULT-APPROLE-SECRET-ID`) | |

---

## Automated Vault Configuration

The automated flow uses four GitHub Actions workflows:

| Order | Workflow | Purpose |
|-------|----------|---------|
| 1 | `dpn-gha-vault-tls-bootstrap-cd.yml` | Generate the Vault server TLS certificate/key + Certificate Manager truststore, and publish them to Key Vault and Kubernetes |
| 2 | `dpn-gha-vault-https-cd.yml` | Deploy Vault via Helm, then initialise it and enable the KV v2 engine |
| 3 | `dpn-gha-vault-load-bundle-cd.yml` | Load the DSM-signed client certificate bundle into Vault |
| 4 | `dpn-gha-certificate-manager-cd.yml` | Deploy the Certificate Manager, which reads and renews certificates from Vault |

A fifth capability, **AppRole setup**, is planned but not yet available as a GitHub Actions workflow for this path — see [Step 3E](#step-3e-configure-approle-authentication).

```text
└── github-actions-pipelines/
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
| 1 | **AKS cluster** provisioned and reachable | Target cluster for the deployment |
| 2 | **Namespaces, `efs-sc` StorageClass, `federator-server` ServiceAccount, `ghcr-pull-secret`** | See [Step2.3: AKS Namespace Configuration](00-common-dpn-configuration.md#step23-aks-namespace-configuration) |
| 3 | **Azure Key Vault + Workload Identity federated credential for auto-unseal, and a Workload Identity ServiceAccount** | See [Appendix — Azure Key Vault auto-unseal configuration](#appendix--azure-key-vault-auto-unseal-configuration) — required for the pipeline path to work at all, since it has no interactive unseal step |
| 4 | **GitHub Actions OIDC federated credential** for the Azure subscription (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#azure-workload-identity--federated-identity-credential)) — the shared self-hosted runner already has `openssl`, `keytool`, `az`, `kubectl`, and `helm` | No agent setup needed per environment |
| 5 | **Environment config and values files populated** | See [Step 2](#step-2-reference-configuration-data-populate-before-deployment) |
| 6 | **DSM-signed client bundle available** | The client private key, DSM-signed certificate, and CA chain — loaded in [Step 3C](#step-3c-configure-certificate-bundle-dpn-gha-vault-load-bundle-cdyml) |

> **One-time setup:** Before running any workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration). In particular the workflows **do not create the namespace** — create it first (`kubectl create namespace <NAMESPACE>`), populate `.github/config/azure/<environment>-<cluster>.json`, and (for the bundle load) set the required GitHub Actions secrets.

---

### Step 2: Reference Configuration Data (populate before deployment)

Two files must be populated for each environment/cluster combination. **Use your own values — the examples below are placeholders only.**

#### Step 2a. Environment config JSON

The workflows resolve environment settings from `.github/config/azure/<environment>-<cluster>.json` (see [Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration)). Vault uses the following keys:

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `AZURE_SUBSCRIPTION_ID` / `ARM_SUBSCRIPTION_ID` | Azure subscription ID | `<subscription-id>` |
| `RESOURCE_GROUP` | Resource group hosting the infrastructure | `rg-aks-dpn-azure-<env>-uks-001` |
| `AKS_CLUSTER` | AKS cluster name | `aks-dpn-azure-<env>-uks-001` |
| `NAMESPACE` | Kubernetes namespace | `ns-dpn-01` |
| `KEY_VAULT_NAME` | Azure Key Vault for secrets and certificates, see [Step2.2](00-common-dpn-configuration.md#step22-azure-environment-configuration) | `kv-dpn-azure-<env>-uks-001` |

#### Step 2b. Vault Helm values

Set the values below in your environment/cluster's values file. DSI proposes only these selective changes; other parameters may be customised if required.

```text
root/
  └── charts/
        └── vault-https/  
          └── values/
              └── azure/          
                 └──<environment>-<cluster>.yaml <- Your environment overrides
```

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cloudProvider` | **Set to `azure`.** Selects Azure Key Vault auto-unseal, the Workload Identity ServiceAccount, the Azure-native `SecretProviderClass`, and the Load Balancer service annotations below; this is also the chart's own default | `azure` |
| `image.repository` | Complete URL of the Vault image | `ghcr.io/energy-dsi/vault` |
| `image.tag` | Vault image tag (also overridable at runtime) | `1.16` |
| `namespace` | Kubernetes namespace | `ns-dpn-01` |
| `persistence.storageClassName` | Persistent volume StorageClass — an Azure Disk-backed class (`managed-csi`/`managed-premium`), **not** the `efs-sc`/Azure Files class used by Certificate Manager's file share; Vault needs a `ReadWriteOnce` volume | `managed-csi` |
| `seal.azureKeyVault.vaultName` | Azure Key Vault used for auto-unseal | `<KEY_VAULT_NAME>` |
| `seal.azureKeyVault.keyName` | Auto-unseal key name within Key Vault | `dpn-vault-unseal` |
| `serviceAccount.create` | Create the Workload Identity-annotated ServiceAccount used for Key Vault auto-unseal | `true` |
| `serviceAccount.name` | ServiceAccount name (default `dpn-vault`) | `dpn-vault` |
| `serviceAccount.clientId` | Workload Identity (Federated Identity Credential) client ID scoped to `system:serviceaccount:<namespace>:<serviceAccount.name>`, granting `get`/`wrapKey`/`unwrapKey` on the unseal key | `<AZURE_CLIENT_ID>` |
| `keyVault.name` | Azure Key Vault the CSI `SecretProviderClass` reads the Vault TLS cert/key from (`VAULT-TLS-CERT`, `VAULT-TLS-KEY`), mounted at `/vault/tls` via the pod's Workload Identity | `<KEY_VAULT_NAME>` |

> **Note:** Keep `replicaCount: 1` — Vault uses a `ReadWriteOnce` persistent volume. The Vault TLS certificate and key are **not** set as literal values here; they are generated in [Step 3A](#step-3a-configure-bootstrap-vault-tls-dpn-gha-vault-tls-bootstrap-cdyml) and read at runtime via the `SecretProviderClass`.

---

### Step 3: Deployment Configuration

Trigger the following workflows in order, via **Actions → &lt;workflow name&gt; → Run workflow** . Each resolves `.github/config/azure/<environment>-<cluster>.json` and the matching Helm values file automatically from the `environment`/`cluster`/`cloud` inputs.

#### Step 3A: Configure Bootstrap Vault TLS (`dpn-gha-vault-tls-bootstrap-cd.yml`)

This workflow generates a Root CA, the Vault server certificate/key, and the Certificate Manager truststore in a single run, then publishes them to Key Vault and Kubernetes.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `country` | CSR subject Country (C) — default `GB` |
| `org` | CSR subject Organisation (O) — default `DSI` |
| `sans` | Comma-separated DNS SANs for the Vault URL. **Must include the internal Kubernetes DNS name**, e.g. `vault-https.<namespace>.svc.cluster.local` |

> **Truststore password comes from a repository secret, not a workflow input.** The truststore password is read from the repository secret `DPN_TLS_TRUSTSTORE_PASSWORD` (the same secret `dpn-tls-cd.yaml` uses) and published to Key Vault as `VAULT-TRUSTSTORE-PASSWORD`. There is no `truststorePassword` workflow input — GitHub Actions has no secret-typed `workflow_dispatch` input, and a plain string input would always be visible in the "Run workflow" form regardless of log masking. Set `DPN_TLS_TRUSTSTORE_PASSWORD` as a repository (or environment) secret before running this workflow.

On completion it publishes:
- `VAULT-TLS-CERT`, `VAULT-TLS-KEY`, `VAULT-TRUSTSTORE-PASSWORD` → Azure Key Vault
- `truststore.jks` → Kubernetes secret `cert-manager-truststore`
- The full working set (including private keys) as a 1-day-retention workflow artifact — download and secure it, then delete the artifact
- `vault.csr` → CSR file for doing bootstrap from DSM
- `server.csr` → CSR file for server certificate. Although vault.csr can be used as well for server certificate with large TTL

#### Step 3B: Deploy and Initialise Vault (`dpn-gha-vault-https-cd.yml`)

This workflow deploys the `vault-https` Helm chart and runs: **Checkout** → **Cloud Login** (also establishes the AKS context) → **AKS Context** (a second, retried connectivity check with diagnostics — the shared self-hosted runner's connection to a given cluster's VNet is not always reliable) → **Helm Lint + Dry Run** → **Helm Deploy** (`helm upgrade --install`) → **Vault HTTPS Seal Status Check** → **Vault Init** (runs `vault-init.sh` to enable the KV v2 engine at `pki-client` and audit logging).

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `vaultImageTag` | Vault image tag (default `1.16`) |
| `vaultImageRepository` | Optional — overrides `image.repository` for this run only (path after `ghcr.io/energy-dsi/`) |
| `runVaultInit` | Run the init step (default `true`; idempotent — safe to re-run on an existing vault) |
| `storeRootTokenInSecretsBackend` | Store the Vault root token in the cloud secrets backend. On Azure this stores `VAULT-TOKEN` in Key Vault. **Set `true` on the first deploy** if you intend to authenticate the bundle-load workflow (Step 3C) with the root token |

> **Auto-unseal is what makes this workflow viable — set it up before this step, not after.** The pipeline has no interactive unseal step; if Vault comes back sealed, the Vault Init step will simply fail. Configure **Azure Key Vault auto-unseal** (`seal.azureKeyVault.*` and the `serviceAccount.*` Workload Identity wiring in the chart's Azure values — [Step 2b](#step-2b-vault-helm-values)) before running this workflow; see [Appendix](#appendix--azure-key-vault-auto-unseal-configuration) for the exact Key Vault key/Workload Identity setup.
>
> **No `--wait`/`--timeout` on `helm upgrade` for this path.** Long-lived watches against the AKS API from the self-hosted runner were unreliable and timed out even when the rollout had actually completed on the cluster. The Helm Deploy step instead fires the upgrade without waiting, then polls `kubectl rollout status --timeout=60s` up to five times with a short pause between attempts — a deploy that reports failure after all five attempts prints diagnostic `helm status`/pods/`describe pods`/PVC/`SecretProviderClass`/namespace-events output before failing the job.
>
> The init step publishes the full init output (**root token + recovery keys**) as the `vault-init-output-<environment>-<cluster>` workflow artifact (1-day retention). Download it, store the recovery keys securely per Organisation's secrets policy, then delete the artifact. There is no ADO-style approval gate on this workflow by default — if you want a manual sign-off before this step runs, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

#### Step 3C: Configure Certificate Bundle (`dpn-gha-vault-load-bundle-cd.yml`)

This workflow needs the DSM client bundle set as **GitHub Actions secrets** (repository or environment level) using these exact names:

| Secret | Content |
|-------------|---------|
| `VAULT_KEY` | Your DPN client **private key** |
| `CERTIFICATE_PEM` | The **DSM-signed certificate** |
| `CA_CHAIN_PEM` | The **CA chain** from DSM |

The workflow resolves the Vault pod, obtains a Vault token, and writes `pki-client/node-net/client/{keypair,certificate,ca-chain}`.

**Azure:** reads the Vault root token from Key Vault (`VAULT-TOKEN`, placed by Step 3B with `storeRootTokenInSecretsBackend: true`).

`workflow_dispatch` inputs: `environment`, `cluster`, `cloud`.

> **Prerequisites for this step:**

- Vault deployed and unsealed (Step 3B)
- KV v2 enabled at `pki-client`
- Above secrets set in GitHub Actions
- `VAULT-TOKEN` present in Key Vault (from Step 3B with `storeRootTokenInSecretsBackend: true`)

#### Step 3D: Deploy Certificate Manager (`dpn-gha-certificate-manager-cd.yml`)

See [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) for the full configuration and workflow inputs for this step.

---

### Step 3E: Configure AppRole Authentication

The Vault root token is a single, all-privileges credential — every component that needs it (Certificate Manager, Federator Gateway) ends up holding full access to Vault. **AppRole** is the recommended alternative: each component authenticates with its own scoped identity (a `role_id` plus a `secret_id`) and receives a short-lived, auto-renewed token restricted to that component's own policy.

> **Certificate Manager approle** 

`dpn-gha-certificate-manager-role-id-creation.yml` exists today and provisions a scoped AppRole identity for the `certificate-manager` component specifically (see [Configure DPN Certificate Manager, Step2](04-configure-dpn-certificate-manager.md#step2-configure-vault-authentication) for the authoritative, up-to-date description, including its Azure Key Vault output names) — it's also used by [Step 3C](#step-3c-configure-certificate-bundle-dpn-gha-vault-load-bundle-cdyml) above to authenticate the bundle-load workflow on Azure. A dedicated, generic per-component AppRole-setup workflow for **other** Vault-consuming components (e.g. the Federator Gateway). The design below documents the intended behaviour for those components so they can adopt the same pattern once a workflow is added for them.
>
> That said, Vault token authentication is **not** the only option available today: the Federator Gateway's real Azure environment already runs on AppRole by **pointing `vaultConfig.appRole.roleId` directly at the Certificate Manager's own `role_id`** and reusing its `secret_id` — no dedicated provisioning workflow needed, since the identity already exists. This shares one component's scoped credential with another rather than giving the Federator Gateway its own least-privilege policy, so treat it as a pragmatic stopgap rather than the end-state design below — but it works, and is what's actually deployed. See [Configure DPN Federator Gateway, Step1](05-configure-dpn-federator-gateway.md#step1-meet-prerequisites).

Once available, the workflow would run once per component, per environment, **after** Vault is deployed and initialised (Step 3B), taking `environment`, `cluster`, `cloud`, and `component` (the Vault-consuming component to provision an AppRole identity for, e.g. `certificate-manager`) as inputs. It would run `setup-approle.sh` inside the Vault pod, using the admin token from Azure Key Vault (`VAULT-TOKEN`), to: 

1. Write a least-privilege policy scoped to that component's own paths under `pki-client/node-net/client/*`.
2. Create/update an AppRole role bound to that policy (`token_ttl=1h`, `token_max_ttl=4h`, non-expiring `secret_id`).
3. Publish the generated **secret-id** to Azure Key Vault, component-suffixed (e.g. `<component>-VAULT-APPROLE-SECRET-ID`) consumed automatically by the component's `SecretProviderClass`, and print the **role-id** for you to copy into that component's Helm values.

> **Key Vault governance note:** the `VAULT-APPROLE-SECRET-ID` Key Vault secret is stamped with a 355-day expiry to satisfy Key Vault's maximum-validity policy. The underlying Vault secret-id itself does not expire — **re-run this pipeline before the Key Vault copy expires** to rotate it, then redeploy the component to pick up the refreshed value.

To switch a component over once its AppRole identity exists, set in its environment values file:

```yaml
vault:
  authMethod: approle   # was: token
  appRole:
    roleId: <role_id from the setup output>
    useSecretIdRef: true
    secretIdSecretName: <component>-secrets # synced from Key Vault via the CSI driver
    secretIdSecretKey: VAULT_APPROLE_SECRET_ID
```

`token` remains required for the bundle-load workflow (Step 3C) regardless, which authenticates as the Vault admin — AppRole (once available) would be for the long-running application components that read certificate material at runtime.

---

## Manual — DPN-wide TLS material (fills an automation gap)

On the Azure/ADO path, a single pipeline (`dpn-tls-cd`) generates one self-signed Root CA and one wildcard server certificate, then publishes it in every format the platform needs — Vault's own PEM listener cert, plus the `dpn-tls`, `dpn-health-tls`, and `tls-auth-secret` Kubernetes secrets that Keycloak, Kafka, both Federators, Airflow, and the health-monitoring `oauth2-proxy` gateways all read from. **No equivalent GitHub Actions workflow exists for this path yet** — `dpn-gha-vault-tls-bootstrap-cd.yml` only ever produces Vault's own TLS cert/key and `cert-manager-truststore`, unchanged from the flow `dpn-tls-cd` provides on the ADO path.

Despite that, the Azure values files for Federator Gateway, Health Monitoring's Kafka UI/OTel collector, and Data Pipelines' Airflow **already reference `dpn-tls` and `dpn-health-tls`** as pre-existing secrets, and the Certificate Manager's Azure values file expects a pre-existing `certificate-manager-secrets` secret (`existingSecret.name: "certificate-manager-secrets"`). Until an automated workflow is added for this GitHub Actions path, an organisation deploying on Azure via this pipeline must create all of these by hand, once per environment/cluster — this section shows how, mirroring exactly what `dpn-tls-cd` does on the ADO path (see [the ADO edition of this guide](../../azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md#step1-generate-the-dpn-universal-tls-material) for the same steps in ADO-pipeline form).

### Step1: Generate the DPN universal TLS material

Identical to the ADO path — the material is plain X.509/PKCS12, with no pipeline-specific content. The three fixed wildcard SANs (`*.ns-dpn-01`, `*.ns-dpn-health-01`, `*.ns-dpn-dp-01.svc.cluster.local`) are internal Kubernetes service DNS names on AKS exactly as they are under the ADO pipeline — no change needed here.

**Step 1a — Set the required inputs and create the working directory:**

```bash
export COUNTRY="<Your Country>"          # subject C, e.g. GB
export ORG="<Your Org>"                  # subject O
export KEYSTORE_PASS="<choose-a-password>"     # -> Key Vault KEYSTORE_PASSWORD
export TRUSTSTORE_PASS="<choose-a-password>"   # -> Key Vault TRUSTSTORE_PASSWORD
export CLIENT_P12_PASS="<choose-a-password>"   # -> Key Vault DPN_CLIENT_P12_PASSWORD
export EXTRA_VAULT_SANS=""               # optional, comma-separated participant SANs for the DSM CSR only

OUT_DIR="dpn-tls"
CA_DIR="$OUT_DIR/ca"; CERTS_DIR="$OUT_DIR/certs"
mkdir -p "$CA_DIR" "$CERTS_DIR"
SUBJ_BASE="/C=$COUNTRY/O=$ORG"
```

**Step 1b — DPN Root CA (self-signed, `CN=dpn-root`):**

```bash
openssl genrsa -out "$CA_DIR/dpn-root.key" 4096
openssl req -x509 -new -nodes -key "$CA_DIR/dpn-root.key" -sha256 \
  -days 3650 -subj "$SUBJ_BASE/CN=dpn-root" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$CA_DIR/dpn-root.crt"
```

**Step 1c — Common server cert (`CN=dpn-common`, wildcard SANs).** This is the universal cert every in-cluster TLS endpoint shares. Create `$CERTS_DIR/server-openssl.cnf`:

```text
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = v3_server

[ dn ]
C  = <Your Country>
O  = <Your Org>
CN = dpn-common

[ v3_server ]
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[ alt_names ]
DNS.1 = *.ns-dpn-01.svc.cluster.local
DNS.2 = *.ns-dpn-health-01.svc.cluster.local
DNS.3 = *.ns-dpn-dp-01.svc.cluster.local
```

```bash
openssl genrsa -out "$CERTS_DIR/server.key" 4096
openssl req -new -key "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.csr" \
  -config "$CERTS_DIR/server-openssl.cnf"
openssl x509 -req -in "$CERTS_DIR/server.csr" \
  -CA "$CA_DIR/dpn-root.crt" -CAkey "$CA_DIR/dpn-root.key" -CAcreateserial \
  -days 825 -sha256 \
  -extfile "$CERTS_DIR/server-openssl.cnf" -extensions v3_server \
  -out "$CERTS_DIR/server.crt"
```

**Step 1d — `keystore.jks`, alias `dpn-server`** (this alias is load-bearing — Keycloak's chart sets `KC_HTTPS_KEY_ALIAS=dpn-server` to match it):

```bash
openssl pkcs12 -export \
  -in "$CERTS_DIR/server.crt" -inkey "$CERTS_DIR/server.key" \
  -certfile "$CA_DIR/dpn-root.crt" -name dpn-server \
  -out "$CERTS_DIR/server.p12" -passout pass:"$KEYSTORE_PASS"
keytool -importkeystore -noprompt \
  -srckeystore "$CERTS_DIR/server.p12" -srcstoretype PKCS12 -srcstorepass "$KEYSTORE_PASS" \
  -destkeystore "$OUT_DIR/keystore.jks" -deststoretype PKCS12 -deststorepass "$KEYSTORE_PASS" \
  -srcalias dpn-server -destalias dpn-server
```

**Step 1e — Client CA + `dpn-client.p12`** (browser/external mTLS client identity):

```bash
openssl genrsa -out "$CA_DIR/dpn-client-ca.key" 4096
openssl req -x509 -new -nodes -key "$CA_DIR/dpn-client-ca.key" -sha256 \
  -days 3650 -subj "$SUBJ_BASE/CN=dpn-client-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$CA_DIR/dpn-client-ca.crt"

cat > "$CERTS_DIR/client-openssl.cnf" <<'EOF'
[ v3_client ]
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out "$CERTS_DIR/dpn-client.key" 4096
openssl req -new -key "$CERTS_DIR/dpn-client.key" \
  -subj "$SUBJ_BASE/CN=dpn-client" -out "$CERTS_DIR/dpn-client.csr"
openssl x509 -req -in "$CERTS_DIR/dpn-client.csr" \
  -CA "$CA_DIR/dpn-client-ca.crt" -CAkey "$CA_DIR/dpn-client-ca.key" -CAcreateserial \
  -days 365 -sha256 \
  -extfile "$CERTS_DIR/client-openssl.cnf" -extensions v3_client \
  -out "$CERTS_DIR/dpn-client.crt"
openssl pkcs12 -export \
  -in "$CERTS_DIR/dpn-client.crt" -inkey "$CERTS_DIR/dpn-client.key" \
  -name dpn-client -out "$OUT_DIR/dpn-client.p12" -passout pass:"$CLIENT_P12_PASS"
```

**Step 1f — `truststore.jks`** (Root CA + Client CA as trust anchors):

```bash
keytool -import -trustcacerts -noprompt -alias dpn-root \
  -file "$CA_DIR/dpn-root.crt" -keystore "$OUT_DIR/truststore.jks" \
  -storetype PKCS12 -storepass "$TRUSTSTORE_PASS"
keytool -import -trustcacerts -noprompt -alias dpn-client-ca \
  -file "$CA_DIR/dpn-client-ca.crt" -keystore "$OUT_DIR/truststore.jks" \
  -storetype PKCS12 -storepass "$TRUSTSTORE_PASS"
```

**Step 1g — Vault's own DSM bootstrap CSR (`CN=vault`, unsigned).** Same three wildcard SANs, plus any participant-specific SANs your DSM PKI role allows:

```bash
cat > "$CERTS_DIR/vault-openssl.cnf" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C  = $COUNTRY
O  = $ORG
CN = vault

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = *.ns-dpn-01.svc.cluster.local
DNS.2 = *.ns-dpn-health-01.svc.cluster.local
DNS.3 = *.ns-dpn-dp-01.svc.cluster.local
EOF
# append DNS.4, DNS.5, ... here for each host in EXTRA_VAULT_SANS, if any

openssl genrsa -out "$CERTS_DIR/vault.key" 4096
openssl req -new -key "$CERTS_DIR/vault.key" -out "$CERTS_DIR/vault.csr" -config "$CERTS_DIR/vault-openssl.cnf"
```

You'll end up with these artefacts:

| Artefact | Consumed by |
|---|---|
| `certs/server.crt` + `certs/server.key` | Vault's own HTTPS listener |
| `keystore.jks` (alias `dpn-server`) | Keycloak, Kafka, Federator Gateway — via `dpn-tls` |
| `truststore.jks` (Root CA + Client CA) | Certificate Manager, Keycloak, Kafka, Federator — via `cert-manager-truststore` and `dpn-tls` |
| `dpn-client.p12` | Browser / external mTLS client install |
| `certs/vault.csr` + `certs/vault.key` | Sign at the DSM Vault, then load in [Step4](#step4-load-the-dsm-signed-certificate-bundle) |

### Step2: Publish to Azure Key Vault

This mirrors [Step 3B](#step-3b-deploy-and-initialise-vault-dpn-gha-vault-https-cdyml)'s `keyVault.name` convention for the two values that convention already covers, and extends it with a platform-level naming convention for the three passwords — there is no established convention for those yet on this path, so treat the `dpn-tls-` prefix below as a proposed name; align it with whatever an eventual automated workflow standardises on.

```bash
KEY_VAULT_NAME="<KEY_VAULT_NAME>"

az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "vault-https-VAULT-TLS-CERT" --file certs/server.crt
az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "vault-https-VAULT-TLS-KEY" --file certs/server.key

az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "dpn-tls-KEYSTORE-PASSWORD" --value "$KEYSTORE_PASS"
az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "dpn-tls-TRUSTSTORE-PASSWORD" --value "$TRUSTSTORE_PASS"
az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "dpn-tls-DPN-CLIENT-P12-PASSWORD" --value "$CLIENT_P12_PASS"
```

As on the ADO path, `KEYCLOAK-ADMIN-PASSWORD` / `KC-DB-PASSWORD` / `KC-SERVICE-CLIENT-SECRET` are not cert material and are not covered here — set those separately per [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md) and [Configure DPN Health Monitoring Service](03-configure-dpn-health-monitoring-service.md).

### Step3: Create the Kubernetes secrets

Until a dedicated GitHub Actions workflow exists for this path (see the gap noted above), the components read these as plain Kubernetes secrets you create directly — the same shape `dpn-tls-cd` creates on the ADO path, plus `certificate-manager-secrets`, which the Certificate Manager's Azure values file (`existingSecret.name: "certificate-manager-secrets"`) expects to find already in place rather than syncing via CSI:

```bash
NS="<targetNamespace>"        # e.g. ns-dpn-01
HEALTH_NS="ns-dpn-health-01"  # fixed — health monitoring always runs here

kubectl delete secret cert-manager-truststore -n "$NS" --ignore-not-found
kubectl create secret generic cert-manager-truststore \
  --namespace "$NS" --from-file=truststore.jks="$OUT_DIR/truststore.jks"

for ns in "$NS" "$HEALTH_NS"; do
  kubectl delete secret dpn-tls -n "$ns" --ignore-not-found
  kubectl create secret generic dpn-tls \
    --namespace "$ns" \
    --from-file=ca.crt="$CA_DIR/dpn-root.crt" \
    --from-file=keystore.jks="$OUT_DIR/keystore.jks" \
    --from-file=truststore.jks="$OUT_DIR/truststore.jks"
done

for ns in "$HEALTH_NS" "$NS"; do
  kubectl delete secret dpn-health-tls -n "$ns" --ignore-not-found
  kubectl create secret generic dpn-health-tls \
    --type=kubernetes.io/tls --namespace "$ns" \
    --from-file=tls.crt="$CERTS_DIR/server.crt" \
    --from-file=tls.key="$CERTS_DIR/server.key" \
    --from-file=ca.crt="$CA_DIR/dpn-root.crt"
done

for ns in "$NS" "$HEALTH_NS"; do
  kubectl delete secret tls-auth-secret -n "$ns" --ignore-not-found
  kubectl create secret generic tls-auth-secret \
    --namespace "$ns" \
    --from-literal=KEYSTORE_PASSWORD="$KEYSTORE_PASS" \
    --from-literal=TRUSTSTORE_PASSWORD="$TRUSTSTORE_PASS" \
    --from-literal=DPN_CLIENT_P12_PASSWORD="$CLIENT_P12_PASS"
done

# Certificate Manager's own auth credential — value depends on vault.authentication
# in its values file (APPROLE or TOKEN). Fetch whichever applies from Key Vault
# once Step 3E / the role-id-creation workflow has produced it, then:
kubectl delete secret certificate-manager-secrets -n "$NS" --ignore-not-found
kubectl create secret generic certificate-manager-secrets \
  --namespace "$NS" \
  --from-literal=VAULT_APPROLE_SECRET_ID="<secret_id, if vault.authentication=APPROLE>"
  # or: --from-literal=VAULT_TOKEN="<root token, if vault.authentication=TOKEN>"
```

### Step4: Load the DSM-signed certificate bundle

Once `vault-https` is actually deployed and unsealed, sign `certs/vault.csr` at the DSM Vault to get `certificate.pem` + `ca-chain.pem`, then load the bundle exactly as [Step6 of the ADO edition](../../azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md#step6-load-the-dsm-signed-certificate-bundle) does — the `vault kv put pki-client/node-net/client/*` commands are identical on this path; only how you obtain the Vault token differs (root token from wherever [Step 3B](#step-3b-deploy-and-initialise-vault-dpn-gha-vault-https-cdyml) stored it, or an AppRole login using the Certificate Manager's `role_id`/`secret_id` from Key Vault, matching what [Step 3C](#step-3c-configure-certificate-bundle-dpn-gha-vault-load-bundle-cdyml) already does for the automated path).

---

## Appendix — Azure Key Vault auto-unseal configuration

This is a **required prerequisite**, not an optional add-on — per [Step 3B](#step-3b-deploy-and-initialise-vault-dpn-gha-vault-https-cdyml) above, the pipeline has no interactive unseal step, so without this Vault comes back sealed after every pod restart and the Vault Init step fails outright. Set this up as part of [Step 1](#step-1-prerequisites-before-vault-can-be-deployed), before your first run of `dpn-gha-vault-https-cd.yml`:

1. Create a key in Azure Key Vault, e.g. `dpn-vault-unseal`, in the Key Vault referenced by `KEY_VAULT_NAME`.
2. Create a **Federated Identity Credential** on a Microsoft Entra ID application/user-assigned managed identity that trusts
   `system:serviceaccount:ns-dpn-01:<serviceAccount.name>` (the dedicated
   Vault ServiceAccount, default `dpn-vault` — **not** `federator-server`),
   granting `get`, `wrapKey`, `unwrapKey` on that key via a Key Vault access policy or RBAC role assignment.
3. Set `serviceAccount.create: true`, `serviceAccount.name`, and
   `serviceAccount.clientId` (that identity's client ID) in the chart's
   `values/azure/<environment>-<cluster>.yaml` — the chart creates and
   annotates the ServiceAccount for you (see [Step 2b](#step-2b-vault-helm-values)).
4. Add a seal stanza to the same values file
   (`seal.azureKeyVault.*` — see
   [Step 2b](#step-2b-vault-helm-values)):
   ```hcl
   seal "azurekeyvault" {
     vault_name = "<KEY_VAULT_NAME>"
     key_name   = "dpn-vault-unseal"
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
| Oct-2026 | DSI Assurance | Final | V1.0.0 |
