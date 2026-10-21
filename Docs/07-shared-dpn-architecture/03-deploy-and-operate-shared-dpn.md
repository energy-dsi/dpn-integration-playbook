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

This guide covers deploying the LOE stack configured in [02 — Configure a Shared DPN](02-configure-shared-dpn.md), checking it, and running it afterwards. [01 — Overview](01-shared-dpn-architecture-overview.md) explains the architecture and who is responsible for what.

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
| 8 | *(Optional)* Run the second demo-runner client | Smoke test through the new LOE's REST federator | `demo-runner-cd` |
| 9 | **Update the health portal** | Tiles and allow-list for the new components | Health monitoring portal deployment |
| 10 | **Create the LOE's data products** | Through the shared self-service | *(self-service UI)* |

---

## Deploying with Azure DevOps (`sharedDPN`)

Use the `release-internal/*-shared-dpn` versions of the pipelines. Run each in the same environment and cluster (`environment`, `dpnCluster`) as the primary.

### Vault, bundle and AppRole (steps 1–3)

| Pipeline | Key parameter | What `sharedDPN=true` does |
|----------|---------------|----------------------------|
| `vault-https-cd` | `sharedDPN: true` | Releases `vault-https-02` / `dpn-vault-02` next to the primary, layering `values-<env>-<cluster>-02.yaml`. Never touches the primary release. Stores the root token as `VAULT-TOKEN-02`. Cannot be combined with `testMode` |
| `vault-load-bundle-cd` | `sharedDPN: true` | Targets pod `app=dpn-vault-02`, reads `VAULT-TOKEN-02`, and loads the bundle from `vault-02.key`, `certificate-02.pem`, `ca-chain-02.pem` |
| `vault-approle-setup-cd` | `sharedDPN: true` | Targets `dpn-vault-02`, stores the new secret-id as `VAULT-APPROLE-SECRET-ID-02`, and prints the **`role_id`** — copy it into the `-02` overlays |

### Certificate Manager (step 5)

Run `certificate-manager-cd` with `sharedDPN: true`. Pre-flight checks stop the run with one clear message if:

- the `-02` values file still contains a `<PLACEHOLDER-…>` (fill in the `roleId`, client ID and certificate subject first);
- Service `dpn-vault-02` does not exist (run step 1);
- Key Vault secret `VAULT-APPROLE-SECRET-ID-02` does not exist (run step 3).

It deploys release `dpn-certificate-manager-02`. The primary release is not touched.

### Federator and REST Federator (steps 6–7)

These pipelines have **no `sharedDPN` switch**. A second instance is deployed **automatically, after the primary, whenever a `values-<env>-<cluster>-02.yaml` file exists** for that environment and cluster:

- **Federator gateway (`azure-dpn-cd`):** after the primary `dpn-platform` release, a task deploys `dpn-platform-02` from a copy of the chart that keeps only the federator server/client templates. It creates `<name>-common-config` ConfigMaps for the second instance and waits for both Deployments to roll out.
- **REST federator (`rest-federator-cd`):** after the primary, it deploys `dpn-redis-02` (its own Redis) and then `dpn-rest-federator-02`.

