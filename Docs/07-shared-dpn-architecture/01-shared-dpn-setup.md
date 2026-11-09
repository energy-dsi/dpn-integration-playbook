# Set Up a Shared DPN

This guide covers the process of setting up Shared DPN.

---

## Table of Contents

- [Approach](#approach)
- [Prerequisites](#prerequisites)
- [Name Each Component for the New Instance](#name-each-component-for-the-new-instance)
- [Step 1: Gather the LOE Identity](#step-1-gather-the-loe-identity)
- [Step 2: Create the New Instance's Values File](#step-2-create-the-new-instances-values-file)
- [Step 3: Deploy](#step-3-deploy)
- [Step 4: Verify](#step-4-verify)
- [Shared Services](#shared-services)
- [Secrets Summary](#secrets-summary)
- [Rollback and Removal](#rollback-and-removal)
- [Review Notes](#review-notes)

---

## Approach

As per the Shared DPN architecture, the following components need additional insatnces based on per LOE :
- DPN Hashicorp Vault
- Certificate Manager
- gRPC federator (server and client)
- REST federator server
- REST federator demo runner client (reference only)

---

## Prerequisites

- At least one working **gRPC or REST Federator** on the Kubernetes cluster with these components (Kafka, Zookeeper, Redis, Keycloak and Otel Collector).
- Each new LOE **registered in the same DSM**, with its **client ID**.
- Spare **cluster capacity** for the extra pods and an extra Vault PVC per LOE.
- A free **internal IP** for each additional load balancer, or agreement to let the cloud assign one (the overlays leave `loadBalancerIP` empty).

---

## Name Each Component for the New Instance

These are the names chosen for each new instance's components. They are set in a new **values file** — a small file that sits next to the existing one and lists only what's different for this instance (see [Step 2](#step-2-create-the-new-instances-values-file) for exactly which files to create) — or in the names of uploaded files. The charts and pipelines then use these names, together with the instance number, to automatically create everything else: the Helm releases, the Kubernetes resources (Services, PVCs, ConfigMaps), and the Key Vault entries.

Names use the instance number `N` (`02`, `03`, … for Vault and Certificate Manager; `2`, `3`, … for federator and Redis). **Never reuse a primary name** — a repeated name makes one release overwrite the other's Deployment, ConfigMap or Secret.

| Component | Existing Name (Primary) | New Name for This Instance (example: `02`) | Helm Parameter (Chart) |
|-----------|--------------------------|---------------------------------------------|-------------------------|
| Vault | `dpn-vault-https` | `dpn-vault-https-02` | Vault `fullnameOverride` |
| Certificate Manager | `dpn-certificate-manager` | `dpn-certificate-manager-02` | Certificate Manager `fullnameOverride`, `otel.env.OTEL_SERVICE_NAME` |
| Certificate Manager Secret | `certificate-manager-secrets` | `certificate-manager-02-secrets` | Certificate Manager `existingSecret.name`; federator, REST federator and demo runner client `tokenSecretName` / `secretIdSecretName` |
| Key Vault secret names | `VAULT-TOKEN` / `VAULT-APPROLE-SECRET-ID` | `VAULT-TOKEN-02` / `VAULT-APPROLE-SECRET-ID-02` | Certificate Manager `keyvault.tokenSecretName` / `keyvault.approleSecretName` |
| Federator server / client | `dpn-federator-server-1` / `dpn-federator-client-1` | `dpn-federator-server-2` / `dpn-federator-client-2` | `federatorServer.name` / `federatorClient.name` |
| REST Federator server | `dpn-rest-federator-server-1` | `dpn-rest-federator-server-2` | `restFederatorServer.name` |
| REST Federator Redis | `dpn-rest-federator-redis-1` | `dpn-rest-federator-redis-2` | Redis `redisCache.name`; REST federator and demo runner client `redis.host` |
| REST Federator Redis key prefix | `federator-server-1` | `federator-server-2` | `restFederatorServer.redis.prefix` |
| REST Federator OTEL service name | `rest-federator-server` | `rest-federator-server-2` | `restFederatorServer.otel.serviceName` |
| Demo runner client (optional) | `dpn-demo-runner-client` | `dpn-demo-runner-client-2` | `job.name`, `job.env.senderFmarId` |
| Demo runner client ConfigMap | `dpn-rest-federator-client-properties` | `dpn-rest-federator-client-2-properties` | `job.clientProperties.configMapName` |
| Demo runner client Redis key prefix | `federator-client` | `federator-client-2` | `job.redis.prefix` |
| Demo runner client OTEL service name | `demo-runner-client` | `demo-runner-client-2` | `job.otel.serviceName` |
| Secure files (Vault bundle) | `bootstrap.key`, `certificate.pem`, `ca-chain.pem` | `bootstrap-02.key`, `certificate-02.pem`, `ca-chain-02.pem` | Azure DevOps Secure Files |

The Vault overlay also sets `service.aliasEnabled: false`, so the `vault-https` alias Service that belongs to the primary is not created a second time.

---

## Step 1: Gather the LOE Identity

| Item | Source | When it is known | Overlay keys |
|------|--------|------------------|--------------|
| **DSM client ID** | The LOE's client in the same DSM. Must be **unique per LOE** | Before setup begins | Certificate Manager `oauth2.clientId`; federator `federatorServer.idp.clientId` and `federatorClient.idp.clientId`; REST federator `restFederatorServer.idp.clientId`; demo runner client `job.idp.clientId` |
| **Certificate subject** | Decide the Common Name (CN) and Subject Alternative Names (SANs) for this LOE's certificate — they must be names unique to this LOE, following the same pattern as the organisation's other endpoints. Example: CN `producer02.dpn01.myorg.example.com`, SANs `producer02.dpn01.myorg.example.com,consumer02.dpn01.myorg.example.com` | Before setup begins | Certificate Manager `cert.subject.cn` and `cert.subject.altNames` (comma-separated) |
| **Vault bundle** | `dpn-tls-cd` creates the cluster-wide internal TLS secrets, so the CSR/key it produced for the primary can be reused to bootstrap a new LOE too — there's no need to run `dpn-tls-cd` again just for this. The participant uses that same CSR to bootstrap the new LOE at the DSM portal, which returns a signed certificate and CA chain for this LOE. (If `dpn-tls-cd` is re-run anyway, it recycles those shared secrets cluster-wide, so every existing pod must be restarted afterwards to pick up the new material.) | Before setup begins | None. Uploaded to Azure DevOps Secure Files as `bootstrap-0N.key` (the reused key), `certificate-0N.pem` and `ca-chain-0N.pem` (from this LOE's bootstrap), and loaded into `dpn-vault-https-0N` by `shared-vault-load-bundle-cd` |
| **AppRole `roleId`** | Run artifact `shared-dpn-approle-role-ids` of `shared-vault-approle-setup-cd` (Step 3, item 4) | After the AppRole run | Certificate Manager `vault.appRole.roleId`; federator `vaultConfig.appRole.roleId`; REST federator `restFederatorServer.vault.appRole.roleId`; demo runner client `job.vault.appRole.roleId` |

For each instance, use the **exact same** DSM client ID and `roleId` in all four overlay files — Certificate Manager, federator, REST federator, and demo runner client. Certificate Manager is deployed first, and the other three check their values against it:

- `shared-certificate-manager-cd` checks that its `roleId` matches the role ID reported by the running `dpn-vault-https-0N`.
- `shared-federator-cd`, `shared-rest-federator-cd` and `shared-demo-runner-client-cd` read the deployed ConfigMap `dpn-certificate-manager-0N-config` and fail if their client ID or role ID differs from it. The Certificate Manager must therefore be deployed before them.


---

## Step 2: Create the New Instance's Values File

Each shared instance is deployed from **two values files**: the primary's existing values file and a small `-0N` overlay next to it. The pipeline layers them in this order, so every key in the overlay replaces the primary's value and everything else is inherited:

```bash
helm upgrade --install <release>-0N <chart> \
  -f values-<env>-<cluster>.yaml \
  -f values-<env>-<cluster>-0N.yaml
```

To add an instance:

1. Leave the primary values file `values-<env>-<cluster>.yaml` unchanged.
2. Next to it, create `values-<env>-<cluster>-0N.yaml`, where `0N` is the instance number (`02`, `03`, …).
3. Put **only** the keys listed below in the overlay, using the names from the naming convention above and the identity from Step 1. Do not copy the whole primary file.
4. Commit the overlays to the repository the pipelines run from.

The repositories contain example overlays; use them as a reference for the format.

| Component | Repository | Primary values file | `0N` values file | Helm release |
|-----------|-----------|--------------------|---------------|--------------|
| Vault | `dpn-federator-certificate-manager` | `charts/vault-https/values-<env>-<cluster>.yaml` | `charts/vault-https/values-<env>-<cluster>-0N.yaml` | `vault-https-0N` |
| Certificate Manager | `dpn-federator-certificate-manager` | `charts/certificate-manager/values-<env>-<cluster>.yaml` | `charts/certificate-manager/values-<env>-<cluster>-0N.yaml` | `dpn-certificate-manager-0N` |
| Federator server and client | `dpn-federator-gateway` | `charts/dpn-platform/values-<env>-<cluster>.yaml` | `charts/dpn-platform/values-<env>-<cluster>-0N.yaml` | `dpn-platform-0N` |
| REST Federator server | `dpn-rest-federator-gateway` | `charts/dpn-rest-federator/values-<env>-<cluster>.yaml` | `charts/dpn-rest-federator/values-<env>-<cluster>-0N.yaml` | `dpn-rest-federator-0N` |
| REST Federator Redis | `dpn-rest-federator-gateway` | `charts/dpn-redis/values-<env>-<cluster>.yaml` | `charts/dpn-redis/values-<env>-<cluster>-0N.yaml` | `dpn-redis-0N` |
| Demo runner client (optional) | `dpn-rest-federator-gateway` | `charts/dpn-demo-runner-client/values-<env>-<cluster>.yaml` | `charts/dpn-demo-runner-client/values-<env>-<cluster>-0N.yaml` | `dpn-demo-runner-client-0N` |

Notes:

- The Vault overlay is minimal (`fullnameOverride` and `service.aliasEnabled: false`). Seal, Key Vault unseal key, managed identity, TLS certificate, image and resources are inherited.
- The gRPC federator `-0N` shares the primary's Kafka source and target, ZooKeeper, Kafka UI and Redis. Its release installs only the federator server and client Deployments, Services, load balancer Services and ConfigMaps.
- Each REST federator has **its own Redis**, referenced from `restFederatorServer.redis.host` and `prefix` in its overlay.
- The REST federator `-0N` chart copy contains only the server Deployment, Service, load balancer Service and ConfigMap. The HPA is not duplicated and keeps targeting the primary.
- Data pipelines are shared; the LOE only creates its own data products (Step 3, item 12).

### What Goes in the New Values File

Example values are for instance `02`. Replace `02` / `2` with the actual instance number. `<client-id>`, `<cn>`, `<sans>` and `<role-id>` come from Step 1.

**Vault** — `charts/vault-https/values-<env>-<cluster>-0N.yaml`

| Key | Value |
|-----|-------|
| `fullnameOverride` | `dpn-vault-https-02` |
| `service.aliasEnabled` | `false` |

**Certificate Manager** — `charts/certificate-manager/values-<env>-<cluster>-0N.yaml`

| Key | Value |
|-----|-------|
| `fullnameOverride` | `dpn-certificate-manager-02` |
| `vault.uri` | `https://dpn-vault-https-02.ns-dpn-01.svc.cluster.local:8200` |
| `vault.appRole.roleId` | `<role-id>` |
| `oauth2.clientId` | `<client-id>` |
| `cert.subject.cn` / `cert.subject.altNames` | `<cn>` / `<sans>` |
| `otel.env.OTEL_SERVICE_NAME` | `dpn-certificate-manager-02` |
| `keyvault.approleSecretName` / `keyvault.tokenSecretName` | `VAULT-APPROLE-SECRET-ID-02` / `VAULT-TOKEN-02` |
| `existingSecret.name` | `certificate-manager-02-secrets` |

**gRPC federator** — `charts/dpn-platform/values-<env>-<cluster>-0N.yaml`

| Key | Value |
|-----|-------|
| `federatorServer.name` / `federatorClient.name` | `dpn-federator-server-2` / `dpn-federator-client-2` |
| `federatorServer.service.loadBalancerIP` / `federatorClient.service.loadBalancerIP` | `""` |
| `federatorServer.idp.clientId` / `federatorClient.idp.clientId` | `<client-id>` |
| `vaultConfig.uri` | `https://dpn-vault-https-02.ns-dpn-01.svc.cluster.local:8200` |
| `vaultConfig.tokenSecretName` / `vaultConfig.appRole.secretIdSecretName` | `certificate-manager-02-secrets` |
| `vaultConfig.appRole.roleId` | `<role-id>` |

**REST federator** — `charts/dpn-rest-federator/values-<env>-<cluster>-0N.yaml` (all keys under `restFederatorServer`)

| Key | Value |
|-----|-------|
| `name` | `dpn-rest-federator-server-2` |
| `service.loadBalancerIP` | `""` |
| `redis.host` / `redis.prefix` | `dpn-rest-federator-redis-2.ns-dpn-01.svc.cluster.local` / `federator-server-2` |
| `idp.clientId` | `<client-id>` |
| `vault.uri` | `https://dpn-vault-https-02.ns-dpn-01.svc.cluster.local:8200` |
| `vault.tokenSecretName` / `vault.appRole.secretIdSecretName` | `certificate-manager-02-secrets` |
| `vault.appRole.roleId` | `<role-id>` |
| `otel.serviceName` | `rest-federator-server-2` |

**REST federator Redis** — `charts/dpn-redis/values-<env>-<cluster>-0N.yaml`

| Key | Value |
|-----|-------|
| `redisCache.name` | `dpn-rest-federator-redis-2` |

**Demo runner client (optional)** — `charts/dpn-demo-runner-client/values-<env>-<cluster>-0N.yaml` (all keys under `job`)

| Key | Value |
|-----|-------|
| `name` / `env.senderFmarId` | `dpn-demo-runner-client-2` |
| `redis.host` / `redis.prefix` | `dpn-rest-federator-redis-2.ns-dpn-01.svc.cluster.local` / `federator-client-2` |
| `idp.clientId` | `<client-id>` |
| `clientProperties.configMapName` | `dpn-rest-federator-client-2-properties` |
| `vault.uri` | `https://dpn-vault-https-02.ns-dpn-01.svc.cluster.local:8200` |
| `vault.tokenSecretName` / `vault.appRole.secretIdSecretName` | `certificate-manager-02-secrets` |
| `vault.appRole.roleId` | `<role-id>` |
| `otel.serviceName` | `demo-runner-client-2` |

Notes:

- Keep `loadBalancerIP: ""` in the overlay (or set a free IP); otherwise the primary's IP is inherited.
- Do not set the federator ConfigMap names; `shared-federator-cd` sets them.
- A few of the values in the tables above point to something that doesn't exist yet at the point the file is created — for example, a Vault address or a Key Vault secret name. That's expected: an earlier step in the Step 3 deploy sequence creates it before this component actually needs it. The table below explains what each of these values refers to and which step creates it:

| Overlay value | Object | Created by |
|---------------|--------|-----------|
| `vault.uri` / `vaultConfig.uri` | Vault Service `dpn-vault-https-0N` | `shared-vault-https-cd` |
| `keyvault.tokenSecretName` | Key Vault `VAULT-TOKEN-0N` | `shared-vault-https-cd` (Vault Init) |
| `keyvault.approleSecretName` | Key Vault `VAULT-APPROLE-SECRET-ID-0N` | `shared-vault-approle-setup-cd` |
| `existingSecret.name`, `tokenSecretName`, `secretIdSecretName` | Secret `certificate-manager-0N-secrets` | `shared-certificate-manager-cd` |
| `redis.host` | Redis Service `dpn-rest-federator-redis-N` | `shared-rest-federator-cd` |

**Vault credentials** — these values are never entered manually; the overlays only reference them by name.

| Credential | Created by | Stored in | Reaches the components through |
|------------|-----------|-----------|--------------------------------|
| Vault root token | `shared-vault-https-cd` (Vault Init, `runVaultInit: true`) | Key Vault `VAULT-TOKEN-0N` | Used by the Vault bundle, AppRole and Certificate Manager pipelines only |
| AppRole secret-id | `shared-vault-approle-setup-cd` (never printed; expires after 355 days, so re-run the pipeline before then) | Key Vault `VAULT-APPROLE-SECRET-ID-0N` | Certificate Manager SecretProviderClass `dpn-certificate-manager-0N-kv-secrets` syncs it into Secret `certificate-manager-0N-secrets` (key `VAULT_APPROLE_SECRET_ID`). The federator, REST federator and demo runner client read it from that Secret (`secretIdSecretName`) |
| AppRole role ID | `shared-vault-approle-setup-cd` (artifact `shared-dpn-approle-role-ids`) | The overlays (`<role-id>`) | Entered manually, see Step 1 |

### Existing files to update

| Repository | File | Change |
|------------|------|--------|
| `dpn-health-monitoring-service` | `charts/dpn-portal/values-dpn01.yaml` | Add the new instance's job runner and Vault web addresses to the portal, so they appear as clickable tiles: a **"GRPC Gateway Client N"** tile (under Gateway) and a **"Certification Vault Service N"** tile (under Security). |
| `dpn-authentication-service` | `charts/keycloak/scripts/configure-keycloak.sh` | Allow the new instance's job runner to log in through Keycloak, by adding its web address as an approved login redirect for the shared `dpn-service-client` login client. |

**Exact values for the DPN Portal file** (replace `N` with the actual instance number):
- Add to `otherUiUrls`: `https://dpn-federator-client-N-external.ns-dpn-01.svc.cluster.local:8085/` and `https://dpn-vault-https-0N-lb.ns-dpn-01.svc.cluster.local:8200`
- Add tiles with those same URLs: `GRPC Gateway Client N` (Gateway section), `Certification Vault Service N` (Security section)

**Exact change for the Keycloak script** (replace `N` with the actual instance number):
- Define `KC_UI_HOST_FEDERATOR_CLIENT_N`, defaulting to `dpn-federator-client-N-external.ns-dpn-01.svc.cluster.local:8085`
- Add `"https://" + that host + "/*"` to `redirectUris`, and `"https://" + that host` to `webOrigins`

---

## Step 3: Deploy

Run the steps in order; each one produces something the next needs. Every step deploys separate `-0N` releases, so the primary is not touched. The `shared-*` pipelines are Azure DevOps pipelines in `.pipelines/azure-pipelines/cd-pipelines/shared-dpn/` of each repository.

**Pipeline inputs**

| Parameter | Pipelines | Value |
|-----------|-----------|-------|
| `ServiceConnection` | All | The service connection for the target environment (the default is the dev connection) |
| `environment` | All | Your environment. Same in every run |
| `dpnCluster` / `dpncluster` / `cluster` | `dpn-federator-certificate-manager` / `dpn-federator-gateway` / `dpn-rest-federator-gateway` | Your cluster. The parameter name differs per repository |
| `totalDpnCount` | All | Total DPNs **including the primary**: `2` deploys `02`, `3` deploys `02` and `03`. Same in every run |
| `imageTag` | Certificate Manager, federator, REST federator, demo runner client | Image tag to deploy. Required |
| `vaultImageTag` | `shared-vault-https-cd` | Default `1.16` |

**Sequence**

| # | Step | Pipeline / action | Needs | Produces |
|---|------|-----------------------|-------|----------|
| 1 | Prepare | Commit the overlays (Step 2) with the `roleId` placeholder still in place. Upload the Vault bundle secure files | Step 1 identity | Overlays, secure files |
| 2 | Deploy the Vaults | `shared-vault-https-cd` | The Vault values file from Step 2 | A running Vault (`vault-https-0N`); its root token saved to Key Vault as `VAULT-TOKEN-0N`; and a downloadable file (`shared-vault-init-output`) containing the root token and recovery keys — restrict who can access this file |
| 3 | Load the Vault bundles | `shared-vault-load-bundle-cd` | The three files uploaded as Secure Files in step 1 — `bootstrap-0N.key` (reused from the primary's `dpn-tls-cd` pipeline artifact), and `certificate-0N.pem`/`ca-chain-0N.pem` (the signed certificate and CA chain from bootstrapping this LOE at the DSM portal) | The certificate bundle is loaded into the running Vault (`dpn-vault-https-0N`) |
| 4 | Create the AppRoles | `shared-vault-approle-setup-cd` | `VAULT-TOKEN-0N` | Key Vault `VAULT-APPROLE-SECRET-ID-0N`; artifact `shared-dpn-approle-role-ids` |
| 5 | Add the role IDs | Edit and commit the Certificate Manager, federator, REST federator and demo runner client values files, replacing the `<role-id>` placeholder with the real role ID | Artifact from step 4 | Values files without placeholders |
| 6 | Deploy the Certificate Managers | `shared-certificate-manager-cd` | `dpn-vault-https-0N`, `VAULT-APPROLE-SECRET-ID-0N`, `tls-auth-secret` | `dpn-certificate-manager-0N`; Secret `certificate-manager-0N-secrets`; ConfigMap `dpn-certificate-manager-0N-config` |
| 7 | Deploy the gRPC federators | `shared-federator-cd` | Primary release `dpn-platform`, step 6 outputs, `tls-auth-secret`, Key Vault `TRUSTSTORE-PASSWORD` | `dpn-platform-0N` |
| 8 | Deploy the REST federators and their Redis | `shared-rest-federator-cd` | Step 6 outputs, `tls-auth-secret`, `TRUSTSTORE-PASSWORD` | `dpn-redis-0N`, `dpn-rest-federator-0N` |
| 9 | Run the demo runner client (optional) | `shared-demo-runner-client-cd` | Step 6 and 8 outputs, `cert-manager-truststore`, `dpn-keycloak-secrets` | Job `dpn-demo-runner-client-N-<BuildId>` |
| 10 | Update the Keycloak redirect URIs | Keycloak CD pipeline | `configure-keycloak.sh` updated to add the new job runner's redirect URI and web origin (see Step 2, "Existing files to update") | Job runner `N` login works |
| 11 | Update the health portal | Portal CD pipeline | `values-dpn01.yaml` updated to add the new instance's portal tile and URLs (see Step 2, "Existing files to update") | Portal tiles for the instance |
| 12 | Create the LOE's data products | Shared self-service UI | — | Data products |

Before deploying, the Certificate Manager, federator, REST federator and demo runner client pipelines check every instance's overlay (names, placeholders), run `helm lint`, a dry-run and the Vault wiring check, and stop if any instance fails. The Vault bundle and AppRole pipelines only check that the Vault overlay exists.

---

## Step 4: Verify

Replace `02` with the instance number that was deployed.

```bash
# Releases exist
helm list -n ns-dpn-01
# expect: vault-https-02, dpn-certificate-manager-02, dpn-platform-02, dpn-rest-federator-02, dpn-redis-02 (+ dpn-demo-runner-client-02 if run)

# Vault is running and unsealed
kubectl exec deploy/dpn-vault-https-02 -n ns-dpn-01 -- sh -c 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status'   # Sealed: false
kubectl get pvc dpn-vault-https-02-data -n ns-dpn-01

# Certificate Manager uses its own Vault and the LOE's identity
kubectl rollout status deploy/dpn-certificate-manager-02 -n ns-dpn-01
kubectl get cm dpn-certificate-manager-02-config -n ns-dpn-01 -o yaml | grep -E 'VAULT_URI|OAUTH2_CLIENT_ID|VAULT_APPROLE_ROLE_ID'
kubectl get secret certificate-manager-02-secrets -n ns-dpn-01

# gRPC federators use the LOE's client ID
kubectl rollout status deploy/dpn-federator-server-2 -n ns-dpn-01
kubectl rollout status deploy/dpn-federator-client-2 -n ns-dpn-01
kubectl get cm dpn-federator-server-2-common-config dpn-federator-client-2-common-config -n ns-dpn-01 -o yaml | grep '^ *idp.client.id'

# Shared services are not duplicated
kubectl get deploy -n ns-dpn-01 | grep -E "dpn-kafka-(src|target)"   # exactly one set

# Primary is unaffected
helm history dpn-platform -n ns-dpn-01   # no new revision
```

Then check in the browser:

- Log in to the job runner at `https://dpn-federator-client-2-external.ns-dpn-01.svc.cluster.local:8085/`.
- The `GRPC Gateway Client 2` and `Certification Vault Service 2` tiles show as up in the DPN Portal.

---

## Shared Services

These services are not duplicated per LOE and need no new files. Only two existing files are updated, as described in Step 2 ("Existing files to update"):

- **Keycloak** — `configure-keycloak.sh`: add the instance's job runner URL to the `dpn-service-client` redirect URIs and web origins, then run the Keycloak CD pipeline.
- **DPN Portal** — `values-dpn01.yaml`: add the instance's job runner and Vault URLs and tiles, then run the portal CD pipeline.

| Service | Notes |
|---------|-------|
| Authentication Service (Keycloak) | One realm and `dpn-service-client` for all LOEs |
| Kafka source/target, ZooKeeper, Kafka UI, federator Redis | Shared by all gRPC federators. Redis keys are separated by DSM client ID, so each LOE needs its own client ID |
| Data pipelines, File Scan Service | Shared; each LOE uses its own data products |
| TLS (`dpn-tls`, `tls-auth-secret`) | Wildcard SAN (`*.ns-dpn-01.svc.cluster.local`) already covers the `-0N` Service names |
| Key Vault, unseal key, managed identity, `TRUSTSTORE-PASSWORD` | Reused from the primary; only `VAULT-TOKEN-0N` and `VAULT-APPROLE-SECRET-ID-0N` are new |
| Demo runner backend (`dpn-demo-runner-server-1`) | Shared; only the client Job is per instance |
| Storage accounts / blob containers | One shared set |
| Container registry | Same registry as the primary; the image tag comes from the `imageTag` pipeline parameter |

---

## Secrets Summary

| Secret | Location | Created by | Note |
|--------|----------|-----------|------|
| Vault root token | Key Vault `VAULT-TOKEN-0N` | `shared-vault-https-cd` (Vault Init) | Used by the pipelines only |
| Vault init output | Run artifact `shared-vault-init-output` | `shared-vault-https-cd` (Vault Init) | Contains the root token and recovery keys. Restrict access to the run and store the recovery keys securely |
| AppRole secret-id | Key Vault `VAULT-APPROLE-SECRET-ID-0N` → Secret `certificate-manager-0N-secrets` (key `VAULT_APPROLE_SECRET_ID`) | `shared-vault-approle-setup-cd` | Expires after 355 days; re-run the pipeline before then |
| Vault bundle | Secure files `bootstrap-0N.key`, `certificate-0N.pem`, `ca-chain-0N.pem` → Vault `dpn-vault-https-0N` | Uploaded manually | `bootstrap-0N.key` is the same key reused from the primary's `dpn-tls-cd` pipeline artifact; `certificate-0N.pem`/`ca-chain-0N.pem` come from bootstrapping this LOE at the DSM portal. Together they're this LOE's client certificate for communication with DSM |
| Reused from the primary | Key Vault `TRUSTSTORE-PASSWORD`; Secrets `tls-auth-secret`, `cert-manager-truststore`, `dpn-keycloak-secrets` | Primary setup | Not created again |

---

## Rollback and Removal

The shared pipelines only touch the `-0N` releases, never the primary. They act on **every** instance `02` to `totalDpnCount`; to roll back or remove a single LOE, use the `helm` commands below.

| Component | Rollback pipeline | Uninstall pipeline | `component` parameter |
|-----------|-------------------|--------------------|-----------------------|
| Vault and Certificate Manager | `shared-certificate-manager-rollback` | `shared-certificate-manager-uninstall-cd` | Rollback: `certificate-manager` (default) or `vault-https`. Uninstall: `certificate-manager` (default), `vault-https` or `both` (Certificate Manager first, then Vault) |
| Federator server and client | `shared-federator-rollback` | `shared-federator-uninstall-cd` | — |
| REST Federator and Redis | `shared-rest-federator-rollback` | `shared-rest-federator-uninstall-cd` | Rollback: `rest-federator` (default) or `redis`. Uninstall: `rest-federator`, `redis` or `both` (default) |
| Demo runner client | — | `shared-demo-runner-client-uninstall-cd` | — |

For the rollback pipelines, leave `revisions` empty to roll every instance back to its previous stable revision, or pin some, for example `02=5,03=7`. All target revisions are validated before any rollback runs.

The same actions by hand:

```bash
helm history dpn-platform-02 -n ns-dpn-01
helm rollback <release>-0N <revision> -n ns-dpn-01 --wait     # dpn-platform-0N, dpn-rest-federator-0N, dpn-redis-0N, dpn-certificate-manager-0N, vault-https-0N

# Remove one LOE entirely
helm uninstall dpn-demo-runner-client-02 dpn-rest-federator-02 dpn-redis-02 dpn-platform-02 dpn-certificate-manager-02 vault-https-02 -n ns-dpn-01
```

Uninstalling `vault-https-0N` also deletes the PVC `dpn-vault-https-0N-data`, which is that Vault's data. A Vault chart rollback does not change data on the PVC. Key Vault entries are **not** removed by the pipelines. After uninstalling, also clean up for the retired LOE only: Key Vault entries `VAULT-TOKEN-0N` and `VAULT-APPROLE-SECRET-ID-0N`, the `-0N` secure files, the `-0N` overlays, the portal `otherUiUrls` and tile entries, the job runner URL in `configure-keycloak.sh`, the DSM registration, and the LOE's data products.

Never delete `dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, the shared Kafka/Redis, the storage accounts or the primary's `VAULT-*` entries. Rolling back a **shared** component affects all LOEs — coordinate centrally.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
|  Nov-2026 | DSI Assurance   | Final | V1.0.0 |
