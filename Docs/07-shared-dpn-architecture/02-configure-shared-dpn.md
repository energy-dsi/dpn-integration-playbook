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

> **Replace every sample value.** The overlay files in the `release-internal/*-shared-dpn` branches contain DSI pre-production values (client IDs, role IDs, certificate names, registry names, IPs). Use them only as a structure. Each `<…>` below is a value you supply.

> **Platform note.** The shipped overlays and automation are for **Azure** (AKS, Key Vault, Azure DevOps). On **AWS** the same rules apply — a separately named instance, its own credential entries in AWS Secrets Manager, and a values overlay — but no AWS overlay files exist yet. See [Secrets Summary](#secrets-summary).

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

The paths above are the Azure DevOps layout. The GitHub Actions workflows read `charts/<chart>/values/<cloud>/<env>-<cluster>.yaml`; if you deploy the new LOE through them, place the overlay beside the primary file as `<env>-<cluster>-02.yaml` (see [03 — Deploy and Operate](03-deploy-and-operate-shared-dpn.md#deploying-with-github-actions-azure-gha-beta-and-aws-gha-beta-today)).

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

Create `charts/vault-https/values-<env>-<cluster>-02.yaml`:

```yaml
# Layered ON TOP of values-<env>-<cluster>.yaml.
# Only the differences from the primary go here; seal (same Key Vault unseal key and
# managed identity), keyvault (same TLS cert/key), image and resources are inherited.

# Everything named from fullnameOverride becomes *-02 automatically:
#   Deployment/Pod/ConfigMap  dpn-vault-02
#   Service                   dpn-vault-02            (ClusterIP :8200)
#   LoadBalancer Service      dpn-vault-02-lb         (own internal IP)
#   PVC                       dpn-vault-02-data       (separate storage = separate Vault)
#   SecretProviderClass       dpn-vault-02-kv-secrets
fullnameOverride: "dpn-vault-02"

service:
  # The chart creates an alias Service called "vault-https" (the primary's in-cluster
  # address). It must NOT be created a second time by this release.
  aliasEnabled: false
```

| Parameter | Purpose | Notes |
|-----------|---------|-------|
| `fullnameOverride` | Names every Vault object for the new LOE | Must be unique in the namespace |
| `service.aliasEnabled` | Prevents a second `vault-https` alias Service | Always `false` for the new LOE |
| *(inherited)* `seal`, `keyvault`, `image`, resources | The new Vault reuses the primary's auto-unseal key, managed identity and TLS certificate/key | Restrict who can administer the shared Key Vault (see [01 — Overview](01-shared-dpn-architecture-overview.md#operational-independence-and-central-management)) |

The Vault TLS name `dpn-vault-02.<namespace>.svc.cluster.local` is already covered by the shared wildcard SAN, so no new certificate is needed for the Vault service itself.

**Vault credentials for the new LOE** (created by the deployment, stored as separate entries in the shared Key Vault — never the primary's):

| Credential | Name |
|------------|------|
| Root token for the new Vault | `VAULT-TOKEN-02` |
| Certificate Manager AppRole secret-id | `VAULT-APPROLE-SECRET-ID-02` |
| Vault bundle files (Azure DevOps secure files) | `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` |

---

## Step 4: Certificate Manager for the New LOE

Each LOE has its **own** Certificate Manager, which uses that LOE's Vault, AppRole and DSM client.

Create `charts/certificate-manager/values-<env>-<cluster>-02.yaml`:

```yaml
# Layered ON TOP of values-<env>-<cluster>.yaml. Image, Key Vault, truststore,
# DSM / Keycloak / OTEL endpoints are inherited.

fullnameOverride: "dpn-certificate-manager-02"

vault:
  uri: "https://dpn-vault-02.<namespace>.svc.cluster.local:8200"   # the NEW LOE's own Vault
  appRole:
    roleId: "<role id printed by the Vault AppRole setup run for dpn-vault-02>"

oauth2:
  clientId: "<the new LOE's DSM client ID>"

cert:
  subject:
    cn: "<certificate common name>"
    altNames: "<the new LOE's host names, comma separated>"

otel:
  env:
    OTEL_SERVICE_NAME: "dpn-certificate-manager-02"   # own name, so the health monitor shows it separately

# Credentials for ONE Vault — never share these with the primary.
#   SecretProviderClass  dpn-certificate-manager-02-kv-secrets   (derived from fullnameOverride)
#   syncs into K8s Secret certificate-manager-02-secrets
keyvault:
  approleSecretName: "VAULT-APPROLE-SECRET-ID-02"
  tokenSecretName: "VAULT-TOKEN-02"

existingSecret:
  name: "certificate-manager-02-secrets"
```

| Parameter | Purpose | Notes |
|-----------|---------|-------|
| `fullnameOverride` | Names the Deployment, labels, PVC and SecretProviderClass | Unique in the namespace |
| `vault.uri` | The new LOE's Vault service | `dpn-vault-02` |
| `vault.appRole.roleId` | AppRole role ID | From the AppRole setup run; the deployment fails while a placeholder remains |
| `oauth2.clientId` | DSM client ID for this LOE | Registered in the same DSM as the primary |
| `cert.subject.cn`, `cert.subject.altNames` | The LOE's certificate subject | LOE-specific host names |
| `otel.env.OTEL_SERVICE_NAME` | Telemetry service name | Distinct per LOE |
| `keyvault.approleSecretName`, `keyvault.tokenSecretName` | Which Key Vault objects this instance reads | Defaults are the primary's names (`VAULT-APPROLE-SECRET-ID`, `VAULT-TOKEN`); the overlay **must** override them |
| `existingSecret.name` | The Kubernetes Secret the credential syncs into | `certificate-manager-02-secrets`; the federators reference this by name (Step 5) |

The chart change that makes this possible (SecretProviderClass and secret named after the instance, configurable Key Vault object names) is part of the `release-internal/2.1.0-shared-dpn` certificate manager chart.

---

## Step 5: Federator Server and Client for the New LOE

The new LOE gets its **own gRPC federator server and client**, with different service names. They **share** the primary's Kafka source and target, ZooKeeper, Kafka UI and Redis.

Create `charts/dpn-platform/values-<env>-<cluster>-02.yaml` containing only `federatorServer`, `federatorClient` and `vaultConfig`:

```yaml
federatorServer:
  name: dpn-federator-server-2                 # unique service name
  service:
    internalLoadBalancer: true
    loadBalancerIP: ""                         # set a FREE internal IP to pin one; otherwise assigned dynamically
  config:
    management_node_base_url: https://<dsm management node>
    kafkaBootstrapServers: dpn-kafka-src.<namespace>.svc.cluster.local:9092   # SHARED Kafka source
    redisHost: dpn-redis                       # SHARED Redis
    redisPort: 6379
  idp:
    clientId: <the new LOE's DSM client ID>
    jwksUrl: https://<dsm auth>/realms/management-node/protocol/openid-connect/certs
    tokenUrl: https://<dsm auth>/realms/management-node/protocol/openid-connect/token
    authMode: "private_key_jwt"
    jwtKeyAlias: "federator"

federatorClient:
  name: dpn-federator-client-2                 # unique service name
  service:
    internalLoadBalancer: true
    loadBalancerIP: ""
  config:
    management_node_base_url: https://<dsm management node>
    kafkaBootstrapServers: dpn-kafka-target.<namespace>.svc.cluster.local:9092   # SHARED Kafka target
    redisHost: dpn-redis                       # SHARED Redis
    topicPrefix: <topic prefix for this LOE>   # see the note below
    targetTopic: <target topic for this LOE>   # see the note below
  idp:
    clientId: <the new LOE's DSM client ID>
    # jwksUrl, tokenUrl, authMode, jwtKeyAlias as above

# The new LOE's own Vault and AppRole (the same ones its certificate manager uses),
# so the private_key_jwt signing certificate matches idp.clientId above.
vaultConfig:
  uri: https://dpn-vault-02.<namespace>.svc.cluster.local:8200
  authMethod: approle
  appRole:
    roleId: "<the same role id as the certificate manager -02>"
    useSecretIdRef: true
    secretIdSecretName: certificate-manager-02-secrets   # synced from VAULT-APPROLE-SECRET-ID-02
```

| Parameter | Purpose | Notes |
|-----------|---------|-------|
| `federatorServer.name`, `federatorClient.name` | Service names for the new LOE | Must differ from `-1`. The pipeline requires both to be set and uses them to name the ConfigMaps (`<name>-common-config`) and to wait for the rollout |
| `…service.loadBalancerIP` | Internal load balancer IP | Blank by default so the primary's IP is never reused |
| `…config.kafkaBootstrapServers` | Shared Kafka | Use the fully qualified service name, same Kafka as the primary |
| `…config.redisHost` | Shared Redis | Same `dpn-redis` as the primary |
| `…idp.clientId` | The LOE's DSM identity | Required — this is what makes the federator act as the new LOE |
| `vaultConfig.uri`, `vaultConfig.appRole.roleId`, `secretIdSecretName` | The LOE's Vault and AppRole | Must be the same Vault/AppRole as `dpn-certificate-manager-02` |

> **Kafka topics.** The shipped `-02` overlays copy `topicPrefix` and `targetTopic` from the primary client. If both LOEs' clients write to the same target topic, their data is not separated at topic level. Agree a distinct `topicPrefix` / `targetTopic` for each LOE with the central team, and confirm the topics exist or are created, before go-live.

> **Telemetry names.** Give each LOE's federator and REST federator its own OTEL service name (where the chart exposes one) so traces and logs can be separated by LOE.

The pipeline deploys this as a **separate release (`dpn-platform-02`)** built from a copy of the chart that keeps only the federator server/client templates, so Kafka, ZooKeeper, Redis and the other shared objects are **not** redeployed or duplicated.

---

## Step 6: REST Federator for the New LOE

The REST federator follows the same pattern, with one difference: **each REST federator instance has its own Redis** (unlike the gRPC federator, which shares one).

**REST federator server** — `charts/dpn-rest-federator/values-<env>-<cluster>-02.yaml`:

```yaml
restFederatorServer:
  name: dpn-rest-federator-server-2
  service:
    internalLoadBalancer: true
    loadBalancerIP: ""
  backend:
    baseUrl: https://<the LOE's backend / demo-runner server>:8443
  redis:
    host: dpn-rest-federator-redis-2.<namespace>.svc.cluster.local   # the new LOE's OWN Redis
    prefix: federator-server-2
  managementNode:
    baseUrl: https://<dsm management node>
  idp:
    clientId: <the new LOE's DSM client ID>
    jwksUrl: https://<dsm auth>/.../certs
    tokenUrl: https://<dsm auth>/.../token
  vault:
    uri: https://dpn-vault-02.<namespace>.svc.cluster.local:8200
    authMethod: approle
    appRole:
      roleId: "<role id>"
      useSecretIdRef: true
      secretIdSecretName: certificate-manager-02-secrets
  otel:
    serviceName: "<distinct name, e.g. dpn-rest-federator-server-2>"
```

**REST federator Redis** — `charts/dpn-redis/values-<env>-<cluster>-02.yaml`:

```yaml
redisCache:
  enabled: true
  name: dpn-rest-federator-redis-2
```

| Parameter | Purpose | Notes |
|-----------|---------|-------|
| `restFederatorServer.name` | Service name | Unique; the pipeline requires it |
| `restFederatorServer.redis.host` / `prefix` | The instance's own Redis and key prefix | Point at `dpn-rest-federator-redis-2` |
| `restFederatorServer.idp.clientId` | The LOE's DSM identity | |
| `restFederatorServer.vault.*` | The LOE's Vault and AppRole | Same as the certificate manager `-02` |
| `restFederatorServer.otel.serviceName` | Telemetry name | The shipped overlay keeps the primary's name; set a distinct one |

Notes:

- The secondary REST federator is its own release (`dpn-rest-federator-02`), built from a copy of the chart containing only the server Deployment, Service, load balancer Service and ConfigMap.
- The REST federator **HPA is not duplicated** — it keeps targeting the primary Deployment.
- The optional **demo-runner client** has its own overlay and release; it is a test aid, not a production dependency.

---

## Step 7: Data Products for the New LOE

(No DevOps change.) The data pipelines are **shared**. Each LOE uses its **own data products**; no pipeline or chart change is needed.

For each LOE, create its data products through the shared self-service UI, using a naming convention agreed in Step 1 so products, containers and topics are attributable to the LOE:

| Item | Guidance |
|------|----------|
| **Data product name** | Include the LOE (for example `<loe>-<product>`), so products are distinguishable in the self-service and in Kafka UI |
| **Source and target storage containers** | Distinct per product. Containers are in the **shared** storage account. Names must not already exist |
| **Target Kafka topic** | Distinct per product. The platform only ever creates new topics; it will not attach to an existing one |
| **Organisation name** | Set once for the whole self-service (`DPN_ORG_NAME`) and applied to every product. See the note in [01 — Overview](01-shared-dpn-architecture-overview.md#loe-identification-and-attribution) |

> **Organisation name per LOE.** If each LOE's name must appear on its data products (and, for topic data products, in the message headers), the platform-wide `DPN_ORG_NAME` is not enough on its own. Rely on the product naming convention, or confirm with DSI whether a separate self-service instance per LOE is required.

The data pipelines keep using the shared Kafka and the shared `dpn-keycloak-secrets` / `dpn-tls` secrets, exactly as in the single-LOE deployment.

---

## Step 8: File Scan Service (Shared)

One File Scan Service serves every LOE. No new deployment is needed.

| Item | Action |
|------|--------|
| Source and destination storage (`sourceStorageAccount`, `sourceContainer`, `destStorageAccount`, `destContainer`) | Confirm the configured storage covers the containers that **every LOE's** data products write to and read from |
| Event subscription / scan results | Confirm uploads from the new LOE's containers are included in the same scan event flow |
| Ownership | Run by the central team. The LOE teams only supply files |

---

## Step 9: Health Monitoring and OTEL (Shared)

One health monitoring stack and one OTEL Collector serve every LOE. The services of the new LOE report to the **same collector endpoint** as the primary's.

| Item | Action |
|------|--------|
| OTEL endpoint | Keep the same collector endpoint on every `-02` component (the overlays inherit it from the primary). No new collector |
| Portal tiles | Add the new LOE's components to the DPN Portal config (`charts/dpn-portal/values-<cluster>.yaml`): `GRPC Gateway Client 2` → `https://dpn-federator-client-2-external.<namespace>.svc.cluster.local:8085/` and `Certification Vault Service 2` → `https://dpn-vault-02-lb.<namespace>.svc.cluster.local:8200` |
| Portal allow-list (`otherUiUrls`) | Add the same two URLs. **Check the Vault 2 entry:** the shipped list uses `dpn-vault-https-2-lb` while the actual Service and tile use `dpn-vault-02-lb`. Make both use `dpn-vault-02-lb`, or the allow-list will not match the real Service |
| Alerts and dashboards | Extend any per-component alert or dashboard that lists components by name so the `-02` services are covered |

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

**On AWS:** there are no shipped overlays, so apply the same rule yourself. Give the new LOE its own, separately named entries in AWS Secrets Manager (for example under a `…/certificate-manager-02/…` path next to the primary's `dpn/<environment>-<cluster>/certificate-manager/…`), point the new certificate manager and federators at them through their own `SecretProviderClass`/Secret names, and never reuse the primary's entries. Confirm the naming with DSI before deploying.

---

## Configuration Checklist

- [ ] Naming plan agreed (Step 1) and no name collides with the primary
- [ ] LOE registered in DSM; client ID, certificate subject and Vault bundle ready (Step 2)
- [ ] `vault-https` `-02` overlay created: `fullnameOverride: dpn-vault-02`, `service.aliasEnabled: false` (Step 3)
- [ ] `certificate-manager` `-02` overlay created, with no `<PLACEHOLDER-…>` left, distinct credential names and OTEL name (Step 4)
- [ ] `dpn-platform` `-02` overlay created: names, DSM client ID, shared Kafka/Redis, `dpn-vault-02` and `certificate-manager-02-secrets`, distinct topics agreed (Step 5)
- [ ] REST federator and its own Redis `-02` overlays created (Step 6)
- [ ] LOE data product naming convention agreed (Step 7)
- [ ] File scan storage covers the new LOE's containers (Step 8)
- [ ] Portal tiles and allow-list use `dpn-vault-02-lb` and `dpn-federator-client-2-external` (Step 9)
- [ ] All sample values from the DSI overlays replaced with the LOE's own

Next: [03 — Deploy and Operate a Shared DPN](03-deploy-and-operate-shared-dpn.md).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | Not yet reviewed | Draft | V0.1.0 |
