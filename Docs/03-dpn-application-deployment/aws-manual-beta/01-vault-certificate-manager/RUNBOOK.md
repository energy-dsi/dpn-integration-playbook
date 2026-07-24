# 01 — Vault + Certificate Manager

Deploys HashiCorp Vault (manual-unseal, file storage backend) and the
certificate-manager service that uses it to issue and rotate the mTLS
certificates the federator gateway components use to talk to each other and
to your DSM (Device/Secrets Management) system.

Apply `00-shared-prerequisites` before this component.

### Files in this folder

| File | Contents |
|---|---|
| `manifests/01-vault-https.yaml` | Vault PVC, ConfigMap, Deployment, Service |
| `manifests/02-certificate-manager.yaml` | Cert-manager PVC, ConfigMap, Deployment |
| `scripts/cm-policy.hcl` | Vault ACL policy scoping certificate-manager's token |
| `scripts/create-vault-tls-bootstrap.sh` | Generates Vault's server TLS cert + truststore |
| `scripts/generate-bootstrap-cert.sh` | Generates a non-production client identity bundle (use only if you don't yet have a real DSM-issued bundle) |

---

## 1. Prerequisites

- `00-shared-prerequisites` applied (namespaces, `efs-sc` StorageClass, `federator-server` ServiceAccount, `ghcr-pull-secret`).
- Local tools: `kubectl`, `openssl`, `keytool` (any JDK), `jq`.
- If your cluster runs an OTEL/CloudWatch auto-instrumentation mutating
  webhook, leave the `cloudwatch.aws.amazon.com/...` / `instrumentation.opentelemetry.io/...`
  annotations in `manifests/01-vault-https.yaml` set to `"false"` — otherwise
  it may inject agents into the Vault pod. Harmless no-op if you don't run
  such a webhook.

## 2. Configuration

Edit `manifests/02-certificate-manager.yaml` and fill in these placeholders
before applying:

| Placeholder | What it is |
|---|---|
| `<DSM_OAUTH2_TOKEN_URI>` | Your DSM's OAuth2 token endpoint |
| `<DSM_OAUTH2_CLIENT_ID>` | OAuth2 client ID registered with your DSM |
| `<DSM_MANAGEMENT_NODE_BASE_URL>` | Your DSM's management-node base URL |
| `<CERT_SUBJECT_COUNTRY>` | 2-letter country code for the cert subject, e.g. `GB` |
| `<CERT_SUBJECT_ORG>` | Organization name for the cert subject |
| `<CERT_SUBJECT_CN>` | Common Name identifying this node, e.g. `dpn-client-01` |
| `<CERT_SUBJECT_ALT_NAMES>` | Comma-separated SANs for producer/consumer endpoints |
| `<TRUSTSTORE_PASSWORD>` | Password you'll use for the Java truststore — pick your own; must match `TRUSTSTORE_PASS` in the TLS bootstrap script below |

You do not need to hand-author any Secret YAML — they're all created
imperatively in the Installation section below, from values you choose at
that point (keystore/truststore passwords, OAuth2 client secret).

## 3. Installation

### 3.1 Deploy Vault

Generate Vault's server TLS certificate and a matching truststore:

```bash
COUNTRY=GB ORG="<Your Org>" TRUSTSTORE_PASS=<same-as-CONFIGURATION-above> OUT_DIR=./vault-bundle \
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

### 3.2 Post-configuration — initialize Vault, enable the PKI engine, load certificates

> **Manual unseal.** No KMS auto-unseal is configured (Shamir, threshold 3 of
> 5). Every time this pod is recreated, Vault comes back **SEALED** and a
> human must unseal it again — see Troubleshooting below and the KMS
> auto-unseal outline at the end of this file.

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

### 3.3 Deploy certificate-manager

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

### 3.4 Healthcheck

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

### 3.5 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Crash loop, `keystore password was incorrect` | `envFrom` gives the Secret precedence over the ConfigMap on a key collision — `certificate-manager-secrets.SPRING_CLOUD_VAULT_SSL_TRUST_STORE_PASSWORD` overrides the ConfigMap value | `kubectl get secret certificate-manager-secrets -n ns-dpn-01 -o jsonpath='{.data.SPRING_CLOUD_VAULT_SSL_TRUST_STORE_PASSWORD}' \| base64 -d` and confirm it matches the password used to build `truststore.jks` |
| certificate-manager can't reach Vault | Vault pod is `Running` but still **sealed** | `kubectl exec -n ns-dpn-01 deploy/vault-https -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status` — if `Sealed true`, unseal again (see 3.2). Also check `VAULT_TOKEN` hasn't expired (`-period=768h`) |
| No `Certificate renewed successfully` in logs | Outbound network/DNS to your DSM endpoints is blocked | Confirm the pod can resolve and reach `<DSM_OAUTH2_TOKEN_URI>` / `<DSM_MANAGEMENT_NODE_BASE_URL>` — this is almost always a DNS-resolver-rule or egress-firewall/whitelisting issue outside these manifests, not a bug in the app |
| Pod stuck in `ContainerCreating` | EFS mount failing | Confirm EFS mount targets exist in the pod's AZ and the mount-target security group allows TCP 2049 from the node subnets; `kubectl describe pod -n ns-dpn-01 <pod>` |
| `kubectl apply` on `02-certificate-manager.yaml` succeeds but config change doesn't take effect | Config is consumed via `envFrom`, which does **not** trigger a pod restart | Always follow a ConfigMap/Secret change with `kubectl rollout restart deployment/dpn-certificate-manager -n ns-dpn-01` |
| After `kubectl delete deployment/vault-https` + re-apply, pod is `Running` but everything using Vault fails | Vault comes back **sealed** — `Running` is not a health signal for Vault | Re-run the unseal commands in 3.2, then `kubectl rollout restart deployment/dpn-certificate-manager -n ns-dpn-01` |
| `kubectl delete pvc/vault-https-data` was run | Destructive — wipes the Shamir file storage backend; Vault returns uninitialised, all KV data gone, existing tokens dead | Not recoverable — re-run all of 3.2 and 3.3 from scratch with a freshly initialized Vault |
| Deleting `dpn-certificate-manager` only | Safe and self-healing — re-applying `manifests/02-certificate-manager.yaml` recreates it from the existing PVC/Secrets with no further steps | — |

> **Do not delete `pvc/cert-manager-tls`.** It's a ReadWriteMany volume
> shared with the federator gateway server/client pods in
> `04-federator-gateway`. Deleting it either blocks on the PVC-protection
> finalizer while those pods hold it, or provisions a brand-new empty volume
> while the gateway pods still reference the old one.

---

## Appendix — AWS KMS auto-unseal (optional follow-up)

Not required to run the stack, but removes the manual-unseal step above and
the risk of Vault sitting sealed after an unplanned pod restart:

1. Create a symmetric KMS CMK, e.g. alias `alias/dpn-vault-unseal`.
2. Create an IAM role whose trust policy allows
   `sts:AssumeRoleWithWebIdentity` from your cluster's OIDC provider for
   `system:serviceaccount:ns-dpn-01:federator-server`, granting
   `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` on that CMK.
3. Annotate the `federator-server` ServiceAccount
   (`00-shared-prerequisites/manifests/02-serviceaccount-federator-server.yaml`)
   with that role's ARN.
4. Add a seal stanza to the `vault.hcl` ConfigMap data in
   `manifests/01-vault-https.yaml`:
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
