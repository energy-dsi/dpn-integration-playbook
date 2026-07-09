# DPN Vault Service Configuration

This document describes how to configure and deploy the **DPN HashiCorp Vault service** in a single target environment. HashiCorp Vault is the secret store used by the DPN Certificate Manager to hold the Intermediate CA, CA chain, key pair, certificate, and the keystore/truststore passwords used to build the P12 files for mutual TLS (mTLS) with the DSI DSM.

DSI provides an **automated method** (Azure DevOps pipelines) that generates the required CSR, certificate, and key material and configures Vault end to end. This is the recommended approach. A **manual fallback** is also provided for organisations that cannot run the automated pipelines.

> **Single environment:** These instructions target **one environment** (referred to throughout as `<env>`). Wherever you see `<env>`, substitute your own environment name (for example the value your organisation uses for the config file `config/<env>.json` and values file `values-<env>.yaml`). You do not need to create multiple environment files.

---

## Table of Contents

- [Overview](#overview)
- [Automated Vault Configuration](#automated-vault-configuration)
  - [Step 1 — Prerequisites (before Vault can be deployed)](#step-1--prerequisites-before-vault-can-be-deployed)
  - [Step 2 — Reference Configuration Data (populate before deployment)](#step-2--reference-configuration-data-populate-before-deployment)
  - [Step 3 — Deployment](#step-3--deployment)
  - [Step 4 — Post-Deployment: Auto-Unseal and Automatic Publication](#step-4--post-deployment-auto-unseal-and-automatic-publication)
  - [Step 5 — Manual Verification (optional)](#step-5--manual-verification-optional)
- [Manual Vault Configuration (Fallback)](#manual-vault-configuration-fallback)
- [Review Notes](#review-notes)

---

## Overview

HashiCorp Vault stores the cryptographic material the Certificate Manager needs to establish mTLS with the DSI DSM and other DPNs. The Certificate Manager reads and writes the following KV v2 paths under the `pki-client` mount:

| Path (`pki-client/node-net/client/…`) | Content | Written by |
|---------------------------------------|---------|------------|
| `keypair` | Client RSA private + public key | Bundle load (Step 3C) |
| `certificate` | DSM-signed client certificate | Bundle load (Step 3C) |
| `ca-chain` | CA chain from DSM | Bundle load (Step 3C) |
| `intermediate-ca` | Intermediate CA certificate | Certificate Manager (renewal) |
| `keystore-password` | Password for the generated `keystore.p12` | Certificate Manager |
| `truststore-password` | Password for the generated `truststore.p12` | Certificate Manager |

Vault serves over **HTTPS (TLS 1.2+)** internally and uses **Azure Key Vault auto-unseal**, so it unseals itself on start-up. DSI provides the community edition of the Vault container; organisations may substitute an enterprise edition per their licensing strategy.

Two setup methods are available:

- **[Automated Vault Configuration](#automated-vault-configuration)** *(recommended)* — three ADO pipelines generate the TLS material, deploy and initialise Vault, and load the certificate bundle.
- **[Manual Vault Configuration (Fallback)](#manual-vault-configuration-fallback)** — the equivalent steps performed by hand with OpenSSL / `keytool` / `kubectl`.

---

## Automated Vault Configuration

The automated flow uses three pipelines from the `dpn-federator-certificate-manager` repository, run in order:

| Order | Pipeline | Purpose |
|-------|----------|---------|
| 1 | `vault-tls-bootstrap-cd.yaml` | Generate the Vault server TLS certificate/key + Certificate Manager truststore, and publish them to Key Vault and Kubernetes |
| 2 | `vault-https-cd.yaml` | Deploy Vault via Helm, then initialise it and enable the KV v2 engine |
| 3 | `vault-load-bundle-cd.yaml` | Load the DSM-signed client certificate bundle into Vault |

All three are located under:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            ├── vault-tls-bootstrap-cd.yaml
            ├── vault-https-cd.yaml
            └── vault-load-bundle-cd.yaml
```

---

### Step 1 — Prerequisites (before Vault can be deployed)

Ensure the following are in place **before** running any pipeline:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **AKS cluster** provisioned and reachable | Target cluster for the deployment |
| 2 | **Azure Key Vault** provisioned | Stores the Vault TLS material, the auto-unseal key, and the Vault root token |
| 3 | **Auto-unseal key** `vault-unseal-key` created in the Key Vault | An RSA key (not a secret) used by Vault's Azure Key Vault seal to auto-unseal |
| 4 | **User-assigned managed identity** with access to the Key Vault | Needs *get* on secrets and *wrap/unwrap* on the unseal key. Its client ID is used for both auto-unseal and the CSI driver |
| 5 | **Secrets Store CSI driver** (Azure provider) enabled on AKS | Vault mounts its TLS cert/key from Key Vault via CSI |
| 6 | **ADO service connection** to the subscription, and a **self-hosted agent** with `openssl`, `keytool`, `az`, `kubectl`, `kubelogin`, and `helm` | See [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md) |
| 7 | **Environment config and values files populated** | See [Step 2](#step-2--reference-configuration-data-populate-before-deployment) |
| 8 | **DSM-signed client bundle available** | The client private key, DSM-signed certificate, and CA chain — loaded in [Step 3C](#step-3--deployment) |

---

### Step 2 — Reference Configuration Data (populate before deployment)

Two files must be populated for your environment. **Use your own values — the examples below are placeholders only.**

#### 2a. Environment config JSON — `config/<env>.json`

The pipelines resolve environment settings from this file (see [Azure Environment Configuration](00-common-dpn-configuration.md#azure-environment-configuration)). Vault uses the following keys:

| Key | Description | Example (placeholder) |
|-----|-------------|-----------------------|
| `AZURE_SUBSCRIPTION_ID` | Subscription hosting the infrastructure | `<subscription-id>` |
| `RESOURCE_GROUP` | Resource group containing the AKS cluster | `rg-<env>-uks-dpn-01` |
| `AKS_CLUSTER` | AKS cluster name | `aks-<env>-uks-dpn-01` |
| `NAMESPACE` | Kubernetes namespace | `ns-dpn-01` |
| `KEY_VAULT_NAME` | Azure Key Vault for secrets and certificates | `kv-dpn-<env>-<region>-<seq>` |

#### 2b. Vault Helm values — `charts/vault-https/values-<env>.yaml`

Copy `values.yaml` (reference — do not edit directly) to `values-<env>.yaml` and set the values below. DSI proposes only these selective changes; other parameters may be customised if required.

```text
Root-Repository
  └── charts
        └── vault-https
              ├── values.yaml        <- Reference file; do not edit directly
              └── values-<env>.yaml  <- Your environment overrides
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

> **Note:** Keep `replicaCount: 1` — Vault uses a `ReadWriteOnce` persistent volume. The Vault TLS certificate and key are **not** set here; they are generated and published to Key Vault in [Step 3A](#step-3--deployment) and mounted into the pod via the CSI driver.

---

### Step 3 — Deployment

Run the three pipelines in order. Each takes your environment as a runtime parameter and resolves `config/<env>.json` and `values-<env>.yaml` automatically.

#### Step 3A — Bootstrap Vault TLS (`vault-tls-bootstrap-cd`)

Generates a Root CA, the Vault server certificate/key, and the Certificate Manager truststore in a single run, then publishes them to Key Vault and Kubernetes.

Runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `serviceConnection` | Azure service connection for your environment |
| `environment` | Your target environment (selects `config/<env>.json`) |
| `country` | CSR subject Country (C) — default `GB` |
| `org` | CSR subject Organisation (O) — default `DSI` |
| `sans` | Comma-separated DNS SANs for the Vault URL. **Must include the internal Kubernetes DNS name**, e.g. `vault-https.<namespace>.svc.cluster.local` |
| `truststorePassword` | Password published to Key Vault as `VAULT-TRUSTSTORE-PASSWORD` — default `changeit` |

On completion it publishes (see [Step 4](#step-4--post-deployment-auto-unseal-and-automatic-publication)):
- `VAULT-TLS-CERT`, `VAULT-TLS-KEY`, `VAULT-TRUSTSTORE-PASSWORD` → Azure Key Vault
- `truststore.jks` → Kubernetes secret `cert-manager-truststore`

#### Step 3B — Deploy and Initialise Vault (`vault-https-cd`)

Deploys the `vault-https` Helm chart and runs four stages: **Validate** (`helm lint` + dry-run) → **Deploy** (`helm upgrade --install`, approval-gated) → **Verify** (pod/service/seal status) → **VaultInit** (initialise Vault, enable the KV v2 engine at `pki-client`, enable audit logging).

Runtime parameters:

| Parameter | Description |
|-----------|-------------|
| `serviceConnection` | Azure service connection for your environment |
| `environment` | Your target environment |
| `vaultImageTag` | Vault image tag (default `1.16`) |
| `runVaultInit` | Run the init stage (default `true`; idempotent — safe to re-run) |
| `storeRootTokenInAkv` | Store the Vault root token in Key Vault as `VAULT-TOKEN`. **Set `true` on the first deploy** so the bundle-load pipeline and the Certificate Manager can read it |

> **Important:** The init stage publishes the full init output (**root token + recovery keys**) as the `vault-init-output` pipeline artifact. Download it, store the recovery keys securely per your secrets policy, then delete the artifact.

#### Step 3C — Load the Certificate Bundle (`vault-load-bundle-cd`)

Upload the DSM client bundle to Azure DevOps **Library → Secure Files** using these exact names, then run the pipeline:

| Secure File | Content |
|-------------|---------|
| `vault.key` | Your DPN client **private key** |
| `certificate.pem` | The **DSM-signed certificate** |
| `ca-chain.pem` | The **CA chain** from DSM |

The pipeline reads the Vault root token from Key Vault (`VAULT-TOKEN`), resolves the Vault pod, and writes `pki-client/node-net/client/{keypair,certificate,ca-chain}`.

Runtime parameters: `serviceConnection`, `environment`.

> **Prerequisites for this step:** Vault deployed and unsealed (3B), `VAULT-TOKEN` present in Key Vault (from 3B with `storeRootTokenInAkv: true`), KV v2 enabled at `pki-client`, and the three Secure Files uploaded.

---

### Step 4 — Post-Deployment: Auto-Unseal and Automatic Publication

No manual unseal is required. Vault uses **Azure Key Vault auto-unseal** (configured via the `seal "azurekeyvault"` stanza rendered into the Vault ConfigMap), so `vault operator init` produces **Recovery Keys, not Unseal Keys**, and Vault unseals itself on start-up.

By the end of Step 3, the pipelines have automatically published the following — no manual secret creation is needed:

| Artifact | Type | Location | Published by |
|----------|------|----------|--------------|
| `VAULT-TLS-CERT` | Secret | Azure Key Vault | `vault-tls-bootstrap-cd` |
| `VAULT-TLS-KEY` | Secret | Azure Key Vault | `vault-tls-bootstrap-cd` |
| `VAULT-TRUSTSTORE-PASSWORD` | Secret | Azure Key Vault | `vault-tls-bootstrap-cd` |
| `cert-manager-truststore` (`truststore.jks`) | Kubernetes secret | Target namespace | `vault-tls-bootstrap-cd` |
| `VAULT-TOKEN` | Secret | Azure Key Vault | `vault-https-cd` (init, when `storeRootTokenInAkv: true`) |
| KV v2 engine at `pki-client` + audit logging | Vault config | Vault | `vault-https-cd` (init) |
| `pki-client/node-net/client/{keypair,certificate,ca-chain}` | Vault secrets | Vault | `vault-load-bundle-cd` |

The Vault pod mounts `VAULT-TLS-CERT` / `VAULT-TLS-KEY` from Key Vault via the Secrets Store CSI driver at `/vault/tls`, so the TLS material is never handled manually on the cluster.

---

### Step 5 — Manual Verification (optional)

Run these checks to confirm the automated flow completed successfully. Replace `<namespace>` with your namespace and `<vault-pod>` with the Vault pod name (label `app=dpn-vault-https`).

**Pod and service are up:**

```bash
kubectl get pods -n <namespace> -l app=dpn-vault-https -o wide
kubectl get svc  -n <namespace> -l app=dpn-vault-https
```

**Vault is initialised and unsealed** (`Initialized true`, `Sealed false`):

```bash
kubectl -n <namespace> exec <vault-pod> -- \
  sh -c 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status'
```

**TLS material and root token exist in Key Vault:**

```bash
az keyvault secret show --vault-name <KEY_VAULT_NAME> --name VAULT-TLS-CERT --query id -o tsv
az keyvault secret show --vault-name <KEY_VAULT_NAME> --name VAULT-TRUSTSTORE-PASSWORD --query id -o tsv
az keyvault secret show --vault-name <KEY_VAULT_NAME> --name VAULT-TOKEN --query id -o tsv
```

**Truststore secret exists in the cluster:**

```bash
kubectl get secret cert-manager-truststore -n <namespace>
```

**Certificate bundle loaded into Vault** (uses the root token; `<RootToken>` from the init artifact):

```bash
kubectl -n <namespace> exec <vault-pod> -- sh -c '
  VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN=<RootToken> \
  vault kv get pki-client/node-net/client/certificate'
```

---

## Manual Vault Configuration (Fallback)

Use this method only if your organisation cannot run the automated pipelines. It performs the same actions by hand: generate the Vault TLS material, publish it to Key Vault and Kubernetes, deploy Vault, then load the certificate bundle. You still deploy the chart with `vault-https-cd` (or `helm upgrade --install`) so that **auto-unseal remains in effect** — only the TLS-material generation and bundle load are done manually.

You will need a machine that can reach the private AKS environment and has `openssl`, `keytool`, `az`, and `kubectl` installed (see [Prerequisites](../01-prerequisites/01-dpn-prerequisites.md)).

### 1. Generate the Vault TLS material

**Step 1 — Create the working directories:**

```bash
mkdir -p vault/ca vault/certs
cd vault
```

**Step 2 — Generate the Root CA key and certificate:**

```bash
openssl genrsa -out ca/rootCA.key 4096
openssl req -x509 -new -nodes -key ca/rootCA.key \
  -sha256 -days 3650 \
  -out ca/rootCA.crt \
  -subj "/C=<Your Country>/O=<Your Org>/CN=dpn-vault-root"
```

**Step 3 — Generate the Vault server key:**

```bash
openssl genrsa -out certs/vault.key 4096
```

**Step 4 — Create `certs/vault-openssl.cnf`.** The SANs must include the internal Kubernetes DNS name used to reach Vault:

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

**Step 5 — Create the CSR and sign it with the Root CA:**

```bash
openssl req -new -key certs/vault.key -out certs/vault.csr -config certs/vault-openssl.cnf

openssl x509 -req \
  -in certs/vault.csr \
  -CA ca/rootCA.crt -CAkey ca/rootCA.key -CAcreateserial \
  -out certs/vault.crt \
  -days 825 -sha256 \
  -extensions req_ext -extfile certs/vault-openssl.cnf
```

**Step 6 — Build the PKCS12 truststore from the Root CA:**

```bash
keytool -import -trustcacerts -noprompt -alias ca \
  -file ca/rootCA.crt \
  -keystore truststore.jks -storetype PKCS12 -storepass <truststore-password>
```

### 2. Publish the TLS material

**Step 7 — Publish the Vault certificate, key, and truststore password to Key Vault:**

```bash
az keyvault secret set --vault-name <KEY_VAULT_NAME> --name VAULT-TLS-CERT --file certs/vault.crt
az keyvault secret set --vault-name <KEY_VAULT_NAME> --name VAULT-TLS-KEY  --file certs/vault.key
az keyvault secret set --vault-name <KEY_VAULT_NAME> --name VAULT-TRUSTSTORE-PASSWORD --value <truststore-password>
```

**Step 8 — Publish the truststore to the Kubernetes secret consumed by the Certificate Manager:**

```bash
kubectl create secret generic cert-manager-truststore \
  --namespace <namespace> \
  --from-file=truststore.jks=truststore.jks \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3. Deploy Vault and enable KV v2

**Step 9 — Deploy the chart** (auto-unseal applies; Vault mounts the TLS material from Key Vault via CSI):

```bash
helm upgrade --install vault-https charts/vault-https \
  --namespace <namespace> \
  -f charts/vault-https/values-<env>.yaml \
  --set image.tag=1.16 --wait --timeout 5m
```

**Step 10 — Initialise Vault and enable the KV v2 engine.** With auto-unseal, `init` returns **recovery keys** and Vault unseals itself — there is **no `vault operator unseal` step**:

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

### 4. Load the certificate bundle

**Step 11 — Load the client key pair, CA chain, and certificate into Vault.** The bundle contains `<orgname>.key`, `ca-chain.crt`, and `certificate.crt`:

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

Verify using the checks in [Step 5 — Manual Verification](#step-5--manual-verification-optional).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
