Release : 2.1.0 - Oct 2026

# Deploy and Operate a Shared DPN

---

## Table of Contents

- [Overview](#overview)
- [Deployment Order](#deployment-order)
- [Deploying with Azure DevOps (`sharedDPN`)](#deploying-with-azure-devops-shareddpn)
- [Deploying with GitHub Actions (azure-gha-beta and aws-gha-beta) Today](#deploying-with-github-actions-azure-gha-beta-and-aws-gha-beta-today)
- [Verification](#verification)
- [Day-2 Operations](#day-2-operations)
- [Rollback](#rollback)
- [Removing an LOE](#removing-an-loe)
- [Adding a Further LOE](#adding-a-further-loe)
- [Troubleshooting](#troubleshooting)
- [Known Limitations and Open Points](#known-limitations-and-open-points)
- [Review Notes](#review-notes)

---

## Overview

This guide covers deploying the LOE stack configured in [02 — Configure a Shared DPN](02-configure-shared-dpn.md), checking it, and running it afterwards. [01 — Overview](01-shared-dpn-architecture-overview.md) explains the architecture.

Throughout, the **primary** LOE is the existing DPN and the **new LOE** is instance `-02`. Namespace is `ns-dpn-01` in the examples.

> **Before you start:** the new LOE's deployment must not disturb the running primary. Every step below either deploys a separate `-02` release or re-applies the primary release **unchanged** (same values, same image tag). Run the federator and REST federator pipelines in a planned window.

---

## Deployment Order

The order matters: each step produces something the next one needs.

| # | Step | Produces / needs | Azure DevOps pipeline |
|---|------|------------------|-----------------------|
| 1 | **Deploy the second Vault** `dpn-vault-02` | Own PVC, Services, load balancer. Stores the root token as `VAULT-TOKEN-02` | `vault-https-cd` with `sharedDPN=true` |
| 2 | **Load the new LOE's Vault bundle** (key, certificate, CA chain) | Needs secure files `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` | `vault-load-bundle-cd` with `sharedDPN=true` |
| 3 | **Create the AppRole** for the new Vault | Stores `VAULT-APPROLE-SECRET-ID-02` in Key Vault and **prints the `roleId`** | `vault-approle-setup-cd` with `sharedDPN=true` |
| 4 | **Put the `roleId` into the overlays** | Certificate manager `-02`, federator `-02` and REST federator `-02` values | *(edit and commit)* |
| 5 | **Deploy the second Certificate Manager** | Fails fast if `dpn-vault-02` or `VAULT-APPROLE-SECRET-ID-02` is missing, or a placeholder remains | `certificate-manager-cd` with `sharedDPN=true` |
| 6 | **Deploy the second Federator server/client** | Release `dpn-platform-02`, shares Kafka and Redis. Needs the certificate manager `-02` Secret | `azure-dpn-cd` (federator gateway) — deploys primary then secondary |
| 7 | **Deploy the second REST Federator** (and its Redis) | Releases `dpn-redis-02` and `dpn-rest-federator-02` | `rest-federator-cd` — deploys primary then secondary |
| 8 | **Update the health portal** | Tiles and allow-list for the new components | Health monitoring portal deployment |
| 9 | **Create the LOE's data products** | Through the shared self-service | *(self-service UI)* |

---

## Verification

Run these after deployment. Replace `ns-dpn-01` if your namespace differs.

### 1. Both LOE stacks are running, as separate releases

```bash
helm list -n ns-dpn-01
# expect (among others): vault-https, vault-https-02, dpn-certificate-manager, dpn-certificate-manager-02,
#                        dpn-platform, dpn-platform-02, dpn-rest-federator, dpn-rest-federator-02, dpn-redis-02

kubectl get deploy -n ns-dpn-01 | grep -E "dpn-vault|certificate-manager|federator|rest-federator"
kubectl get pvc -n ns-dpn-01 | grep dpn-vault          # a separate dpn-vault-02-data volume
kubectl get svc -n ns-dpn-01 | grep -E "dpn-vault-02|federator-(server|client)-2|rest-federator-server-2"
```

### 2. The new LOE uses its own Vault and credentials

```bash
kubectl get secret certificate-manager-02-secrets -n ns-dpn-01        # exists; separate from certificate-manager-secrets
kubectl get secretproviderclass -n ns-dpn-01 | grep -E "02-kv-secrets"
kubectl logs deploy/dpn-certificate-manager-02 -n ns-dpn-01 --tail=100 # authenticates to dpn-vault-02, no errors
```

### 3. The federators are the new LOE

```bash
kubectl rollout status deploy/dpn-federator-server-2 -n ns-dpn-01
kubectl rollout status deploy/dpn-federator-client-2 -n ns-dpn-01
kubectl get cm -n ns-dpn-01 | grep common-config                      # one pair per instance
kubectl get cm dpn-federator-server-2-common-config -n ns-dpn-01 -o yaml | grep -i client   # idp.client.id is the new LOE's
```

### 4. Shared services are shared, not duplicated

```bash
kubectl get deploy -n ns-dpn-01 | grep -E "dpn-kafka-(src|target)|dpn-redis$"   # exactly one set
kubectl get deploy -n ns-dpn-01 | grep -c dpn-redis                              # the REST federator Redis instances are separate by design
```

### 5. Primary is unaffected

```bash
kubectl get pods -n ns-dpn-01 -l app=dpn-vault-https
kubectl get pods -n ns-dpn-01 -l app=dpn-certificate-manager
helm history dpn-platform -n ns-dpn-01        # primary revision unchanged, or only a no-op upgrade from the pipeline
```

---

## Rollback

| What to roll back | Procedure | Effect on other LOEs |
|-------------------|-----------|----------------------|
| Federator server/client of the new LOE | `helm history dpn-platform-02 -n ns-dpn-01` then `helm rollback dpn-platform-02 <revision> -n ns-dpn-01 --wait` | None |
| REST federator of the new LOE | `helm rollback dpn-rest-federator-02 <revision> -n ns-dpn-01 --wait` | None |
| Certificate manager of the new LOE | `helm rollback dpn-certificate-manager-02 <revision> -n ns-dpn-01 --wait` | None |
| Vault of the new LOE | `helm rollback vault-https-02 <revision> -n ns-dpn-01 --wait`. Vault data lives on its own PVC (`dpn-vault-02-data`) and is not changed by a chart rollback | None |
| A **shared** component | Use the component's own rollback procedure | **All LOEs** — coordinate centrally |

---

## Removing an LOE

Remove only the `-02` releases. Do not run an "all components" removal against a shared DPN.

```bash
helm uninstall dpn-rest-federator-02 dpn-redis-02 dpn-platform-02 dpn-certificate-manager-02 vault-https-02 -n ns-dpn-01
```

Then clean up what Helm does not remove, **for the new LOE only**:

| Item | Action |
|------|--------|
| Vault PVC `dpn-vault-02-data` | Delete only when the LOE's Vault data is no longer needed (this is the LOE's Vault content) |
| Key Vault entries `VAULT-TOKEN-02`, `VAULT-APPROLE-SECRET-ID-02` | Delete or disable |
| Secret `certificate-manager-02-secrets` and the `-02` SecretProviderClasses | Removed with the releases; confirm |
| Deployment secure files `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` | Remove from the library |
| Portal tiles and allow-list entries for the `-02` components | Remove |
| The LOE's DSM client registration and certificates | Retire through DSM |
| The LOE's data products, containers and topics | Decommission through the self-service and storage processes |

Never delete `dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, the shared Kafka/Redis, the storage accounts or the primary's `VAULT-*` entries — other LOEs depend on them.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | Not yet reviewed | Draft | V0.1.0 |
