# DPN Vault Service Configuration

This section describes how to configure **DPN HashiCorp Vault service**. HashiCorp Vault is the secret store used by DPN Certificate Manager to hold Intermediate CA, CA chain, key pair, certificate, and keystore/truststore passwords. These secrets are used to build the certificate P12 files for mutual TLS (mTLS).

DSI provides an **automated method** (GitHub Actions workflows in `dpn-containerised-deployment-service`) that generates the required CSR, certificate, and key material and configures Vault end to end. This is the preferred approach for this airgapped Azure path. A **manual fallback** is also provided for organisations that cannot run the automated pipeline due to certain limitations.

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
    - [Step 2a. Environment config JSON — `config/<env>.json`](#step-2a-environment-config-json--configenvjson)
    - [Step 2b. Vault Helm values — `charts/vault-https/values-<env>.yaml`](#step-2b-vault-helm-values--chartsvault-httpsvalues-envyaml)
  - [Step 3: Deployment Configuration](#step-3-deployment-configuration)
    - [Step 3A: Configure Bootstrap Vault TLS (`vault-tls-bootstrap-cd`)](#step-3a-configure-bootstrap-vault-tls-vault-tls-bootstrap-cd)
    - [Step 3B: Configuration to Initialise Vault (`vault-https-cd`)](#step-3b-configuration-to-initialise-vault-vault-https-cd)
    - [Step 3C: Configure Certificate Bundle (`vault-load-bundle-cd`)](#step-3c-configure-certificate-bundle-vault-load-bundle-cd)
    - [Step 3D: Configure AppRole Authentication (planned, not yet available)](#step-3d-configure-approle-authentication-planned-not-yet-available)
- [Manual Vault Configuration (Fallback)](#manual-vault-configuration-fallback)
  - [Step1: Generate the Vault TLS material](#step1-generate-the-vault-tls-material)
  - [Step2: Publish the TLS material](#step2-publish-the-tls-material)
  - [Step3: Deploy Vault and enable KV v2](#step3-deploy-vault-and-enable-kv-v2)
  - [Step4: Load the certificate bundle](#step4-load-the-certificate-bundle)
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

Vault serves over **HTTPS (TLS 1.2+)** internally and uses **Azure Key Vault auto-unseal** in the automated approach, so it unseals itself on start-up. In case of manual process the unseal key needs to be created separately. DSI provides the community edition of the Vault container; organisations may substitute an enterprise edition per their licensing strategy.

Two Vault setup methods are available:

- **[Automated Vault Configuration](#automated-vault-configuration)** *(recommended)* — three GitHub Actions workflows generate the TLS material, deploy and initialise Vault, and load the certificate bundle.

- **[Manual Vault Configuration (Fallback)](#manual-vault-configuration-fallback)** — the equivalent steps performed by hand with OpenSSL / `keytool` / `kubectl`.

---

## Automated Vault Configuration

The automated flow uses three GitHub Actions workflows in `dpn-containerised-deployment-service`:

| Order | Workflow | Purpose |
|-------|----------|---------|
| 1 | `dpn-vault-tls-bootstrap-cd.yml` | Generate the Vault server TLS certificate/key + Certificate Manager truststore, and publish them to Key Vault and Kubernetes |
| 2 | `dpn-vault-https-cd.yml` | Deploy Vault via Helm, then initialise it and enable the KV v2 engine |
| 3 | `dpn-vault-load-bundle-cd.yml` | Load the DSM-signed client certificate bundle into Vault |

A fourth capability, **AppRole setup**, is planned but not yet available as a GitHub Actions workflow for this path — see [Step 3D](#step-3d-configure-approle-authentication-planned-not-yet-available).

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        ├── dpn-vault-tls-bootstrap-cd.yml
        ├── dpn-vault-https-cd.yml
        └── dpn-vault-load-bundle-cd.yml
```

---

### Step 1: Prerequisites (before Vault can be deployed)

Ensure the following are in place **before** running any pipeline:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **AKS cluster** provisioned and reachable | Target cluster for the deployment |
| 2 | **Azure Key Vault** provisioned | Stores the Vault TLS material, the auto-unseal key, and the Vault root token |
| 3 | **Auto-unseal key** `vault-unseal-key` created in the Key Vault | An RSA **key** (not a secret) used by Vault's Azure Key Vault seal to auto-unseal. Create once: `az keyvault key create --vault-name <KEY_VAULT_NAME> --name vault-unseal-key --kty RSA` |
| 4 | **User-assigned managed identity** with access to the Key Vault | Needs *get* on secrets and *wrap/unwrap* on the unseal key. Its client ID is used for both auto-unseal and the CSI driver |
| 5 | **Secrets Store CSI driver** (Azure provider) enabled on AKS | Vault mounts its TLS cert/key from Key Vault via CSI |
| 6 | **GitHub Actions OIDC federated credential** for the subscription (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md#github-actions-oidc-federated-credential)) — the shared self-hosted runner already has `openssl`, `keytool`, `az`, `kubectl`, `kubelogin`, and `helm` | No agent setup needed per environment |
| 7 | **Environment config and values files populated** | See [Step 2](#step-2-reference-configuration-data-populate-before-deployment) |
| 8 | **DSM-signed client bundle available** | The client private key, DSM-signed certificate, and CA chain — loaded in [Step 3C](#step-3-deployment-configuration) |

> **One-time setup:** Before running any workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration). In particular the workflows **do not create the namespace** — create it first (`kubectl create namespace <NAMESPACE>`), populate `.github/config/azure/<environment>-<cluster>.json`, and (for the bundle load) set the required GitHub Actions secrets.

---

### Step 2: Reference Configuration Data (populate before deployment)

Two files must be populated for each environment. **Use your own values — the examples below are placeholders only.**

#### Step 2a. Environment config JSON — `.github/config/azure/<environment>-<cluster>.json`

The workflows resolve environment settings from this file (see [Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration)). Vault uses the following keys (both subscription-ID keys are present in the sample config and should match your subscription):

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `AZURE_SUBSCRIPTION_ID` / `ARM_SUBSCRIPTION_ID` | Subscription hosting the infrastructure | `<subscription-id>` |
| `RESOURCE_GROUP` | Resource group containing the AKS cluster | `rg-<env>-uks-dpn-01` |
| `AKS_CLUSTER` | AKS cluster name | `aks-<env>-uks-dpn-01` |
| `NAMESPACE` | Kubernetes namespace | `ns-dpn-01` |
| `KEY_VAULT_NAME` | Azure Key Vault for secrets and certificates | `kv-dpn-<env>-<region>-<seq>` |

#### Step 2b. Vault Helm values — `charts/vault-https/values/azure/<environment>-<cluster>.yaml`

Set the values below in your environment/cluster's values file. DSI proposes only these selective changes; other parameters may be customised if required.

```text
dpn-federator-cert-manager/
  └── charts/
        └── vault-https/
              ├── values.yaml                              <- Reference file; do not edit directly
              └── values/azure/<environment>-<cluster>.yaml <- Your environment overrides
```

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `image.repository` | Complete URL of the Vault image | `<DSI public image repository>/hashicorp/vault` |
| `image.tag` | Vault image tag (also overridable at runtime) | `1.16` |
| `namespace` | Kubernetes namespace | `ns-dpn-01` |
| `seal.azureKeyVault.tenantId` | Tenant ID of the auto-unseal Key Vault | `<tenant-id>` |
| `seal.azureKeyVault.clientId` | Managed-identity client ID used for auto-unseal | `<managed-identity-client-id>` |
| `seal.azureKeyVault.keyVaultName` | Auto-unseal Key Vault name | `kv-dpn-<env>-<region>-<seq>` |
| `seal.azureKeyVault.keyName` | Auto-unseal key name | `vault-unseal-key` |
| `keyvault.tenantId` | Tenant ID of the TLS-cert Key Vault (CSI) | `<tenant-id>` |
| `keyvault.clientID` | Managed-identity client ID used by the CSI driver | `<managed-identity-client-id>` |
| `keyvault.name` | TLS-cert Key Vault name (CSI) | `kv-dpn-<env>-<region>-<seq>` |

> **Note:** Keep `replicaCount: 1` — Vault uses a `ReadWriteOnce` persistent volume. The Vault TLS certificate and key are **not** set here; they are generated and published to Key Vault in [Step 3A](#step-3-deployment-configuration) and mounted into the pod via the CSI driver.

---

### Step 3: Deployment Configuration

Trigger the following three workflows in order, via **Actions → &lt;workflow name&gt; → Run workflow** in `dpn-containerised-deployment-service`. Each resolves `.github/config/azure/<environment>-<cluster>.json` and the matching Helm values file automatically from the `environment`/`cluster`/`cloud` inputs.

#### Step 3A: Configure Bootstrap Vault TLS (`dpn-vault-tls-bootstrap-cd.yml`)

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
| `truststorePassword` | Password published to Key Vault as `VAULT-TRUSTSTORE-PASSWORD` — default `changeit` |

On completion it publishes:
- `VAULT-TLS-CERT`, `VAULT-TLS-KEY`, `VAULT-TRUSTSTORE-PASSWORD` → Azure Key Vault
- `truststore.jks` → Kubernetes secret `cert-manager-truststore`
- The full working set (including private keys) as a 1-day-retention workflow artifact — download and secure it, then delete the artifact

#### Step 3B: Configuration to Initialise Vault (`dpn-vault-https-cd.yml`)

This workflow deploys the `vault-https` Helm chart and runs: **Helm Lint + Dry Run** → **Helm Deploy** (`helm upgrade --install`) → **Vault HTTPS Seal Status Check** → **Vault Init** (runs `vault-init.sh` to enable the KV v2 engine at `pki-client` and audit logging).

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `vaultImageTag` | Vault image tag (default `1.16`) |
| `runVaultInit` | Run the init step (default `true`; idempotent — safe to re-run on an existing vault) |
| `storeRootTokenInAkv` | Store the Vault root token in Key Vault as `VAULT-TOKEN`. **Set `true` on the first deploy** — the bundle-load workflow (Step 3C) always needs it, even if the Certificate Manager and Federator Gateway are subsequently switched to AppRole (Step 3D) |

> **Important:** The init step publishes the full init output (**root token + recovery keys**) as the `vault-init-output-<environment>-<cluster>` workflow artifact (1-day retention). Download it, store the recovery keys securely per Organisation's secrets policy, then delete the artifact. There is no ADO-style approval gate on this workflow by default — if you want a manual sign-off before this step runs, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

#### Step 3C: Configure Certificate Bundle (`dpn-vault-load-bundle-cd.yml`)

This workflow needs the DSM client bundle set as **GitHub Actions secrets** (repository or environment level) using these exact names, then run the workflow:

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

---

### Step 3D: Configure AppRole Authentication (planned, not yet available)

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

## Manual Vault Configuration (Fallback)

Use this method only if the organisation cannot run the automated GitHub Actions pipeline. It requires manual execution to generate the Vault TLS material, publish it to Key Vault and Kubernetes, deploy Vault, then load the certificate bundle. Organisations may still deploy the chart with `dpn-vault-https-cd.yml` (or `helm upgrade --install`) so that **auto-unseal remains in effect** — only the TLS-material generation and bundle load are done manually.

**Prerequisite Note**

- The organisation is required to set up a machine that can reach the private AKS environment (the shared self-hosted runner already has these tools if you prefer to run these steps as an ad-hoc job on it instead).
- That machine requires `openssl`, `keytool`, `az`, and `kubectl` installed (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md)).

### Step1: Generate the Vault TLS material

**Step 1a — Create the working directories:**

```bash
mkdir -p vault/ca vault/certs
cd vault
```

**Step 1b — Generate the Root CA key and certificate:**

```bash
openssl genrsa -out ca/rootCA.key 4096
openssl req -x509 -new -nodes -key ca/rootCA.key \
  -sha256 -days 3650 \
  -out ca/rootCA.crt \
  -subj "/C=<Your Country>/O=<Your Org>/CN=dpn-vault-root"
```

**Step 1c — Generate the Vault server key:**

```bash
openssl genrsa -out certs/vault.key 4096
```

**Step 1d — Create `certs/vault-openssl.cnf`.** The SANs must include the internal Kubernetes DNS name used to reach Vault:

```text
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
C  = <Your Country>
O  = <Your Org>
CN = vault

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = vault-https.<namespace>.svc.cluster.local
DNS.2 = <vault.your-org.com>
```

**Step 1e — Create the CSR and sign it with the Root CA:**

```bash
openssl req -new -key certs/vault.key -out certs/vault.csr -config certs/vault-openssl.cnf

openssl x509 -req \
  -in certs/vault.csr \
  -CA ca/rootCA.crt -CAkey ca/rootCA.key -CAcreateserial \
  -out certs/vault.crt \
  -days 825 -sha256 \
  -extensions req_ext -extfile certs/vault-openssl.cnf
```

**Step 1f — Build the PKCS12 truststore from the Root CA:**

```bash
keytool -import -trustcacerts -noprompt -alias ca \
  -file ca/rootCA.crt \
  -keystore truststore.jks -storetype PKCS12 -storepass <truststore-password>
```

### Step2: Publish the TLS material

**Step 2a — Publish the Vault certificate, key, and truststore password to Key Vault:**

```bash
az keyvault secret set --vault-name <KEY_VAULT_NAME> --name VAULT-TLS-CERT --file certs/vault.crt
az keyvault secret set --vault-name <KEY_VAULT_NAME> --name VAULT-TLS-KEY  --file certs/vault.key
az keyvault secret set --vault-name <KEY_VAULT_NAME> --name VAULT-TRUSTSTORE-PASSWORD --value <truststore-password>
```

**Step 2b — Publish the truststore to the Kubernetes secret consumed by the Certificate Manager:**

```bash
kubectl create secret generic cert-manager-truststore \
  --namespace <namespace> \
  --from-file=truststore.jks=truststore.jks \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step3: Deploy Vault and enable KV v2

**Step 3a — Deploy the chart** (auto-unseal applies; Vault mounts the TLS material from Key Vault via CSI):

```bash
helm upgrade --install vault-https charts/vault-https \
  --namespace <namespace> \
  -f charts/vault-https/values-<env>.yaml \
  --set image.tag=1.16 --wait --timeout 5m
```

**Step 3b — Initialise Vault and enable the KV v2 engine.** With auto-unseal, `init` returns **recovery keys** and Vault unseals itself — there is **no `vault operator unseal` step**:

```bash
VPOD=$(kubectl get pod -n <namespace> -l app=dpn-vault-https -o jsonpath='{.items[0].metadata.name}')

kubectl -n <namespace> exec $VPOD -- \
  sh -c 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault operator init'
# store the Root Token and Recovery Keys securely from the output

kubectl -n <namespace> exec $VPOD -- \
  sh -c 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN=<RootToken> \
         vault secrets enable -path=pki-client kv-v2'
```

Optionally store the root token in Key Vault so the Certificate Manager can read it:

```bash
az keyvault secret set --vault-name <KEY_VAULT_NAME> --name VAULT-TOKEN --value <RootToken>
```

### Step4: Load the certificate bundle

**Step 4a — Load the client key pair, CA chain, and certificate into Vault.** The bundle contains `<orgname>.key`, `ca-chain.pem`, and `certificate.pem`:

```bash
kubectl -n <namespace> exec $VPOD -- env VAULT_TOKEN=<RootToken> VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault kv put pki-client/node-net/client/keypair \
    privateKey="$(cat <orgname>.key)" \
    publicKey="$(openssl rsa -in <orgname>.key -pubout 2>/dev/null)"

kubectl -n <namespace> exec $VPOD -- env VAULT_TOKEN=<RootToken> VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault kv put pki-client/node-net/client/ca-chain chain="$(cat ca-chain.crt)"

kubectl -n <namespace> exec $VPOD -- env VAULT_TOKEN=<RootToken> VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  vault kv put pki-client/node-net/client/certificate certificate="$(cat certificate.crt)"
```

Verify that the client key pair, CA chain, and certificate paths are populated in Vault under `pki-client/node-net/client/`.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
