Release : 2.1.0 - Oct 2026

# Shared DPN Architecture — Overview

---

## Table of Contents

- [Purpose and Scope](#purpose-and-scope)
- [Status of the Shared DPN Implementation](#status-of-the-shared-dpn-implementation)
- [Reference Architecture](#reference-architecture)
- [What Is Shared and What Is Dedicated to Each LOE](#what-is-shared-and-what-is-dedicated-to-each-loe)
- [LOE Identification and Attribution](#loe-identification-and-attribution)
- [Prerequisites](#prerequisites)
- [Related Documents](#related-documents)
- [Review Notes](#review-notes)

---

## Purpose and Scope

A parent organisation can have several affiliated **Legal Operating Entities (LOEs)** that each need to publish and consume data on the DSI network. Deploying a complete DPN for each LOE multiplies infrastructure, deployment and operating effort. A **Shared DPN** lets those LOEs use **one DPN deployment (one Kubernetes cluster, one set of platform services)** while keeping each LOE separate where it matters: its identity, its certificates, its Vault, its federator and its data products.

This section of the playbook explains how to set that up. It is written for the DPN participant's platform and DevOps team.

| Document | What it covers |
|----------|----------------|
| **01 — Overview** *(this document)* | The architecture, what is shared versus dedicated, and how an LOE is identified |
| [02 — Configure a Shared DPN](02-configure-shared-dpn.md) | What a participant configures, component by component, to add a further LOE |
| [03 — Deploy and Operate a Shared DPN](03-deploy-and-operate-shared-dpn.md) | Deployment order, verification, day-2 operations, rollback, uninstall and troubleshooting |

The three business outcomes this design addresses:

| # | Outcome | How the Shared DPN delivers it |
|---|---------|--------------------------------|
| 1 | **LOE identification and attribution** — the DPN identifies the acting LOE, records activity against it and keeps an audit trail per LOE transaction | Each LOE has its own DSM client identity, its own Vault/AppRole, its own certificate subject and its own named federator and certificate manager. See [LOE Identification and Attribution](#loe-identification-and-attribution) |
| 2 | **Shared DPN support for multiple LOEs** — LOEs publish and consume through one DPN deployment, with participant separation, and no separate DPN per LOE | One cluster hosts the shared platform services plus one **LOE stack** (Vault, Certificate Manager, Federator, REST Federator) per LOE. See [What Is Shared and What Is Dedicated](#what-is-shared-and-what-is-dedicated-to-each-loe) |
| 3 | **Operational independence and central management** — maintenance for one LOE does not stop another; common components are managed once; responsibilities are clear | Each LOE stack is its own set of Helm releases, deployed, upgraded and rolled back independently. Shared components are managed centrally |

---

## Status of the Shared DPN Implementation

Read this before planning a deployment. 

| Component repository | Shared DPN changes |
|----------------------|--------------------|
| `dpn-federator-certificate-manager` | Second Vault (`dpn-vault-02`) and second Certificate Manager (`dpn-certificate-manager-02`) |
| `dpn-federator-gateway` | Second federator server and client (`dpn-federator-server-2` / `dpn-federator-client-2`) as their own Helm release |
| `dpn-rest-federator-gateway` | Second REST federator server, its own Redis, and a second demo-runner client |
| `dpn-health-monitoring-service` | Portal tiles for the second federator client and second Vault |
| `dpn-authentication-service`, `dpn-data-pipelines`, `dpn-file-scan-service` | No change — these are shared as they are |

---

## Reference Architecture

One cluster, one set of shared platform services, and one *LOE stack* per LOE. The diagram shows two LOEs (instance `-01` the existing DPN, instance `-02` the added LOE).

```text
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│  ONE DPN CLUSTER                                                                         │
│                                                                                          │
│  ┌── LOE 1 stack (existing DPN) ───────┐   ┌── LOE 2 stack (added, suffix -02) ───────┐   │
│  │ Vault            dpn-vault-https    │   │ Vault            dpn-vault-02            │   │
│  │ Cert Manager     dpn-certificate-   │   │ Cert Manager     dpn-certificate-        │   │
│  │                  manager            │   │                  manager-02              │   │
│  │ Federator        dpn-federator-     │   │ Federator        dpn-federator-          │   │
│  │ server / client  server-1 / client-1│   │ server / client  server-2 / client-2     │   │
│  │ REST Federator   dpn-rest-federator-│   │ REST Federator   dpn-rest-federator-     │   │
│  │ + its Redis      server-1, redis-1  │   │ + its Redis      server-2, redis-2       │   │
│  │ DSM client ID, certificate subject  │   │ DSM client ID, certificate subject       │   │
│  └──────────────────┬──────────────────┘   └───────────────────┬──────────────────────┘   │
│                     │      both stacks use the same shared services                       │
│  ┌──────────────────┴───────────────────────────────────────────┴──────────────────────┐  │
│  │ SHARED:  Keycloak (authentication) · Kafka source/target + ZooKeeper + Kafka UI ·   │  │
│  │ Federator Redis · dpn-tls / tls-auth-secret · Data Pipelines (self-service) ·       │  │
│  │ File Scan Service · OTEL Collector + Health Monitoring · Storage accounts · Key Vault│  │
│  └──────────────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────────────┘
                 │                                                   │
                 └──── same DSM / management node, one client per LOE ┘
```

Key design points:

- **One namespace for the LOE stacks.** All instances run in the same namespace (`ns-dpn-01`), kept apart by **name suffix** (`-02`), not by namespace. Every Kubernetes object an instance creates is named after it, so instances never overwrite each other.
- **Each LOE stack is its own Helm release** (for example `vault-https-02`, `dpn-certificate-manager-02`, `dpn-platform-02`, `dpn-rest-federator-02`). The existing (primary) releases are never touched when an LOE is added.
- **Shared services are not duplicated.** The Kafka brokers, Redis, Keycloak, storage, the OTEL Collector and the health monitoring service serve every LOE.

---

## What Is Shared and What Is Dedicated to Each LOE

| Component | Shared or dedicated | What this means in practice |
|-----------|--------------------|-----------------------------|
| **Kubernetes cluster and namespace** (`ns-dpn-01`) | Shared | One cluster. LOE stacks differ by name suffix |
| **Authentication Service (Keycloak)** | Shared | One realm and `dpn-service-client` for all LOEs. No change needed |
| **Kafka Source, Kafka Target, ZooKeeper, Kafka UI** | Shared | Both LOE federators use the same `dpn-kafka-src` / `dpn-kafka-target` |
| **Federator Redis** (`dpn-redis`) | Shared | Both LOE federator servers/clients use the same Redis |
| **TLS** (`dpn-tls`, `tls-auth-secret`) | Shared | The universal wildcard SAN `*.<namespace>.svc.cluster.local` already covers `dpn-vault-02…` and the other `-02` service names |
| **Storage accounts / blob containers** | Shared | One set of storage used across the federators, data pipelines and the file scan service |
| **File Scan Service** | Shared | One deployment scans files for all LOEs |
| **Data Pipelines (self-service)** | Shared | One self-service deployment. Each LOE creates its **own data products** |
| **OTEL Collector** | Shared | All federators and certificate managers send telemetry to the same collector endpoint |
| **Health Monitoring Service** | Shared | One monitoring stack for every federator, certificate manager and Vault |
| **Key Vault / secrets backend and managed identity** | Shared store, **separate entries** | Same Key Vault, but each LOE has its own credential entries (for example `VAULT-TOKEN-02`, `VAULT-APPROLE-SECRET-ID-02`) |
| **Vault** | **Dedicated** | One Vault service per LOE (`dpn-vault-02`), with its own storage (PVC), Services and load balancer. Reuses the primary's auto-unseal key, managed identity and TLS certificate |
| **Certificate Manager** | **Dedicated** | One per LOE (`dpn-certificate-manager-02`), talking to that LOE's own Vault with its own AppRole and DSM client |
| **Federator server and client (gRPC)** | **Dedicated** | One server and client per LOE (`dpn-federator-server-2`, `dpn-federator-client-2`) with their own service names, DSM client ID, Vault and AppRole |
| **REST Federator server (and demo-runner client)** | **Dedicated** | One per LOE (`dpn-rest-federator-server-2`). Unlike the gRPC federator, it also gets its **own Redis** (`dpn-rest-federator-redis-2`) |
| **LOE identity** (DSM client ID, certificate CN/SANs, AppRole) | **Dedicated** | The basis for LOE separation and attribution |

---

## LOE Identification and Attribution

The DPN identifies the acting LOE through identity that is **unique per LOE** at each layer. When an LOE publishes or consumes data, the request travels through that LOE's own federator, which authenticates with that LOE's own credentials.

| Layer | What identifies the LOE | Where it is configured |
|-------|------------------------|------------------------|
| **DSM (management node) client** | Each LOE has its own client ID registered in the same DSM. The federator authenticates to DSM with `private_key_jwt` signed with that LOE's key, so DSM sees a different caller per LOE | `idp.clientId` on the federator server/client and the REST federator; `oauth2.clientId` on the certificate manager |
| **Certificate** | Each LOE's certificate carries its own subject (`cn`) and host names (`altNames`), issued through its own certificate manager | `cert.subject.cn` and `cert.subject.altNames` on the certificate manager `-02` values |
| **Vault and AppRole** | Each LOE's keys and certificates live in its own Vault, accessed only through its own AppRole `roleId` / `secret-id` | `vault.uri`, `vault.appRole.roleId` (certificate manager); `vaultConfig.uri`, `vaultConfig.appRole` (federators) |
| **Service identity** | Each LOE's federator and certificate manager has its own Kubernetes service name, so logs and metrics are attributable by workload | `federatorServer.name`, `federatorClient.name`, `restFederatorServer.name`, `fullnameOverride` |
| **Telemetry** | Each certificate manager reports under its own OTEL service name (`dpn-certificate-manager-02`), so the health monitor shows it as its own component | `otel.env.OTEL_SERVICE_NAME` |
| **Data product** | Each data product is created by an LOE through the shared self-service and has its own name, storage containers and Kafka topics | Data product definition in the self-service UI |

---

## Prerequisites

Before adding an LOE to a shared DPN:

- A working **primary DPN** on the target cluster (Vault, Certificate Manager, Federator, Kafka, Redis, Keycloak, Data Pipelines, File Scan and Health Monitoring deployed as in the platform deployment guides).
- The new LOE **registered in the same DSM** (management node), with its **client ID** and the certificate it will use.
- The new LOE's **Vault bundle** (private key, certificate and CA chain) available as the deployment secure files/secrets (for example `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` on Azure DevOps).
- Spare **cluster capacity** for the additional pods and persistent volume (second Vault PVC).
- A free **internal IP** for each additional load balancer, or agreement to let the cloud assign one dynamically.
- The `release-internal/*-shared-dpn` versions of the component repositories (or a `develop` that has merged them) for the pipelines and chart changes in [Status of the Shared DPN Implementation](#status-of-the-shared-dpn-implementation).
- A **naming plan** agreed between the central team and each LOE team (see [02 — Configure, Step 1](02-configure-shared-dpn.md#step-1-agree-the-naming-plan)).

---

## Related Documents

- [02 — Configure a Shared DPN](02-configure-shared-dpn.md)
- [03 — Deploy and Operate a Shared DPN](03-deploy-and-operate-shared-dpn.md)
- [DPN Architecture](../04-dpn-architecture/)
- [DPN Application Deployment](../03-dpn-application-deployment/)

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | Not yet reviewed | Draft | V0.1.0 |