> **Important — both LOEs are redeployed in one run, at one image tag.**
> - The secondary release is deployed with the **same `imageTag` parameter** as the primary. Enter the tag the primary already runs unless you intend to upgrade both.
> - Each run re-applies the primary release (a no-op if values and tag are unchanged). Run these pipelines with the approval gate and in a maintenance window.
> - To run the new LOE at a different version, use Helm directly on the `-02` release (see [Day-2 Operations](#day-2-operations)).

### Scope of the automation

- Overlays and `sharedDPN` support are provided for the **`dpn01` cluster** of **`pdev`, `ptest` and `puat`** (the Vault pipeline's guard states that these environments have only one DPN).
- Only **one additional LOE (`-02`)** is automated. See [Adding a Further LOE](#adding-a-further-loe).

---

## Deploying with GitHub Actions (azure-gha-beta and aws-gha-beta) Today

The GitHub Actions workflows on `develop` (`dpn-gha-vault-https-cd.yaml`, `dpn-gha-certificate-manager-cd.yaml`, `dpn-gha-federator-gateway-cd.yaml`, `dpn-gha-rest-federator-cd.yaml`, and their role-id workflows) have **no shared-DPN input**: each is fixed to one release name and one values file `charts/<chart>/values/<cloud>/<env>-<cluster>.yaml`. Running them again targets the primary only.

Until they are extended, deploy the `-02` releases with Helm from a workstation or an admin VM that has cluster access, using the same overlay approach as the Azure DevOps pipelines. Place each overlay beside the primary file as `<env>-<cluster>-02.yaml`.

> The commands below are derived from the Azure DevOps pipelines on the shared branches. They have **not** been run against the GitHub Actions layout; check paths and image settings (`image.repository` is `ghcr.io/energy-dsi/...` on the GitHub Actions setups) and run `--dry-run` first.

**Vault `-02`:**

```bash
helm upgrade --install vault-https-02 charts/vault-https -n ns-dpn-01 \
  -f charts/vault-https/values/<cloud>/<env>-<cluster>.yaml \
  -f charts/vault-https/values/<cloud>/<env>-<cluster>-02.yaml \
  --set image.tag=<vaultImageTag> --wait --timeout 5m
```

Then initialise it, load the bundle and create the AppRole against pod `app=dpn-vault-02` with the same scripts the primary uses (`vault/…`), storing the **new** root token and secret-id under the `-02` credential names, never the primary's. Record the printed `role_id` in the overlays.

**Certificate Manager `-02`:**

```bash
helm upgrade --install dpn-certificate-manager-02 charts/certificate-manager -n ns-dpn-01 \
  -f charts/certificate-manager/values/<cloud>/<env>-<cluster>.yaml \
  -f charts/certificate-manager/values/<cloud>/<env>-<cluster>-02.yaml \
  --set image.tag=<imageTag> --wait --timeout 5m
```

**Federator server/client `-02`** (a copy of the chart that keeps only the federator templates, as the pipeline does):

```bash
CHART=charts/dpn-platform
SECOND=$(mktemp -d)/dpn-platform-second
cp -r "$CHART" "$SECOND"
find "$SECOND/templates" -maxdepth 1 -type f \
  ! -name '_helpers.tpl' \
  ! -name 'federator-server-deployment.yaml' ! -name 'federator-server-service.yaml' \
  ! -name 'federator-server-lb-service.yaml' ! -name 'federator-client-deployment.yaml' \
  ! -name 'federator-client-service.yaml' \
  ! -name 'federator-common-config-server.yaml' ! -name 'federator-common-config-client.yaml' \
  -delete

helm upgrade --install dpn-platform-02 "$SECOND" -n ns-dpn-01 \
  -f "$CHART/values/<cloud>/<env>-<cluster>.yaml" \
  -f "$CHART/values/<cloud>/<env>-<cluster>-02.yaml" \
  --set federatorServer.image.tag=<imageTag> --set federatorClient.image.tag=<imageTag> \
  --set federatorServer.commonConfigName=dpn-federator-server-2-common-config \
  --set federatorClient.commonConfigName=dpn-federator-client-2-common-config
```

(The Azure DevOps pipeline also passes `--set vaultConfig.truststorePassword=…` from the shared truststore secret; do the same, sourcing it from your secrets backend.)

**REST Federator `-02`:** deploy `dpn-redis-02` from the Redis chart with its `-02` overlay, then install the REST federator from a chart copy that keeps only `rest-federator-server-deployment.yaml`, `rest-federator-server-service.yaml`, `rest-federator-server-lb-service.yaml` and `rest-federator-server-config.yaml`, as release `dpn-rest-federator-02` with the `-02` overlay layered on the primary file.

### Minimal workflow change to automate this

The smallest change that gives the GitHub Actions workflows the Azure DevOps behaviour is, for each of the four CD workflows, a boolean input (for example `sharedDPN`) that:

1. switches `RELEASE_NAME` to the `-02` release (`vault-https-02`, `dpn-certificate-manager-02`);
2. adds `-f …/<env>-<cluster>-02.yaml` after the primary values file;
3. switches the Vault, token and AppRole credential names to the `-02` entries;
4. for the federator and REST federator, adds the second-release step (trimmed chart copy, separate release), conditional on the `-02` file existing.

This is the "minimal DevOps change to keep service names separate" for the certificate managers, and it is only needed for the Vault, certificate manager, federator and REST federator. The data pipelines, file scan and health monitoring need no pipeline change.

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

### 6. Business-level checks (acceptance criteria)

| Criterion | Check |
|-----------|-------|
| **AC1 — identification and attribution** | Publish a test data product as the new LOE. In DSM, the activity is recorded against the new LOE's **client ID**. In Jaeger/OpenSearch, traces and logs appear under the `-02` service names. The primary LOE's activity is recorded under its own client ID |
| **AC2 — shared DPN, LOE separation** | Both LOEs publish and consume through this one cluster. Each LOE's certificate and Vault are its own; one LOE cannot read the other's Vault |
| **AC3 — independence** | Restart `dpn-certificate-manager-02` or roll back `dpn-platform-02` while the primary LOE keeps exchanging data; the primary is unaffected |
| **Portal** | The DPN Portal shows `GRPC Gateway Client 2` and `Certification Vault Service 2`, and both open |

---

## Day-2 Operations

| Task | Who | How |
|------|-----|-----|
| **Upgrade a dedicated component of one LOE** (Vault, certificate manager) | LOE team | Re-run the pipeline with `sharedDPN=true` and the new image tag, or `helm upgrade` the `-02` release. The other LOE is not touched |
| **Upgrade the federator / REST federator** | LOE team, with central approval | Through the CD pipeline both LOEs move together at one tag. To upgrade only the new LOE, `helm upgrade dpn-platform-02 …` (trimmed chart, as in the table above) with the new `--set …image.tag=` |
| **Upgrade a shared component** (Kafka, Redis, Keycloak, OTEL, File Scan, Data Pipelines, Health Monitoring) | Central team | Plan in a maintenance window and tell every LOE; this affects all LOEs |
| **Rotate the Certificate Manager AppRole secret-id** | LOE team | Re-run `vault-approle-setup-cd` with `sharedDPN=true` (updates `VAULT-APPROLE-SECRET-ID-02`), then restart `dpn-certificate-manager-02` and the `-02` federators that read `certificate-manager-02-secrets` |
| **Rotate shared TLS (`dpn-tls`, `tls-auth-secret`)** | Central team | Re-run the TLS pipeline, then restart all pods that mount it, **for every LOE** |
| **Monitor** | Central team; LOE team views its components | One health monitoring stack. Filter by the `-02` service names for the new LOE |
| **Certificate renewal** | LOE team | The LOE's certificate manager renews against DSM on its own schedule, with its own client ID |
| **Capacity** | Central team | Shared Kafka, Redis, storage and the cluster serve all LOEs. Review capacity when an LOE is added |

---

## Rollback

| What to roll back | Procedure | Effect on other LOEs |
|-------------------|-----------|----------------------|
| Federator server/client of the new LOE | `helm history dpn-platform-02 -n ns-dpn-01` then `helm rollback dpn-platform-02 <revision> -n ns-dpn-01 --wait` | None |
| REST federator of the new LOE | `helm rollback dpn-rest-federator-02 <revision> -n ns-dpn-01 --wait` | None |
| Certificate manager of the new LOE | `helm rollback dpn-certificate-manager-02 <revision> -n ns-dpn-01 --wait` | None |
| Vault of the new LOE | `helm rollback vault-https-02 <revision> -n ns-dpn-01 --wait`. Vault data lives on its own PVC (`dpn-vault-02-data`) and is not changed by a chart rollback | None |
| A **shared** component | Use the component's own rollback procedure | **All LOEs** — coordinate centrally |

> The rollback and uninstall pipelines on the shared branches have **no shared-DPN changes**: they act on the primary releases. Roll back the `-02` releases with Helm as above and confirm what a pipeline would target before running it.

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

## Adding a Further LOE

The shipped automation supports **one additional LOE (`-02`)**. For a third LOE (`-03`), the same pattern applies — repeat [02 — Configure](02-configure-shared-dpn.md) with the suffix `-03` — but the pipelines need extending, because the suffix and names are fixed to `-02` in:

- the `sharedDPN` switch of the Vault, bundle, AppRole and certificate manager pipelines (`dpn-vault-02`, `VAULT-TOKEN-02`, `VAULT-APPROLE-SECRET-ID-02`, `vault-02.key` …);
- the second-release tasks in the federator and REST federator pipelines (`dpn-platform-02`, `-02` values file).

Make the suffix a parameter rather than copying the pipelines. Agree capacity and naming with the central team first.

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| `certificate-manager-cd` fails with "values file still contains `<PLACEHOLDER-…>`" | The `-02` overlay still has the sample `roleId`, client ID or certificate subject | Replace the listed values and re-run |
| "Service `dpn-vault-02` not found" | Step 1 not run for this environment/cluster | Run `vault-https-cd` with `sharedDPN=true` |
| "`VAULT-APPROLE-SECRET-ID-02` not found in Key Vault" | AppRole setup not run for the new Vault | Run `vault-approle-setup-cd` with `sharedDPN=true`, then re-run |
| Second Vault stays sealed or fails to start | Unseal key or managed identity not inherited from the primary, or PVC not bound | Check that the primary values define `seal`/`keyvault` and that `dpn-vault-02-data` is bound |
| `helm` reports resources owned by another release (for example a `vault-https` Service) | `service.aliasEnabled` not set to `false` on the `-02` Vault overlay | Set it to `false` and redeploy |
| Second certificate manager reads the primary's credential | `keyvault.approleSecretName` / `tokenSecretName` or `existingSecret.name` not overridden | Set the `-02` names; confirm `certificate-manager-02-secrets` |
| Federator `-2` fails to authenticate to DSM | `idp.clientId` not the new LOE's, or the signing certificate does not match that client | Check the client ID, and that `vaultConfig.uri` points at `dpn-vault-02` with the matching `roleId` |
| Federator `-2` cannot read its Vault credential | `secretIdSecretName` not `certificate-manager-02-secrets`, or the secret is not yet synced | Check the secret exists; the certificate manager `-02` must be deployed first |
| ConfigMap or Service already exists / overwritten | Name collision with the primary | Re-check the [naming plan](02-configure-shared-dpn.md#step-1-agree-the-naming-plan); each instance must set its own `name` |
| Primary federator version changed after a new-LOE run | The pipeline re-applied the primary at the `imageTag` you entered | Re-deploy the primary at its previous tag; next time enter the tag the primary runs |
| Second LB gets no IP, or "IP already in use" | `loadBalancerIP` copied from the primary | Leave `""` for dynamic assignment, or set a free IP |
| REST federator `-2` cannot reach Redis | `redis.host` not pointing to `dpn-rest-federator-redis-2`, or `dpn-redis-02` not deployed | Deploy `dpn-redis-02` first and check the host |
| Portal tile for Vault 2 does not open | Allow-list uses `dpn-vault-https-2-lb` but the Service is `dpn-vault-02-lb` | Make the allow-list and tile both use `dpn-vault-02-lb` |
| Both LOEs' data lands in the same Kafka topic | Federator client `-2` copied the primary's `topicPrefix` / `targetTopic` | Give each LOE its own topic values |
| Traces cannot be told apart by LOE | Components of the new LOE report under the primary's OTEL service name | Set a distinct OTEL service name per LOE component |

---

## Known Limitations and Open Points

Confirm these with DSI before production use.

| # | Item |
|---|------|
| 1 | **Automation is Azure DevOps only.** No GitHub Actions or AWS shared-DPN workflow or overlay exists yet; use the manual Helm steps above and extend the workflows as described |
| 2 | **One extra LOE (`-02`) and `dpn01` of `pdev`/`ptest`/`puat`** are automated. More LOEs or other clusters need the pipelines extended |
| 3 | **Sample overlays contain DSI pre-production values** and, in places, placeholders (`<PLACEHOLDER-…>`, `<APP-ROLE-ID>`). They are templates, not deployable as-is |
| 4 | **Data product organisation name is platform-wide** (`DPN_ORG_NAME`). Per-LOE naming relies on a product naming convention unless DSI confirms a per-LOE self-service |
| 5 | **Federator client `-2` topics** are copied from the primary in the shipped overlays; set distinct topics if separation is required |
| 6 | **Shared Vault seal and TLS.** The second Vault reuses the primary's auto-unseal key, managed identity and TLS certificate; the shared Key Vault is therefore a central trust point |
| 7 | **Federator and REST federator versions move together** when deployed through the CD pipelines |
| 8 | **Portal allow-list** entry for Vault 2 uses a different host name from the Service/tile; correct it |
| 9 | **Rollback/uninstall pipelines** have no shared-DPN awareness; use Helm on the `-02` releases |
| 10 | **Attribution record.** The business-level record of an LOE's data sharing is held in DSM against its client ID; the DPN-side evidence is the per-LOE service names, certificates and telemetry |

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | Not yet reviewed | Draft | V0.1.0 |
