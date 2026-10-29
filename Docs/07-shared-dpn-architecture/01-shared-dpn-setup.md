# Set Up a Shared DPN

This guide covers everything needed to add one more LOE to an existing DPN: prerequisites, configuration and deployment.

---

## Table of Contents

- [Approach](#approach)
- [Prerequisites](#prerequisites)
- [Step 1: Agree the Naming Plan](#step-1-agree-the-naming-plan)
- [Step 2: Gather the LOE Identity](#step-2-gather-the-loe-identity)
- [Step 3: Create the `-02` Values Files](#step-3-create-the--02-values-files)
- [Step 4: Deploy](#step-4-deploy)
- [Step 5: Verify](#step-5-verify)
- [Shared Services (No Change Needed)](#shared-services-no-change-needed)
- [Secrets Summary](#secrets-summary)
- [Rollback and Removal](#rollback-and-removal)
- [Review Notes](#review-notes)

---

## Approach

Each LOE has its **own** Vault, Certificate Manager, gRPC federator (server and client) and REST federator (with its own Redis). Everything else is shared.

For every dedicated component:

1. Keep the primary values file **unchanged**.
2. Add a `-02` overlay containing **only what differs** (instance name, identity, Vault address and credentials).
3. Deploy it as its **own Helm release**, layering the overlay on the primary file (`-f primary.yaml -f primary-02.yaml`). Everything not overridden is inherited.

---

## Prerequisites

- A working **primary DPN** on the target cluster (Vault, Certificate Manager, Federator, Kafka, Redis, Keycloak, Data Pipelines, File Scan and Health Monitoring).
- The new LOE **registered in the same DSM**, with its **client ID** and certificate.
- The new LOE's **Vault bundle** (private key, certificate, CA chain) uploaded as deployment secure files: `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem`.
- Spare **cluster capacity** for the extra pods and a second Vault PVC.
- A free **internal IP** for each additional load balancer, or agreement to let the cloud assign one.
- The `release-internal/*-shared-dpn` versions of the component repositories (or a `develop` that has merged them).

---

## Step 1: Agree the Naming Plan

Agree these names with the central DPN team **before** creating any file. **Never reuse a primary name** — a repeated name makes one release overwrite the other's Deployment, ConfigMap or Secret.

| Item | Primary LOE | New LOE (`-02`) |
|------|-------------|-----------------|
| Vault Deployment / Service / PVC | `dpn-vault-https` | `dpn-vault-02`, `dpn-vault-02-lb`, `dpn-vault-02-data` |
| Vault SecretProviderClass | `dpn-vault-https-kv-secrets` | `dpn-vault-02-kv-secrets` |
| Certificate Manager | `dpn-certificate-manager` | `dpn-certificate-manager-02` |
| Certificate Manager SecretProviderClass → Secret | `dpn-certificate-manager-kv-secrets` → `certificate-manager-secrets` | `dpn-certificate-manager-02-kv-secrets` → `certificate-manager-02-secrets` |
| Federator server / client | `dpn-federator-server-1` / `dpn-federator-client-1` | `dpn-federator-server-2` / `dpn-federator-client-2` |
| Federator common-config ConfigMaps | `federator-common-config-server` / `-client` | `<server name>-common-config` / `<client name>-common-config` |
| REST Federator server | `dpn-rest-federator-server-1` | `dpn-rest-federator-server-2` |
| REST Federator Redis | `dpn-rest-federator-redis-1` | `dpn-rest-federator-redis-2` |
| Key Vault: Vault root token | `VAULT-TOKEN` | `VAULT-TOKEN-02` |
| Key Vault: AppRole secret-id | `VAULT-APPROLE-SECRET-ID` | `VAULT-APPROLE-SECRET-ID-02` |
| Secure files (Vault bundle) | `bootstrap.key`, `certificate.pem`, `ca-chain.pem` | `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` |
| Certificate host names (SANs) | `producer…`, `consumer…` | `producer02…`, `consumer02…` (your LOE's own names) |

---

## Step 2: Gather the LOE Identity

| Item | Source | Used in |
|------|--------|---------|
| **DSM client ID** | The LOE's client in the same DSM | Certificate Manager `oauth2.clientId`; federator and REST federator `idp.clientId` |
| **Certificate subject** (`cn`, `altNames`) | Your certificate request | Certificate Manager `cert.subject.cn` / `cert.subject.altNames` |
| **Vault bundle** | Issued for the LOE | Secure files, loaded into the new Vault |
| **AppRole `roleId`** | Printed by the AppRole setup run (Step 4, item 3). Not known in advance | Certificate Manager `vault.appRole.roleId`; federator and REST federator `vault.appRole.roleId` |

The overlays ship with `<PLACEHOLDER-…>` markers (for example `<PLACEHOLDER-VAULT-02-APPROLE-ROLE-ID>`). The Certificate Manager deployment **fails while any placeholder remains**, so fill in the `roleId` after the AppRole run and before deploying it.

---

## Step 3: Create the `-02` Values Files

Copy each primary file to a `-02` file and change only what differs, using the names from Step 1 and the identity from Step 2.

| Component | Primary values file | `-02` overlay | Helm release |
|-----------|--------------------|---------------|--------------|
| Vault | `charts/vault-https/values-<env>-<cluster>.yaml` | `…-02.yaml` | `vault-https-02` |
| Certificate Manager | `charts/certificate-manager/values-<env>-<cluster>.yaml` | `…-02.yaml` | `dpn-certificate-manager-02` |
| Federator server and client | `charts/dpn-platform/values-<env>-<cluster>.yaml` | `…-02.yaml` | `dpn-platform-02` |
| REST Federator server | `charts/dpn-rest-federator/values-<env>-<cluster>.yaml` | `…-02.yaml` | `dpn-rest-federator-02` |
| REST Federator Redis | `charts/dpn-redis/values-<env>-<cluster>.yaml` | `…-02.yaml` | `dpn-redis-02` |

Notes:

- The gRPC federator `-02` shares the primary's Kafka source and target, ZooKeeper, Kafka UI and Redis.
- Each REST federator has **its own Redis**.
- The REST federator `-02` chart copy contains only the server Deployment, Service, load balancer Service and ConfigMap.
- Data pipelines are shared; the LOE only creates its own data products (Step 4, item 9).

---

## Step 4: Deploy

Order matters: each step produces something the next needs. Deploying `-02` must not disturb the primary — each step deploys a separate `-02` release or re-applies the primary **unchanged**. Run the federator pipelines in a planned window.

| # | Step | Notes | Azure DevOps pipeline |
|---|------|-------|-----------------------|
| 1 | Deploy the second Vault `dpn-vault-02` | Own PVC, Services, load balancer. Stores `VAULT-TOKEN-02` | `vault-https-cd`, `sharedDPN=true` |
| 2 | Load the Vault bundle | Needs the three `-02` secure files | `vault-load-bundle-cd`, `sharedDPN=true` |
| 3 | Create the AppRole | Stores `VAULT-APPROLE-SECRET-ID-02` and **prints the `roleId`** | `vault-approle-setup-cd`, `sharedDPN=true` |
| 4 | Put the `roleId` into the `-02` overlays | Certificate Manager, federator, REST federator | *(edit and commit)* |
| 5 | Deploy the second Certificate Manager | Fails fast if `dpn-vault-02` or `VAULT-APPROLE-SECRET-ID-02` is missing, or a placeholder remains | `certificate-manager-cd`, `sharedDPN=true` |
| 6 | Deploy the second Federator server/client | Release `dpn-platform-02`; needs the Certificate Manager `-02` Secret | `azure-dpn-cd` (deploys primary then secondary) |
| 7 | Deploy the second REST Federator and its Redis | Releases `dpn-redis-02`, `dpn-rest-federator-02` | `rest-federator-cd` (deploys primary then secondary) |
| 8 | Update the health portal | Tiles and allow-list for the new components | Health monitoring portal deployment |
| 9 | Create the LOE's data products | Through the shared self-service UI, using the agreed naming | *(self-service UI)* |

---

## Step 5: Verify

```bash
# Separate releases and resources exist
helm list -n ns-dpn-01
# expect: vault-https-02, dpn-certificate-manager-02, dpn-platform-02, dpn-rest-federator-02, dpn-redis-02
kubectl get pvc -n ns-dpn-01 | grep dpn-vault            # separate dpn-vault-02-data volume

# New LOE uses its own Vault and credentials
kubectl get secret certificate-manager-02-secrets -n ns-dpn-01
kubectl logs deploy/dpn-certificate-manager-02 -n ns-dpn-01 --tail=100   # authenticates to dpn-vault-02, no errors

# Federators are the new LOE
kubectl rollout status deploy/dpn-federator-server-2 -n ns-dpn-01
kubectl rollout status deploy/dpn-federator-client-2 -n ns-dpn-01
kubectl get cm dpn-federator-server-2-common-config -n ns-dpn-01 -o yaml | grep -i client   # new LOE's client id

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
| Authentication Service (Keycloak) | One realm and client serve all LOEs |
| Kafka source/target, ZooKeeper, Kafka UI, federator Redis | Shared by both gRPC federators |
| Data pipelines, File Scan Service | Shared; each LOE uses its own data products |
| Health Monitoring and OTEL Collector | The new LOE reports to the same collector endpoint |
| TLS (`dpn-tls`, `tls-auth-secret`) | Wildcard SAN already covers the `-02` names |
| Storage accounts / blob containers | One shared set |
| GHCR image access | Same `ghcr-pull-secret`; overlays inherit image and tag |

---

## Secrets Summary

| Secret / credential | Location | Created by |
|---------------------|----------|------------|
| New Vault root token | Key Vault `VAULT-TOKEN-02` | Vault deployment (`sharedDPN`) |
| AppRole secret-id | Key Vault `VAULT-APPROLE-SECRET-ID-02` → Secret `certificate-manager-02-secrets` (key `VAULT_APPROLE_SECRET_ID`) | Vault AppRole setup (`sharedDPN`) |
| Vault bundle | Secure files `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` | Uploaded manually |
| DSM client credentials / keystore | As for the primary, for the LOE's client | LOE registration |

---

## Rollback and Removal

Roll back or remove only the `-02` releases; other LOEs are unaffected.

```bash
helm history dpn-platform-02 -n ns-dpn-01
helm rollback <release>-02 <revision> -n ns-dpn-01 --wait     # dpn-platform-02, dpn-rest-federator-02, dpn-certificate-manager-02, vault-https-02

# Remove the new LOE entirely
helm uninstall dpn-rest-federator-02 dpn-redis-02 dpn-platform-02 dpn-certificate-manager-02 vault-https-02 -n ns-dpn-01
```

A Vault chart rollback does not change data on the `dpn-vault-02-data` PVC. After uninstalling, also clean up for the new LOE only: the PVC (when its Vault data is no longer needed), Key Vault entries `VAULT-TOKEN-02` and `VAULT-APPROLE-SECRET-ID-02`, the `-02` secure files, portal tiles and allow-list entries, the DSM registration, and the LOE's data products.

Never delete `dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, the shared Kafka/Redis, the storage accounts or the primary's `VAULT-*` entries. Rolling back a **shared** component affects all LOEs — coordinate centrally.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
|  Oct-2026 | DSI Assurance   | Final | V0.1.0 |
