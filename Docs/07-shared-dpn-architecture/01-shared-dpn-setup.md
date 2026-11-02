# Set Up a Shared DPN

This guide covers the process of setting up Shared DPN.

---

## Table of Contents

- [Approach](#approach)
- [Prerequisites](#prerequisites)
- [Step 1: Naming Convention](#step-1-naming-convention)
- [Step 2: Gather the LOE Identity](#step-2-gather-the-loe-identity)
- [Step 3: Create the `-0N` Values Files](#step-3-create-the--0n-values-files)
- [Step 4: Deploy](#step-4-deploy)
- [Step 5: Verify](#step-5-verify)
- [Shared Services (No Change Needed)](#shared-services-no-change-needed)
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

## Step 1: Naming Convention

Names are derived from the instance number `N` (`02`, `03`, … in Vault and Certificate Manager names; `2`, `3`, … in federator and Redis names). **Never reuse a primary name** — a repeated name makes one release overwrite the other's Deployment, ConfigMap or Secret. The pipelines check these names and stop if they are wrong.

| Item | Primary LOE | Instance `0N` (example: `03`) |
|------|-------------|-------------------------------|
| Vault Helm release | `vault-https` | `vault-https-03` |
| Vault Deployment / Service | `dpn-vault-https` | `dpn-vault-https-03` |
| Vault load balancer Service | `dpn-vault-https-lb` | `dpn-vault-https-03-lb` |
| Vault PVC | `dpn-vault-https-data` | `dpn-vault-https-03-data` |
| Vault SecretProviderClass | `dpn-vault-https-kv-secrets` | `dpn-vault-https-03-kv-secrets` |
| Certificate Manager | `dpn-certificate-manager` | `dpn-certificate-manager-03` |
| Certificate Manager SecretProviderClass → Secret | `dpn-certificate-manager-kv-secrets` → `certificate-manager-secrets` | `dpn-certificate-manager-03-kv-secrets` → `certificate-manager-03-secrets` |
| Federator Helm release | `dpn-platform` | `dpn-platform-03` |
| Federator server / client | `dpn-federator-server-1` / `dpn-federator-client-1` | `dpn-federator-server-3` / `dpn-federator-client-3` |
| Federator ConfigMaps | `federator-common-config-server`, `federator-server-config` | `dpn-federator-server-3-common-config`, `dpn-federator-server-3-config` (and the same for the client) |
| REST Federator Helm release / server | `dpn-rest-federator` / `dpn-rest-federator-server-1` | `dpn-rest-federator-03` / `dpn-rest-federator-server-3` |
| REST Federator Redis Helm release / name | `dpn-redis` / `dpn-rest-federator-redis-1` | `dpn-redis-03` / `dpn-rest-federator-redis-3` |
| Demo runner client (optional) | `dpn-demo-runner-client` | `dpn-demo-runner-client-03` (Job `dpn-demo-runner-client-3`) |
| Key Vault: Vault root token | `VAULT-TOKEN` | `VAULT-TOKEN-03` |
| Key Vault: AppRole secret-id | `VAULT-APPROLE-SECRET-ID` | `VAULT-APPROLE-SECRET-ID-03` |
| Secure files (Vault bundle) | `bootstrap.key`, `certificate.pem`, `ca-chain.pem` | `bootstrap-03.key`, `certificate-03.pem`, `ca-chain-03.pem` |
| Certificate host names (SANs) | `producer…`, `consumer…` | The LOE's own names, for example `producer03…` |

The Vault overlay also sets `service.aliasEnabled: false`, so the `vault-https` alias Service that belongs to the primary is not created a second time.

---

## Step 2: Gather the LOE Identity

| Item | Source | Used in |
|------|--------|---------|
| **DSM client ID** | The LOE's client in the same DSM | Certificate Manager `oauth2.clientId`; federator and REST federator `idp.clientId` |
| **Certificate subject** (`cn`, `altNames`) | Your certificate request | Certificate Manager `cert.subject.cn` / `cert.subject.altNames` |
| **Vault bundle** | Issued for the LOE | Secure files, loaded into the new Vault |
| **AppRole `roleId`** | Printed by the AppRole setup run (Step 4, item 3). Not known in advance | Certificate Manager `vault.appRole.roleId`; federator `vaultConfig.appRole.roleId`; REST federator `restFederatorServer.vault.appRole.roleId` |

The DSM client ID must be the **same** in the Certificate Manager, federator and REST federator overlays of one instance. The wiring check fails if they differ.

Overlays that are not yet filled in carry `<PLACEHOLDER-…>` markers (for example `<PLACEHOLDER-VAULT-03-APPROLE-ROLE-ID>`). Every shared pipeline **fails while any placeholder remains**, so fill in the `roleId` after the AppRole run and before deploying the Certificate Manager.

---

## Step 3: Create the `-0N` Values Files

Copy each primary file to a `-0N` file and change only what differs, using the names from Step 1 and the identity from Step 2. Overlays are named `values-<env>-<cluster>-0N.yaml`, for example `values-dev-dpn01-03.yaml`. Overlays for `dev-dpn01` (`02` to `06`) and `test-dpn01` (`02` and `03`) already exist in the repositories; copy one for any other instance or environment.

| Component | Repository | Primary values file | `-0N` overlay | Helm release |
|-----------|-----------|--------------------|---------------|--------------|
| Vault | `dpn-federator-certificate-manager` | `charts/vault-https/values-<env>-<cluster>.yaml` | `…-0N.yaml` | `vault-https-0N` |
| Certificate Manager | `dpn-federator-certificate-manager` | `charts/certificate-manager/values-<env>-<cluster>.yaml` | `…-0N.yaml` | `dpn-certificate-manager-0N` |
| Federator server and client | `dpn-federator-gateway` | `charts/dpn-platform/values-<env>-<cluster>.yaml` | `…-0N.yaml` | `dpn-platform-0N` |
| REST Federator server | `dpn-rest-federator-gateway` | `charts/dpn-rest-federator/values-<env>-<cluster>.yaml` | `…-0N.yaml` | `dpn-rest-federator-0N` |
| REST Federator Redis | `dpn-rest-federator-gateway` | `charts/dpn-redis/values-<env>-<cluster>.yaml` | `…-0N.yaml` | `dpn-redis-0N` |
| Demo runner client (optional) | `dpn-rest-federator-gateway` | `charts/dpn-demo-runner-client/values-<env>-<cluster>.yaml` | `…-0N.yaml` | `dpn-demo-runner-client-0N` |

Notes:

- The Vault overlay is minimal (`fullnameOverride` and `service.aliasEnabled: false`). Seal, Key Vault unseal key, managed identity, TLS certificate, image and resources are inherited.
- The gRPC federator `-0N` shares the primary's Kafka source and target, ZooKeeper, Kafka UI and Redis. Its release installs only the federator server and client Deployments, Services, load balancer Services and ConfigMaps.
- Each REST federator has **its own Redis**, referenced from `restFederatorServer.redis.host` and `prefix` in its overlay.
- The REST federator `-0N` chart copy contains only the server Deployment, Service, load balancer Service and ConfigMap. The HPA is not duplicated and keeps targeting the primary.
- Data pipelines are shared; the LOE only creates its own data products (Step 4, item 9).

---

## Step 4: Deploy

Order matters: each step produces something the next needs. Deploying `0N` must not disturb the primary — each step deploys separate `-0N` releases. Run the federator pipelines in a planned window. Use the **same `environment`, `dpnCluster` and `totalDpnCount`** for every pipeline in the sequence.

| # | Step | Notes | Azure DevOps pipeline (`shared-dpn` folder) |
|---|------|-------|---------------------------------------------|
| 1 | Deploy the shared Vaults `dpn-vault-https-02..0N` | Own PVC, Services, load balancer per instance. Run Vault Init (`runVaultInit`, on by default) to store `VAULT-TOKEN-0N` | `shared-vault-https-cd` |
| 2 | Load the Vault bundles | Needs `bootstrap-0N.key`, `certificate-0N.pem`, `ca-chain-0N.pem` for every instance | `shared-vault-load-bundle-cd` |
| 3 | Create the AppRoles | Stores `VAULT-APPROLE-SECRET-ID-0N` in Key Vault (never printed) and **publishes each `roleId`** as a run artifact | `shared-vault-approle-setup-cd` |
| 4 | Put each `roleId` into the `-0N` overlays | Certificate Manager, federator, REST federator. Commit the change | *(edit and commit)* |
| 5 | Deploy the shared Certificate Managers | Fails fast if `dpn-vault-https-0N` or `VAULT-APPROLE-SECRET-ID-0N` is missing, a placeholder remains, or the `roleId` differs from the one its Vault reports | `shared-certificate-manager-cd` |
| 6 | Deploy the shared Federator servers and clients | Releases `dpn-platform-02..0N`; needs `certificate-manager-0N-secrets`. Deploys instance by instance | `shared-federator-cd` (`dpn-federator-gateway`) |
| 7 | Deploy the shared REST Federators and their Redis | Releases `dpn-redis-0N`, `dpn-rest-federator-0N` | `shared-rest-federator-cd` (`dpn-rest-federator-gateway`) |
| 8 | Run the demo runner client (optional) | One Job per instance; the demo backend is shared with the primary | `shared-demo-runner-client-cd` (`dpn-rest-federator-gateway`) |
| 9 | Update the health portal | Add the instance's Vault and job-runner URLs to `otherUiUrls` and tiles in `charts/dpn-portal/values-dpn01.yaml` (instances `02` and `03` are already listed) | Health monitoring portal deployment |
| 10 | Create the LOE's data products | Through the shared self-service UI, using the agreed naming | *(self-service UI)* |

The Vault, Certificate Manager and Vault bundle pipelines are in `dpn-federator-certificate-manager`. Each pipeline validates every instance first (values-file checks, `helm lint`, dry-run, wiring check), waits for the ADO environment approval, deploys instance by instance, and then verifies.

---

## Step 5: Verify

Replace `03` with the instance number you deployed.

```bash
# Separate releases and resources exist
helm list -n ns-dpn-01
# expect: vault-https-03, dpn-certificate-manager-03, dpn-platform-03, dpn-rest-federator-03, dpn-redis-03
kubectl get pvc -n ns-dpn-01 | grep dpn-vault            # separate dpn-vault-https-03-data volume

# New LOE uses its own Vault and credentials
kubectl get secret certificate-manager-03-secrets -n ns-dpn-01
kubectl logs deploy/dpn-certificate-manager-03 -n ns-dpn-01 --tail=100   # authenticates to dpn-vault-https-03, no errors

# Federators are the new LOE
kubectl rollout status deploy/dpn-federator-server-3 -n ns-dpn-01
kubectl rollout status deploy/dpn-federator-client-3 -n ns-dpn-01
kubectl get cm dpn-federator-server-3-common-config -n ns-dpn-01 -o yaml | grep -i client   # new LOE's client id

# REST federator has its own Redis
kubectl rollout status deploy/dpn-rest-federator-server-3 -n ns-dpn-01
kubectl get deploy -n ns-dpn-01 | grep dpn-rest-federator-redis

# Shared services are not duplicated
kubectl get deploy -n ns-dpn-01 | grep -E "dpn-kafka-(src|target)"      # exactly one set

# Primary is unaffected
kubectl get pods -n ns-dpn-01 -l app=dpn-vault-https
helm history dpn-platform -n ns-dpn-01                    # unchanged, or only a no-op upgrade
```

---

## Shared Services (No Change Needed)

Do not duplicate these for the new LOE.

| Service | Why |
|---------|-----|
| Authentication Service (Keycloak) | One realm and client serve all LOEs. The `dpn-service-client` redirect URIs and web origins cover job runners `1` to `3` only; see the note below the table |
| Kafka source/target, ZooKeeper, Kafka UI, federator Redis | Shared by all gRPC federators |
| Data pipelines, File Scan Service | Shared; each LOE uses its own data products |
| Health Monitoring and OTEL Collector | The new LOE reports to the same collector endpoint, under its own service name |
| TLS (`dpn-tls`, `tls-auth-secret`) | Wildcard SAN (`*.ns-dpn-01.svc.cluster.local`) already covers the `-0N` Service names |
| Key Vault, unseal key and managed identity | The shared Vaults reuse the primary's; only the root token and AppRole secret-id are new |
| Demo runner backend (`dpn-demo-runner-server-1`) | Shared; only the client Job is per instance |
| Storage accounts / blob containers | One shared set |
| GHCR image access | Same `ghcr-pull-secret`; overlays inherit image and tag |

For an instance `04` or higher, add its `dpn-federator-client-N-external` host to the `dpn-service-client` redirect URIs and web origins (`KC_UI_HOST_FEDERATOR_CLIENT_N` in `dpn-authentication-service/charts/keycloak/scripts/configure-keycloak.sh`) and redeploy Keycloak. Until then, job runner login for that instance fails.

---

## Secrets Summary

| Secret / credential | Location | Created by |
|---------------------|----------|------------|
| New Vault root token | Key Vault `VAULT-TOKEN-0N` | Vault Init in `shared-vault-https-cd` |
| AppRole secret-id | Key Vault `VAULT-APPROLE-SECRET-ID-0N` → Secret `certificate-manager-0N-secrets` (key `VAULT_APPROLE_SECRET_ID`) | `shared-vault-approle-setup-cd` |
| Vault bundle | Secure files `bootstrap-0N.key`, `certificate-0N.pem`, `ca-chain-0N.pem` | Uploaded manually |
| DSM client credentials / keystore | As for the primary, for the LOE's client | LOE registration |

---

## Rollback and Removal

Roll back or remove only the `-0N` releases; other LOEs are unaffected. Each component has a shared rollback and uninstall pipeline that takes the same `totalDpnCount`.

| Component | Rollback pipeline | Uninstall pipeline |
|-----------|-------------------|--------------------|
| Vault and Certificate Manager | `shared-certificate-manager-rollback` (select the `component`) | `shared-certificate-manager-uninstall-cd` (removes the Certificate Manager first, then the Vault) |
| Federator server and client | `shared-federator-rollback` | `shared-federator-uninstall-cd` |
| REST Federator and Redis | `shared-rest-federator-rollback` | `shared-rest-federator-uninstall-cd` |
| Demo runner client | — | `shared-demo-runner-client-uninstall-cd` |

For the rollback pipelines, leave `revisions` empty to roll every instance back to its previous stable revision, or pin some, for example `02=5,03=7`. All target revisions are validated before any rollback runs.

The same actions by hand:

```bash
helm history dpn-platform-03 -n ns-dpn-01
helm rollback <release>-0N <revision> -n ns-dpn-01 --wait     # dpn-platform-0N, dpn-rest-federator-0N, dpn-certificate-manager-0N, vault-https-0N

# Remove one LOE entirely
helm uninstall dpn-rest-federator-03 dpn-redis-03 dpn-platform-03 dpn-certificate-manager-03 vault-https-03 -n ns-dpn-01
```

Uninstalling `vault-https-0N` also deletes the PVC `dpn-vault-https-0N-data`, which is that Vault's data. A Vault chart rollback does not change data on the PVC. Key Vault entries are **not** removed by the pipelines. After uninstalling, also clean up for the retired LOE only: Key Vault entries `VAULT-TOKEN-0N` and `VAULT-APPROLE-SECRET-ID-0N`, the `-0N` secure files, portal tiles and allow-list entries, the DSM registration, and the LOE's data products.

Never delete `dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, the shared Kafka/Redis, the storage accounts or the primary's `VAULT-*` entries. Rolling back a **shared** component affects all LOEs — coordinate centrally.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
|  Nov-2026 | DSI Assurance   | Final | V1.0.0 |
