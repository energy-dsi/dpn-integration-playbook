Release : 2.1.0 - Oct 2026

# Configure a Shared DPN

---

## Table of Contents

- [Overview](#overview)
- [Configuration Files Used](#configuration-files-used)
- [Step 1: Agree the Naming Plan](#step-1-agree-the-naming-plan)
- [Step 2: Prepare the LOE Identity](#step-2-prepare-the-loe-identity)
- [Step 3: Vault for the New LOE](#step-3-vault-for-the-new-loe)
- [Step 4: Certificate Manager for the New LOE](#step-4-certificate-manager-for-the-new-loe)
- [Step 5: Federator Server and Client for the New LOE](#step-5-federator-server-and-client-for-the-new-loe)
- [Step 6: REST Federator for the New LOE](#step-6-rest-federator-for-the-new-loe)
- [Step 7: Data Products for the New LOE](#step-7-data-products-for-the-new-loe)
- [Step 8: File Scan Service (Shared)](#step-8-file-scan-service-shared)
- [Step 9: Health Monitoring and OTEL (Shared)](#step-9-health-monitoring-and-otel-shared)
- [Step 10: Shared Services Needing No Change](#step-10-shared-services-needing-no-change)
- [Secrets Summary](#secrets-summary)
- [Configuration Checklist](#configuration-checklist)
- [Review Notes](#review-notes)

---

## Overview

This guide lists **what a participant configures to add one more LOE** to an existing DPN. Read [01 — Overview](01-shared-dpn-architecture-overview.md) first for the architecture and the shared-versus-dedicated split.

The approach is the same for every component that is dedicated to an LOE:

1. Keep the existing (primary) values file **unchanged**.
2. Add a second values file for the new LOE (the **`-02` overlay**) that contains **only what differs** from the primary — instance name, identity, Vault address and credentials.
3. Deploy the new LOE as its **own Helm release**, layering the overlay on top of the primary file (`-f primary.yaml -f primary-02.yaml`). Everything not overridden is inherited from the primary, including image, registry, Key Vault, truststore and endpoints.

---

## Configuration Files Used

| Component | Primary values file | New LOE overlay (`-02`) | Helm release for the new LOE |
|-----------|--------------------|-----------------------|------------------------------|
| Vault | `charts/vault-https/values-<env>-<cluster>.yaml` | `charts/vault-https/values-<env>-<cluster>-02.yaml` | `vault-https-02` |
| Certificate Manager | `charts/certificate-manager/values-<env>-<cluster>.yaml` | `charts/certificate-manager/values-<env>-<cluster>-02.yaml` | `dpn-certificate-manager-02` |
| Federator server and client | `charts/dpn-platform/values-<env>-<cluster>.yaml` | `charts/dpn-platform/values-<env>-<cluster>-02.yaml` | `dpn-platform-02` |
| REST Federator server | `charts/dpn-rest-federator/values-<env>-<cluster>.yaml` | `charts/dpn-rest-federator/values-<env>-<cluster>-02.yaml` | `dpn-rest-federator-02` |
| REST Federator Redis | `charts/dpn-redis/values-<env>-<cluster>.yaml` | `charts/dpn-redis/values-<env>-<cluster>-02.yaml` | `dpn-redis-02` |
| Demo-runner client (optional test client) | `charts/dpn-demo-runner-client/values-<env>-<cluster>.yaml` | `charts/dpn-demo-runner-client/values-<env>-<cluster>-02.yaml` | its own release |

---

## Step 1: Agree the Naming Plan

Every object belonging to the new LOE must have a name that does **not** collide with the primary's. Agree this table with the central DPN team **before** creating any file. The suffix convention below is the one the shipped overlays use (`-02` for the second LOE).

| Item | Primary LOE | New LOE (instance 02) |
|------|-------------|-----------------------|
| Vault Deployment / Service / PVC | `dpn-vault-https` | `dpn-vault-02`, `dpn-vault-02-lb`, `dpn-vault-02-data` |
| Vault SecretProviderClass | `dpn-vault-https-kv-secrets` | `dpn-vault-02-kv-secrets` |
| Certificate Manager | `dpn-certificate-manager` | `dpn-certificate-manager-02` |
| Certificate Manager SecretProviderClass → Secret | `dpn-certificate-manager-kv-secrets` → `certificate-manager-secrets` | `dpn-certificate-manager-02-kv-secrets` → `certificate-manager-02-secrets` |
| Federator server / client | `dpn-federator-server-1` / `dpn-federator-client-1` | `dpn-federator-server-2` / `dpn-federator-client-2` |
| Federator common-config ConfigMaps | `federator-common-config-server` / `-client` | `<server name>-common-config` / `<client name>-common-config` |
| REST Federator server | `dpn-rest-federator-server-1` | `dpn-rest-federator-server-2` |
| REST Federator Redis | `dpn-rest-federator-redis-1` | `dpn-rest-federator-redis-2` |
| Key Vault: Vault root token | `VAULT-TOKEN` | `VAULT-TOKEN-02` |
| Key Vault: Certificate Manager AppRole secret-id | `VAULT-APPROLE-SECRET-ID` | `VAULT-APPROLE-SECRET-ID-02` |
| Deployment secure files (Vault bundle) | `bootstrap.key`, `certificate.pem`, `ca-chain.pem` | `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` |
| Certificate host names (SANs) | `producer…`, `consumer…` | `producer02…`, `consumer02…`, … (your LOE's own names) |

> **Do not reuse a primary name.** If a name is repeated, one release overwrites the other's Deployment, ConfigMap or Secret. The deployment pipelines refuse some collisions (for example they fail while a `<PLACEHOLDER-…>` is left in the `-02` file), but they cannot detect all of them.

---

## Step 2: Prepare the LOE Identity

The new LOE's identity is what separates and identifies it. Gather these **before** editing any values file:

| Item | Where it comes from | Used in |
|------|---------------------|---------|
| **DSM client ID** | The LOE's own client registered in the **same DSM** as the primary | Certificate Manager `oauth2.clientId`; federator server/client `idp.clientId`; REST federator `idp.clientId` |
| **Certificate subject** — `cn` and `altNames` | Your certificate request for the LOE | Certificate Manager `cert.subject.cn` / `cert.subject.altNames` |
| **Vault bundle** — private key, certificate, CA chain | Issued for the LOE | Uploaded as `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` and loaded into the new Vault |
| **AppRole `roleId`** | Printed by the Vault AppRole setup run for the **new** Vault (Step 3). Not known in advance | Certificate Manager `vault.appRole.roleId`; federator and REST federator `vaultConfig`/`vault.appRole.roleId` |

> The overlay files ship with `<PLACEHOLDER-…>` markers (for example `<PLACEHOLDER-VAULT-02-APPROLE-ROLE-ID>`). The certificate manager deployment **fails while any placeholder remains**, so the `roleId` is filled in after the AppRole run in Step 3 and before the certificate manager is deployed.

---

## Step 3: Vault for the New LOE

The new LOE gets its own **Vault service** with its own persistent storage. It is a separate Vault, not a second path in the primary one.

---

## Step 4: Certificate Manager for the New LOE

Each LOE has its **own** Certificate Manager, which uses that LOE's Vault, AppRole and DSM client.

---

## Step 5: Federator Server and Client for the New LOE

The new LOE gets its **own gRPC federator server and client**, with different service names. They **share** the primary's Kafka source and target, ZooKeeper, Kafka UI and Redis.

---

## Step 6: REST Federator for the New LOE

The REST federator follows the same pattern, with one difference: **each REST federator instance has its own Redis** (unlike the gRPC federator, which shares one).

Notes:

- The secondary REST federator is its own release (`dpn-rest-federator-02`), built from a copy of the chart containing only the server Deployment, Service, load balancer Service and ConfigMap.

---

## Step 7: Data Products for the New LOE

(No DevOps change.) The data pipelines are **shared**. Each LOE uses its **own data products**; no pipeline or chart change is needed.

For each LOE, create its data products through the shared self-service UI, using a naming convention agreed in Step 1 so products, containers and topics are attributable to the LOE.

---

## Step 8: File Scan Service (Shared)

One File Scan Service serves every LOE. No new deployment is needed.

---

## Step 9: Health Monitoring and OTEL (Shared)

One health monitoring stack and one OTEL Collector serve every LOE. The services of the new LOE report to the **same collector endpoint** as the primary's.

---

## Step 10: Shared Services Needing No Change

These are used as they are. Do not duplicate them for the new LOE.

| Service | Why no change is needed |
|---------|-------------------------|
| **Authentication Service (Keycloak)** | One realm and client serve all LOEs |
| **Kafka source/target, ZooKeeper, Kafka UI, federator Redis** | Shared by both LOEs' gRPC federators |
| **TLS (`dpn-tls`, `tls-auth-secret`)** | The wildcard SAN already covers the `-02` service names |
| **Storage accounts / blob containers** | One set, shared across federators, data pipelines and file scan |
| **GHCR image access** | Same `ghcr-pull-secret`; the overlays inherit the image repository and tag |

---

## Secrets Summary

| Secret / credential | Azure (Key Vault / Kubernetes) | Owner | Created by |
|---------------------|-------------------------------|-------|------------|
| New Vault root token | Key Vault `VAULT-TOKEN-02` | LOE | Vault deployment (`sharedDPN`) |
| Certificate Manager AppRole secret-id | Key Vault `VAULT-APPROLE-SECRET-ID-02` → Secret `certificate-manager-02-secrets` (key `VAULT_APPROLE_SECRET_ID`) | LOE | Vault AppRole setup (`sharedDPN`) |
| Vault bundle | Secure files `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` | LOE | Uploaded manually |
| DSM client credentials / keystore for the LOE | As for the primary, for the LOE's client | LOE | LOE registration |
| Shared: `dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, `ghcr-pull-secret` | Existing, unchanged | Central | Platform deployment |

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | Not yet reviewed | Draft | V0.1.0 |
