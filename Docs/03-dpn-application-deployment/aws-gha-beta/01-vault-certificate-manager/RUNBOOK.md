# 01 — Vault + Certificate Manager

Deploys HashiCorp Vault (manual-unseal, file storage backend) and the
certificate-manager service that uses it to issue and rotate the mTLS
certificates the federator gateway components use to talk to each other and
to your DSM (Device/Secrets Management) system.

Apply `00-shared-prerequisites` before this component (including its
one-time AWS OIDC role setup).

**Primary path: the `dpn-containerised-deployment-service` GitHub Actions
pipeline** — the same workflows documented for Azure, run with `cloud: aws`.
The manifests/scripts in this folder are kept as a **manual fallback**
(Appendix, below) for if the pipeline is unavailable, not the normal way to
deploy this component anymore.

### Files in this folder (manual fallback reference)

| File | Contents |
|---|---|
| `manifests/01-vault-https.yaml` | Vault PVC, ConfigMap, Deployment, Service |
| `manifests/02-certificate-manager.yaml` | Cert-manager PVC, ConfigMap, Deployment |
| `scripts/cm-policy.hcl` | Vault ACL policy scoping certificate-manager's token |
| `scripts/create-vault-tls-bootstrap.sh` | Generates Vault's server TLS cert + truststore |
| `scripts/generate-bootstrap-cert.sh` | Generates a non-production client identity bundle (use only if you don't yet have a real DSM-issued bundle) |

---

## 1. Prerequisites

- `00-shared-prerequisites` applied (namespaces, `efs-sc` StorageClass, `federator-server` ServiceAccount, `ghcr-pull-secret`, AWS OIDC role for the pipeline).
- `values/aws/<environment>-<cluster>.yaml` populated for both the `vault-https` and `certificate-manager` charts (see [Populate the AWS Helm values](../00-shared-prerequisites/RUNBOOK.md#0-one-time-github-actions-aws-access) in the shared prerequisites) — adapt from the `values/azure/` equivalents, translating Azure-specific fields (Key Vault CSI, Azure DNS) to their AWS equivalents.
- **Key Vault stays in the picture even for AWS.** The pipeline stores the Vault root token and the TLS truststore password in an **Azure Key Vault** regardless of which cloud the cluster is in — `dpn-vault-https-cd.yml`'s `storeRootTokenInAkv` input and `dpn-vault-tls-bootstrap-cd.yml` both always write there, because the org's central secrets store is Azure Key Vault, not an AWS-native one. Confirm `KEY_VAULT_NAME` is present in `.github/config/aws/<environment>-<cluster>.json` — it isn't in the sample config we've seen, so you likely need to add it.
- (Manual fallback only) Local tools: `kubectl`, `openssl`, `keytool` (any JDK), `jq`.
- If your cluster runs an OTEL/CloudWatch auto-instrumentation mutating
  webhook, leave the `cloudwatch.aws.amazon.com/...` / `instrumentation.opentelemetry.io/...`
  annotations in `manifests/01-vault-https.yaml` (or the chart's AWS values,
  for the pipeline path) set to `"false"` — otherwise it may inject agents
  into the Vault pod. Harmless no-op if you don't run such a webhook.

### Certificate Lifecycle and Management

DPN-to-DPN and DPN-to-DSM communications are secured using mutual TLS (mTLS), meaning both parties in every connection must present a valid certificate to authenticate themselves. Each DPN therefore requires a DSI-issued certificate to participate in the network — without one, it cannot establish any connection with another DPN or with the DSM.

During initial DPN setup, a participant uploads a Certificate Signing Request (CSR) through the DSM user interface. The DSM signs the CSR and returns a bootstrap certificate bundle for download. The participant installs this bundle into their DPN's Vault (see `scripts/generate-bootstrap-cert.sh` if you don't yet have a real DSM-issued bundle), after which certificate renewal is handled automatically — the DPN manages its own certificate lifecycle without further manual intervention under normal operating conditions.

If a certificate expires before automatic renewal has taken place — for example due to the DPN being offline during the renewal window — the participant will need to return to the DSM user interface, upload a new CSR, and download a fresh bootstrap certificate to restore connectivity. As with the initial setup, the downloaded certificate bundle should be saved at the point of download since it cannot be retrieved from the platform again once the session ends.

Organisations should factor this recovery process into their operational runbooks so that certificate expiry does not result in extended loss of connectivity to the DSI network.

While the DSM is capable of issuing short-lived certificates and the DPN includes built-in capability to renew them automatically before expiry, the current certificate validity period is set to 60 days. This decision is driven by a known constraint affecting organisations that deploy their DPN behind Cloudflare or an equivalent reverse proxy or edge security layer. In such deployments, enterprise security policies may be configured to terminate mTLS at the Cloudflare boundary rather than passing it through end-to-end. Where mTLS is terminated at Cloudflare, the certificate installed at that layer is outside the DPN's automated renewal process — meaning that when a certificate is renewed by the DPN, the updated certificate must also be manually installed at the Cloudflare boundary. A shorter certificate lifetime would increase the frequency of this manual intervention. Setting the validity period to 60 days balances the security benefit of certificate rotation against the operational burden of manual installation at the proxy layer.

This constraint is under active review. Solutions have been identified that are expected to address 24 hrs certificate TTL back from 60 days while issuing a different certificate for proxy-terminated mTLS deployments. The additional long term TTL certificate to be provided from a different endpoint and serves only the purpose of client authentication at edge proxies for DPN. This longer TTL certificate can not be used for DSM authentication or any client certificate. This change is targeted for delivery in PI4. 

_**Note:** Organisations operating DPNs behind Cloudflare or equivalent infrastructure should factor the current manual renewal process into their operational runbooks until this capability is available and also actively monitor the expiry of the certificate installed outside the DPN certificate manager component since DSI does not generate any alert on certificate expiry at this moment._

## 2. Configuration

Set the parameters below in the environment/cluster values files for both
charts (`dpn-federator-cert-manager/charts/vault-https/values/aws/<environment>-<cluster>.yaml`
and `.../charts/certificate-manager/values/aws/<environment>-<cluster>.yaml`),
adapting from `manifests/02-certificate-manager.yaml`'s placeholders as a
reference for what values the chart needs:

| Value | What it is |
|---|---|
| `managementNode.baseUrl` | Your DSM's management-node base URL |
| `oauth2.clientId` / `oauth2.tokenUri` | OAuth2 client ID and token endpoint registered with your DSM |
| `cert.subject.country` / `.org` / `.cn` / `.altNames` | CSR subject fields — country, org, common name, and comma-separated SANs for producer/consumer endpoints |
| Truststore password | Pick your own; used consistently across the vault-tls-bootstrap and certificate-manager workflows below |

You do not need to hand-author any Secret YAML — the pipeline creates them for you from workflow inputs and Key Vault-sourced secrets.

## 3. Deploy via Pipeline

Trigger these `dpn-containerised-deployment-service` GitHub Actions workflows in order, via **Actions → Run workflow**, each with `cloud: aws`:

### 3A. Configure Bootstrap Vault TLS (`dpn-vault-tls-bootstrap-cd.yml`)

Generates a Root CA, the Vault server certificate/key, and the Certificate Manager truststore, then publishes them to Azure Key Vault and to a Kubernetes secret in the EKS cluster.

| Input | Value |
|---|---|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `country` / `org` | CSR subject fields — default `GB` / `DSI` |
| `sans` | Comma-separated DNS SANs, must include `vault-https.<namespace>.svc.cluster.local` |
| `truststorePassword` | Published to Key Vault as `VAULT-TRUSTSTORE-PASSWORD` — default `changeit` |

### 3B. Deploy and Initialise Vault (`dpn-vault-https-cd.yml`)

Deploys the `vault-https` Helm chart, then runs the Vault Init step (enables KV v2 at `pki-client` + audit logging).

| Input | Value |
|---|---|
| `environment` / `cluster` / `cloud` | as above (`cloud: aws`) |
| `vaultImageTag` | Vault image tag — default `1.16` |
| `runVaultInit` | Default `true`; idempotent |
| `storeRootTokenInAkv` | **Set `true` on the first deploy** — the bundle-load workflow (3C) needs `VAULT-TOKEN` from Key Vault regardless of target cloud |

> **Auto-unseal is what makes this workflow viable — set it up before this step, not after.** Unlike the manual fallback (which uses Shamir shares and needs a human to unseal Vault by hand after every pod restart), the pipeline has no interactive unseal step — if Vault comes back sealed, the Vault Init step in this workflow will simply fail. Configure **AWS KMS auto-unseal** in the chart's AWS values (`seal.awskms.*`) before running this workflow — see [Appendix B](#appendix-b--aws-kms-auto-unseal-configuration) for the exact KMS key/IAM role/Helm values needed. This is the same role auto-unseal plays on the Azure side via `seal.azureKeyVault.*`.

### 3C. Configure Certificate Bundle (`dpn-vault-load-bundle-cd.yml`)

Set these as **GitHub Actions secrets** (repository or environment level) before running: `VAULT_KEY` (client private key), `CERTIFICATE_PEM` (DSM-signed certificate), `CA_CHAIN_PEM` (CA chain) — from your DSM, or generated non-production via `scripts/generate-bootstrap-cert.sh` (Appendix A).

| Input | Value |
|---|---|
| `environment` / `cluster` / `cloud` | as above (`cloud: aws`) |

The workflow reads `VAULT-TOKEN` from Key Vault, resolves the Vault pod, and writes `pki-client/node-net/client/{keypair,certificate,ca-chain}`.

### 3D. Deploy Certificate Manager (`dpn-certificate-manager-cd.yml`)

| Input | Value |
|---|---|
| `environment` / `cluster` / `cloud` | as above (`cloud: aws`) |
| `imageTag` | Certificate Manager image tag |

### Healthcheck

```bash
kubectl get pods -n ns-dpn-01 -l app=vault-https
kubectl get pods -n ns-dpn-01 -l app=dpn-certificate-manager

kubectl get cm dpn-certificate-manager-config -n ns-dpn-01 -o json | jq '.data | length'
kubectl get cm dpn-certificate-manager-config -n ns-dpn-01 -o jsonpath='{.data.CERT_SUBJECT_ALT_NAMES}'; echo

CM_POD=$(kubectl get pod -n ns-dpn-01 -l app=dpn-certificate-manager -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ns-dpn-01 "$CM_POD" -- ls -la /tls/

kubectl logs -n ns-dpn-01 -l app=dpn-certificate-manager --tail=100
```

**Healthy:** both pods `Running 1/1`; `/tls/` contains `keystore.p12` and
`truststore.p12`; logs show `Synchronizing keystores to filesystem...` /
`Keystore synchronized to /tls/keystore.p12`; no `CrashLoopBackOff`.

`Certificate renewed successfully` in the logs additionally requires the
outbound call to your DSM to succeed — if you see keystore sync but no
renewal line, check DNS/egress to your DSM endpoints (Troubleshooting below).

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Crash loop, `keystore password was incorrect` | `envFrom` gives the Secret precedence over the ConfigMap on a key collision — `certificate-manager-secrets.SPRING_CLOUD_VAULT_SSL_TRUST_STORE_PASSWORD` overrides the ConfigMap value | `kubectl get secret certificate-manager-secrets -n ns-dpn-01 -o jsonpath='{.data.SPRING_CLOUD_VAULT_SSL_TRUST_STORE_PASSWORD}' \| base64 -d` and confirm it matches the password used to build `truststore.jks` |
| certificate-manager can't reach Vault | Vault pod is `Running` but still **sealed** | `kubectl exec -n ns-dpn-01 deploy/vault-https -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status` — if `Sealed true`, unseal again (see 3.2). Also check `VAULT_TOKEN` hasn't expired (`-period=768h`) |
| No `Certificate renewed successfully` in logs | Outbound network/DNS to your DSM endpoints is blocked | Confirm the pod can resolve and reach `<DSM_OAUTH2_TOKEN_URI>` / `<DSM_MANAGEMENT_NODE_BASE_URL>` — this is almost always a DNS-resolver-rule or egress-firewall/whitelisting issue outside these manifests, not a bug in the app |
| Pod stuck in `ContainerCreating` | EFS mount failing | Confirm EFS mount targets exist in the pod's AZ and the mount-target security group allows TCP 2049 from the node subnets; `kubectl describe pod -n ns-dpn-01 <pod>` |
| `kubectl apply` on `02-certificate-manager.yaml` succeeds but config change doesn't take effect | Config is consumed via `envFrom`, which does **not** trigger a pod restart | Always follow a ConfigMap/Secret change with `kubectl rollout restart deployment/dpn-certificate-manager -n ns-dpn-01` |
| After `kubectl delete deployment/vault-https` + re-apply, pod is `Running` but everything using Vault fails | Vault comes back **sealed** — `Running` is not a health signal for Vault. On the pipeline path with AWS KMS auto-unseal configured this shouldn't happen; on the manual fallback it will, every time | Re-run the unseal commands in [Appendix A, A.2](#a2-post-configuration--initialize-vault-enable-the-pki-engine-load-certificates), then `kubectl rollout restart deployment/dpn-certificate-manager -n ns-dpn-01` |
| `kubectl delete pvc/vault-https-data` was run | Destructive — wipes the Vault storage backend; Vault returns uninitialised, all KV data gone, existing tokens dead | Not recoverable — re-run [3B/3C](#3-deploy-via-pipeline) (or [Appendix A, A.2/A.3](#appendix-a--manual-fallback-deployment) for the manual path) from scratch with a freshly initialized Vault |
| Deleting `dpn-certificate-manager` only | Safe and self-healing — re-applying `manifests/02-certificate-manager.yaml` recreates it from the existing PVC/Secrets with no further steps | — |

> **Do not delete `pvc/cert-manager-tls`.** It's a ReadWriteMany volume
> shared with the federator gateway server/client pods in
> `04-federator-gateway`. Deleting it either blocks on the PVC-protection
> finalizer while those pods hold it, or provisions a brand-new empty volume
> while the gateway pods still reference the old one.

---

## Appendix A — Manual Fallback Deployment

Use this only if the pipeline (Section 3) is unavailable. It requires manual execution to generate the Vault TLS material, deploy Vault, initialise it, and deploy certificate-manager — the same end state Section 3 reaches via the four workflows.

### A.1 Deploy Vault

Generate Vault's server TLS certificate and a matching truststore:

```bash
COUNTRY=GB ORG="<Your Org>" TRUSTSTORE_PASS=<your-chosen-password> OUT_DIR=./vault-bundle \
  sh scripts/create-vault-tls-bootstrap.sh

kubectl create secret generic vault-tls \
  --from-file=vault.crt=./vault-bundle/certs/vault.crt \
  --from-file=vault.key=./vault-bundle/certs/vault.key \
  -n ns-dpn-01
```

Deploy Vault:

```bash
kubectl apply -f manifests/01-vault-https.yaml
kubectl rollout status deployment/vault-https -n ns-dpn-01
```

### A.2 Post-configuration — initialize Vault, enable the PKI engine, load certificates

> **Manual unseal.** No KMS auto-unseal is configured here (Shamir, threshold 3 of
> 5). Every time this pod is recreated, Vault comes back **SEALED** and a
> human must unseal it again — see Troubleshooting above, or configure
> [Appendix B — AWS KMS auto-unseal](#appendix-b--aws-kms-auto-unseal-configuration)
> to remove this step (recommended if you plan to use the pipeline going forward).

Initialize and unseal:

```bash
VAULT_POD=$(kubectl get pod -n ns-dpn-01 -l app=vault-https -o jsonpath='{.items[0].metadata.name}')
VE="env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true"

kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE vault operator init > vault-init-output.txt
# SAVE THIS FILE SECURELY (5 unseal keys + initial root token), then delete the local copy.

kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE vault operator unseal <key-1>
kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE vault operator unseal <key-2>
kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE vault operator unseal <key-3>

kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE vault status   # expect: Sealed false
```

Enable the KV v2 (PKI client) engine:

```bash
ROOT_TOKEN=<initial-root-token-from-vault-init-output.txt>
kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE VAULT_TOKEN=$ROOT_TOKEN \
  vault secrets enable -path=pki-client kv-v2
```

Write the ACL policy and create a scoped token for certificate-manager:

```bash
kubectl cp scripts/cm-policy.hcl ns-dpn-01/"$VAULT_POD":/tmp/cm-policy.hcl

kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE VAULT_TOKEN=$ROOT_TOKEN \
  vault policy write certificate-manager /tmp/cm-policy.hcl
kubectl exec -n ns-dpn-01 "$VAULT_POD" -- rm -f /tmp/cm-policy.hcl

CM_TOKEN=$(kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE VAULT_TOKEN=$ROOT_TOKEN \
  vault token create -policy=certificate-manager -period=768h -field=token)
```

Load the bootstrap identity bundle (`vault.key`, `certificate.pem`,
`ca-chain.pem` — from your DSM, or use `scripts/generate-bootstrap-cert.sh`
for a non-production bundle):

```bash
kubectl cp vault.key       ns-dpn-01/"$VAULT_POD":/tmp/vault.key
kubectl cp certificate.pem ns-dpn-01/"$VAULT_POD":/tmp/certificate.pem
kubectl cp ca-chain.pem    ns-dpn-01/"$VAULT_POD":/tmp/ca-chain.pem

kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE VAULT_TOKEN=$CM_TOKEN \
  sh -c 'vault kv put pki-client/node-net/client/keypair privateKey=@/tmp/vault.key publicKey="$(openssl rsa -in /tmp/vault.key -pubout 2>/dev/null)"'
kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE VAULT_TOKEN=$CM_TOKEN \
  vault kv put pki-client/node-net/client/certificate certificate=@/tmp/certificate.pem
kubectl exec -n ns-dpn-01 "$VAULT_POD" -- $VE VAULT_TOKEN=$CM_TOKEN \
  vault kv put pki-client/node-net/client/ca-chain chain=@/tmp/ca-chain.pem

kubectl exec -n ns-dpn-01 "$VAULT_POD" -- rm -f /tmp/vault.key /tmp/certificate.pem /tmp/ca-chain.pem
```

### A.3 Deploy certificate-manager

```bash
kubectl create secret generic cert-manager-truststore \
  --from-file=truststore.jks=./vault-bundle/truststore.jks \
  -n ns-dpn-01

kubectl create secret generic certificate-manager-secrets -n ns-dpn-01 \
  --from-literal=VAULT_TOKEN="$CM_TOKEN" \
  --from-literal=SPRING_CLOUD_VAULT_SSL_TRUST_STORE_PASSWORD=<same-TRUSTSTORE_PASSWORD-as-above> \
  --from-literal=MTLS_KEYSTORE_PASSWORD='<choose-a-password>' \
  --from-literal=MTLS_TRUSTSTORE_PASSWORD='<choose-a-password>' \
  --from-literal=OAUTH2_CLIENT_SECRET='<your-dsm-oauth2-client-secret>'

kubectl apply -f manifests/02-certificate-manager.yaml
kubectl rollout status deployment/dpn-certificate-manager -n ns-dpn-01
```

---

## Appendix B — AWS KMS auto-unseal configuration

Not required to run the manual fallback, but removes its manual-unseal step and
the risk of Vault sitting sealed after an unplanned pod restart — and, per
[3B](#3b-deploy-and-initialise-vault-dpn-vault-https-cd-yml) above, is what
makes the **pipeline** path viable at all for this component:

1. Create a symmetric KMS CMK, e.g. alias `alias/dpn-vault-unseal`.
2. Create an IAM role whose trust policy allows
   `sts:AssumeRoleWithWebIdentity` from your cluster's OIDC provider for
   `system:serviceaccount:ns-dpn-01:federator-server`, granting
   `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` on that CMK.
3. Annotate the `federator-server` ServiceAccount
   (`00-shared-prerequisites/manifests/02-serviceaccount-federator-server.yaml`)
   with that role's ARN.
4. Add a seal stanza to the `vault.hcl` ConfigMap data — in
   `manifests/01-vault-https.yaml` for the manual fallback, or in the
   chart's `values/aws/<environment>-<cluster>.yaml` (`seal.awskms.*`,
   mirroring `seal.azureKeyVault.*` on the Azure side) for the pipeline path:
   ```hcl
   seal "awskms" {
     region     = "<AWS_REGION>"
     kms_key_id = "alias/dpn-vault-unseal"
   }
   ```
5. Run a one-time seal migration on the existing Vault (not automatic):
   ```bash
   vault operator unseal -migrate <key-1>
   vault operator unseal -migrate <key-2>
   vault operator unseal -migrate <key-3>
   ```
   Keep the original 5 Shamir keys afterward — they become the recovery keys.
