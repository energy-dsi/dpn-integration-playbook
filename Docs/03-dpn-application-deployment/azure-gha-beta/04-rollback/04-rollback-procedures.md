Release : 2.1.0 - Oct 2026

# DPN Rollback and Recovery Process

---

## Table of Contents

- [Overview](#overview)
- [Rollback Strategy](#rollback-strategy)
- [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component)
- [Pre-Rollback Checklist](#pre-rollback-checklist)
- [Rollback Sequence Across Components](#rollback-sequence-across-components)
- [Part 1 — DPN Data Pipeline Rollback](#part-1--dpn-data-pipeline-rollback)
  - [Strategy 1 — Redeploy a Previous Build via the Standard CD Workflow](#strategy-1--redeploy-a-previous-build-via-the-standard-cd-workflow)
  - [Strategy 2 — Helm Revision Rollback](#strategy-2--helm-revision-rollback)
  - [Which Strategy to Use](#which-strategy-to-use)
  - [Verification](#verification)
- [Part 2 — DPN Federator Gateway Rollback](#part-2--dpn-federator-gateway-rollback)
- [Part 3 — DPN Federator Certificate Manager Rollback](#part-3--dpn-federator-certificate-manager-rollback)
- [Part 4 — DPN File Scanning Service Rollback](#part-4--dpn-file-scanning-service-rollback)
- [Part 5 — DPN Health Monitoring Service Rollback](#part-5--dpn-health-monitoring-service-rollback)
- [Part 6 — DPN Authentication Service Rollback](#part-6--dpn-authentication-service-rollback)
- [Part 7 — DPN REST Federator Gateway Rollback](#part-7--dpn-rest-federator-gateway-rollback)
- [Kafka Topic Recovery](#kafka-topic-recovery)
- [Post-Rollback Verification (All Components)](#post-rollback-verification-all-components)
- [Disaster Recovery Considerations](#disaster-recovery-considerations)
- [Config and Installation Guide Cross-References](#config-and-installation-guide-cross-references)
- [Review Notes](#review-notes)

---

## Overview

This document describes rollback and recovery procedures across **all DPN components**: Vault, Federator Certificate Manager, Federator Gateway, Data Pipeline, File Scanning Service, Health Monitoring Service, Authentication Service (Keycloak) and REST Federator Gateway.

Each component repository has one CD workflow per component under `.github/workflows/` (or, for Health Monitoring, one orchestrator that chains the sub-component workflows), and that same workflow is what you re-run to roll forward or back. Each component repository also has its own dedicated Helm-revision rollback workflow (listed in [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component)); all of them accept `cloud: azure`. This document generalises a two-mode approach (Helm revision vs. image tag) to every component via a mix of re-running the standard CD workflow, the rollback workflows, and manual `helm rollback`/`helm upgrade` commands.

All rollback operations here work at the **Helm release / container image** layer. Every rollback pipeline reduces to the same two modes, regardless of component — see [Rollback Strategy](#rollback-strategy).

Because several DPN components depend on one another at runtime (certificates, message flow, shared storage), rolling back more than one component at a time is not order-independent — see [Rollback Sequence Across Components](#rollback-sequence-across-components) before acting on more than one Part below.

---

## Rollback Strategy

There are **two separate mechanisms**, not two modes of one workflow — this is the key distinction to get right:

| | Mechanism used | What you provide | What it does |
|---|------------------|----------------------|-------------------|
| **Strategy 1 — Image tag rollback** | The **same, standard CD workflow** used for every normal deployment (`Actions → Run workflow`) | A previous **image tag** | Runs exactly like any other deployment — a fresh `helm upgrade --install` — except pointed at an older, already-built image instead of the latest one |
| **Strategy 2 — Helm revision rollback** | The component's rollback workflow (see [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component)), or a manual `helm rollback` command | A **Helm revision number** | Runs `helm rollback <release> <revision>`, reverting the release — chart *and* values — to exactly how it was at that revision |

The distinction matters for what actually gets reverted:

- **Strategy 1** The standard CD workflow deploys whatever the environment/cluster values file currently defines, just with an older `imageTag` substituted in. If the *values* are also wrong (not just the image), Strategy 1 alone won't fix that — it'll faithfully redeploy the bad values with an old image.

- **Strategy 2 reverts everything about that revision** — chart version, values, and therefore whatever image tag was in use at that revision too. It doesn't let you pick an image tag independently of the revision; you get exactly what that revision was.

**On image tags:** components pull from GHCR (`ghcr.io/energy-dsi/...`) by default, so `imageTag` is typically a semantic version or a DSI-provided stable tag rather than a numeric build ID — check your registry's tag history (GHCR package page, or `az acr repository show-tags` if you push to your own Azure Container Registry) for what's actually available before choosing one to roll back to.

---

## Rollback Workflow Availability by Component

| Component | Standard CD workflow (Strategy 1) | Dedicated rollback workflow (Strategy 2) | 
|-----------|--------------------------------------|-----------------------------------------------|
| DPN Data Pipeline | `dpn-gha-data-pipelines-cd.yaml` | **DPN Rollback - Self-Service Data Pipelines** (`dpn-gha-self-service-rollback.yaml`) for `dpn-self-service`, `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` in `ns-dpn-dp-01`; **DPN Rollback - Data Pipelines** (`dpn-gha-data-pipelines-rollback.yaml`) for any other release, by name, in `ns-dpn-01` — [Part 1](#part-1--dpn-data-pipeline-rollback) |
| DPN Federator Gateway | `dpn-gha-federator-gateway-cd.yaml` | **DPN Rollback - Federator Gateway** (`dpn-gha-federator-gateway-rollback.yaml`) for `dpn-platform` — [Part 2](#part-2--dpn-federator-gateway-rollback) |
| DPN Federator Certificate Manager | `dpn-gha-certificate-manager-cd.yaml` (and `dpn-gha-vault-https-cd.yaml` for Vault) | **DPN Rollback - Certificate Manager** (`dpn-gha-certificate-manager-rollback.yaml`) for `dpn-certificate-manager` and `vault-https`; manual `helm rollback` only for the legacy `vault` release — [Part 3](#part-3--dpn-federator-certificate-manager-rollback) |
| DPN File Scanning Service | `dpn-gha-file-scan-cd.yaml` | **DPN Rollback - File Scan Service** (`dpn-gha-file-scan-rollback.yaml`) for `dpn-file-scan-service` — [Part 4](#part-4--dpn-file-scanning-service-rollback) |
| DPN Health Monitoring Service | `dpn-gha-health-monitoring-cd-install.yaml` (orchestrator — the 10 per-component workflows are `workflow_call`-only and can't be triggered standalone) | **DPN Rollback - Health Monitoring** (`dpn-gha-rollback-health-monitoring.yaml`) for every sub-component release in `ns-dpn-health-01` — [Part 5](#part-5--dpn-health-monitoring-service-rollback) |
| DPN Authentication Service | `dpn-gha-keycloak-cd.yaml` | **DPN Rollback - Keycloak** (`dpn-gha-keycloak-rollback.yaml`) for `dpn-keycloak` — [Part 6](#part-6--dpn-authentication-service-rollback) |
| DPN REST Federator Gateway | `dpn-gha-rest-federator-cd.yaml` (and `dpn-gha-demo-runner-cd.yaml` for the Demo Runner) | **DPN Rollback - REST Federator Gateway** (`dpn-gha-rest-federator-rollback.yaml`) for `dpn-redis`, `dpn-rest-federator`, `dpn-demo-runner-server` or `dpn-demo-runner-client` — [Part 7](#part-7--dpn-rest-federator-gateway-rollback) |

Each workflow lives in its component's own repository under `.github/workflows/` and reads its settings from `.github/config/azure/<environment>-<cluster>.json` in that repository.

Apart from the Self-Service workflow (described in [Part 1](#strategy-2--helm-revision-rollback)), the rollback workflows share the same shape. Each is started from **Actions → <display name> → Run workflow** and takes:

| Input | Values |
|-------|--------|
| `environment` | `dev` / `test` (default `dev`) |
| `cluster` | `dpn01` / `dpn02` (default `dpn01`) |
| `cloud` | `azure` / `aws`. **The default is `aws` on every one of these workflows except DPN Rollback - Health Monitoring (default `azure`) — select `azure`.** |
| `releaseName` | Only on the workflows that cover more than one release — see each Part |
| `targetRevision` | `0` (default) = the previous stable revision, or a revision number from `helm history <release>`; must be a non-negative integer |
| `confirm` | The release name (or the selected `releaseName` value) retyped exactly — see each Part |

Each job runs on the self-hosted runner (`[self-hosted, vmss]`) under the GitHub Environment `<environment>-<cluster>`, so any required reviewers on that environment act as the approval gate. It checks the `confirm` text and the revision format, loads `.github/config/azure/<environment>-<cluster>.json`, signs in to Azure with the `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` repository secrets and gets the AKS context through the `cloud-login` composite action, then works in the `NAMESPACE` from that file (`ns-dpn-01`; Health Monitoring always uses `ns-dpn-health-01`). For each release it shows `helm history`, resolves `0` to the previous revision whose status is `deployed` or `superseded`, refuses a target revision with any other status, runs `helm rollback --dry-run` and then `helm rollback <release> <revision> -n <namespace> --wait` (timeout `15m`; `10m` for DPN Rollback - Data Pipelines), and finishes with a verification step that lists the pods and release status. None of them change Azure Key Vault secrets.

---

## Pre-Rollback Checklist

Before initiating any rollback:

1. Confirm the CI/CD pipeline currently running (if any) has stopped or completed — don't roll back into an in-progress deployment.
2. Decide which strategy applies: is the problem a bad **image build** (use Strategy 1) or a bad **configuration/values change** (use Strategy 2)? Using the wrong one either won't fix the actual problem or will revert more than intended.
3. For Strategy 1: identify the last known-good image tag/build number. For Strategy 2: identify the last known-good Helm revision number.
4. For the Data Pipeline specifically: confirm no active file ingestion is mid-flight, and that Kafka topics for the affected product are not actively being written to, where practical.
5. For Vault/Certificate Manager rollbacks: confirm you have a secure, offline copy of the certificate bundle before touching Vault contents.
6. Notify anyone actively using the affected component's dashboards/endpoints, especially for Health Monitoring Service, since a rollback there briefly interrupts telemetry collection platform-wide.
7. If more than one component needs to be rolled back, read [Rollback Sequence Across Components](#rollback-sequence-across-components) first and plan the order before starting any individual Part below.

---

## Rollback Sequence Across Components

**If only one component is broken, there is no sequence to worry about** — follow the relevant Part (1–7) on its own. A sequence only matters when a bad release touched more than one component at once, or when rolling back one component could invalidate what a dependent component is currently using.

The runtime dependency chain across DPN components is:

```
Vault
  └─→ Federator Certificate Manager (persists certs to Vault)
        └─→ Federator Gateway (uses issued certs for mTLS)
              └─→ Data Pipeline (hands off data via Federator Gateway)
                    └─→ File Scanning Service (writes into Data Pipeline's dp-consumer-stage container)

Health Monitoring Service — independent of the chain above; every other component sends telemetry to it, but nothing above depends on it to function
```

When multiple components need rolling back together, work **down the chain, from Vault outward**, for the same reason you'd deploy in that order: a downstream component's current config assumes the upstream one is in a known-good state.

1. **Vault** — only if the certificate bundle itself is suspect (not just the Certificate Manager's code). Restore from a secure offline copy per [Disaster Recovery Considerations](#disaster-recovery-considerations) before touching anything downstream, since every other component's mTLS depends on Vault's contents being valid.
2. **Federator Certificate Manager** — roll back its deployment (Part 3) if the manager's own code is at fault. This does not affect Vault's stored certificates, so it's safe to do independently of step 1 unless the manager's rollback would reintroduce code that mismanages Vault contents.
3. **Federator Gateway** — roll back (Part 2) only after Vault/Certificate Manager are confirmed healthy; otherwise the Gateway may roll back into a config that expects certificates Vault no longer has in the expected state.
4. **Data Pipeline** — roll back (Part 1) once the Federator Gateway is confirmed healthy, since the Data Pipeline hands data off through it.
5. **File Scanning Service** — roll back (Part 4) last in the chain, since it depends on the Data Pipeline's `dp-consumer-stage` container already existing and being written to correctly.
6. **Health Monitoring Service** — roll back (Part 5) at any point relative to the above, but do it **after** the others if you still need its dashboards to confirm the other rollbacks succeeded. If Health Monitoring itself is the only thing broken, there's no ordering constraint with the rest of the chain at all.

The Authentication Service ([Part 6](#part-6--dpn-authentication-service-rollback)) and the REST Federator Gateway ([Part 7](#part-7--dpn-rest-federator-gateway-rollback)) are not shown in this chain; roll them back using their own Parts.

If you're rolling back the *whole platform* to a prior known-good state (e.g. after a bad multi-component release), apply this same order rather than rolling back whichever component's alert fired first — an out-of-order rollback (e.g. Data Pipeline before Federator Gateway) risks the component you just fixed immediately breaking again once its upstream dependency changes under it.

---

## Part 1 — DPN Data Pipeline Rollback

### Strategy 1 — Redeploy a Previous Build via the Standard CD Workflow

Go to **Actions → DPN CD - Data Pipelines → Run workflow** (`dpn-gha-data-pipelines-cd.yaml` in `dpn-data-pipelines`) — the same workflow used for every normal deployment, not a rollback-specific one.

| Input | Purpose | Values |
|-----------|---------|--------|
| `environment` | Target environment | `dev`, `test` (default `test`) |
| `cluster` | Target DPN cluster | `dpn01`, `dpn02` |
| `cloud` | Target cloud | `azure` (the default is `aws` — change it) |
| `configType` | Producer or consumer | `producer`, `consumer` |
| `processType` | Integration pathway | `file`, `topic` |
| `productType` | Product type name; part of the release name | free text, default `default` |
| `schemaType` | Schema type (part of the producer image name) | free text, default `default` |
| `imageTag` | **Image Tag To Deploy** — the tag to roll back to | free text, **no default — must be supplied every run** |
| `imageName` | Optional override of the computed image name | free text, default empty |

To roll back: trigger this workflow exactly as you would for a normal deployment, but set `imageTag` to a previous, known-good tag instead of the latest one. There is no separate "rollback mode" — the workflow always runs `helm upgrade --install` against whatever `imageTag` you give it, whether that's the newest build or an older one.

**Finding a previous tag:** check the GHCR package page for the image, or if pushing to your own Azure Container Registry:

```bash
az acr repository show-tags --name <acr-name> --repository <image-name> --orderby time_desc --output table
```

### Strategy 2 — Helm Revision Rollback

For the Self-Service releases in `ns-dpn-dp-01` (`dpn-self-service`, `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor`), run **DPN Rollback - Self-Service Data Pipelines** (`dpn-data-pipelines/.github/workflows/dpn-gha-self-service-rollback.yaml`) with:

| Input | Value |
|-------|-------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` (the default is `aws` — change it) |
| `release_name` | `dpn-self-service`, `dpn-consumer-file-extractor` or `dpn-consumer-topic-extractor` |
| `targetRevision` | Revision to roll back to; `0` (default) for the previous stable revision |
| `confirm` | The `release_name` value, retyped exactly |

The workflow waits for approval on the GitHub Environment `<environment>-<cluster>`, lists the last five revisions with the image each one runs, refuses a target revision whose status is not `deployed` or `superseded`, runs a `--dry-run` and then `helm rollback <release_name> <revision> -n ns-dpn-dp-01 --wait --timeout 10m`.

For releases deployed by `dpn-gha-data-pipelines-cd.yaml` in `ns-dpn-01`, run **DPN Rollback - Data Pipelines** (`dpn-data-pipelines/.github/workflows/dpn-gha-data-pipelines-rollback.yaml`) with:

| Input | Value |
|-------|-------|
| `environment` | `dev` / `test` (default `dev`) |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` (the default is `aws` — change it) |
| `releaseName` | Free text — the exact Helm release name from `helm list -n ns-dpn-01` (releases are created per product, so there is no fixed list) |
| `targetRevision` | Revision to roll back to; `0` (default) for the previous stable revision |
| `confirm` | The `releaseName` value, retyped exactly |

It fails if the release is not installed, then runs `helm rollback <releaseName> <revision> -n ns-dpn-01 --wait --timeout 10m` after the checks described in [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component), and shows `helm status` and the last revisions afterwards. Alternatively, run `helm rollback` directly.

`dpn-gha-data-pipelines-cd.yaml` names each release `dpn-<configType>-<processType>-<adaptor|extractor>-<productType>` (for example `dpn-producer-file-adaptor-default`). Releases left from earlier releases of the workflow may follow the older convention `{configType}-{processType}-{base_name}-{schemaType}` for producer and `{configType}-{processType}-{base_name}` for consumer, where a `schema_mapper` folder is remapped to `mapper` in the release name; use `helm list -n <namespace>` to find them.

```bash
helm rollback $RELEASE_NAME <rollbackRevision> -n $NAMESPACE
```

`helm rollback` will simply fail if the revision number doesn't exist. Check history first:

```bash
helm history <release-name> -n <namespace>
```

### Which Strategy to Use

| Situation | Use |
|-----------|-----|
| The image build is broken (bad code, bad dependency) but the Helm values/chart are fine | **Strategy 1** — redeploy an older build number |
| A values/config change was bad (wrong secret reference, wrong scheduling config, wrong resource limits) | **Strategy 2** — revert to a prior Helm revision |
| Both the image *and* the values changed and both are suspect | **Strategy 2** first (reverts both), then confirm the image at that revision is actually the one you want — use Strategy 1 afterward only if you need an even older image than what that revision had |

### Verification

```bash
kubectl get deployment $RELEASE_NAME -n <namespace> \
  -o=jsonpath='{.spec.template.spec.containers[0].image}'

kubectl rollout status deployment/$RELEASE_NAME -n <namespace> --timeout=180s
```

---

## Part 2 — DPN Federator Gateway Rollback

**Strategy 1 — standard CD workflow (`dpn-gha-federator-gateway-cd.yaml`):** re-run with an older `imageTag`. Since this workflow deploys the entire `dpn-platform` release together (Zookeeper Source/Target, Kafka Source/Target, Kafka UI, Redis, Federator Server, Federator Client), redeploying an old tag rebuilds the whole platform release at that image version, not just one sub-component.

If only one sub-component's image needs to change, target it directly instead of using the platform-wide workflow:

```bash
kubectl set image deployment/dpn-federator-server-1 \
  dpn-federator-server-1=<acr-url-or-ghcr>/dpn-federator-server:<imageTag> -n <namespace>
kubectl rollout status deployment/dpn-federator-server-1 -n <namespace>
```

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - Federator Gateway** (`dpn-federator-gateway/.github/workflows/dpn-gha-federator-gateway-rollback.yaml`) with `environment`, `cluster`, `cloud: azure` (the default is `aws` — change it), `targetRevision` (`0` = previous stable revision) and `confirm: dpn-platform`. It rolls back the `dpn-platform` release in `ns-dpn-01` as described in [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component). Its pre-rollback checklist warns that rolling back a Kafka/Zookeeper topology change can disrupt in-flight messages, so compare the revisions in `helm history dpn-platform` first; the Vault AppRole `role_id` and the federator client/server TLS material are not affected.

The manual equivalent is:

```bash
helm rollback dpn-platform <rollbackRevision> -n <namespace>
```

Either way, this reverts the entire combined release — every sub-component — to that revision at once. There's no partial Helm-revision rollback of just one sub-component within a shared release.

**Verification:**

```bash
kubectl get pods -n <namespace>
helm history dpn-platform -n <namespace>
```

---

## Part 3 — DPN Federator Certificate Manager Rollback

**Strategy 1 — standard CD workflow (`dpn-gha-certificate-manager-cd.yaml`):** re-run with an older `imageTag`.

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - Certificate Manager** (`dpn-federator-certificate-manager/.github/workflows/dpn-gha-certificate-manager-rollback.yaml`) with:

| Input | Value |
|-------|-------|
| `environment` | `dev` / `test` (default `dev`) |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` (the default is `aws` — change it) |
| `releaseName` | `certificate-manager` (release `dpn-certificate-manager`), `vault-https` (release `vault-https`), or `all` |
| `targetRevision` | `0` (default) = previous stable revision, or a revision number from `helm history`; with `all`, `0` is resolved separately for each release |
| `confirm` | The `releaseName` value, retyped exactly |

With `all` it rolls back `dpn-certificate-manager` first and then `vault-https` (the reverse of the install dependency order), and skips, rather than fails, a release that is not installed or has no earlier stable revision. The legacy plain-HTTP `vault` release (`dpn-gha-vault-cd.yaml`) is not covered — roll it back manually. Its pre-rollback checklist warns that rolling back `vault-https` can affect its TLS/unseal configuration and, if Vault was recently initialised, leave it inconsistent with Vault's own data; the Certificate Manager's Vault AppRole and policies are not affected.

The manual equivalent is:

```bash
helm rollback dpn-certificate-manager <rollbackRevision> -n <namespace>
```

**Neither strategy rolls back Vault's contents** — the certificate manager's deployment revision is independent of what's stored in Vault. If the problem is the *certificate bundle itself* rather than the certificate manager's code, see [Disaster Recovery Considerations](#disaster-recovery-considerations).

**Verification:**

```bash
kubectl get pods -n <namespace>
kubectl -n <namespace> exec <pod-name> -- ls /tls
```

---

## Part 4 — DPN File Scanning Service Rollback

Use the standard CD workflow for Strategy 1, and **DPN Rollback - File Scan Service** or manual Helm commands for Strategy 2, per [Rollback Strategy](#rollback-strategy) and [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component).

**Strategy 1 — re-run `dpn-gha-file-scan-cd.yaml` with an older `imageTag`:**

```bash
kubectl set image deployment/dpn-file-scan-service \
  dpn-file-scan-service=<acr-url-or-ghcr>/dpn-file-scan-service:<imageTag> -n <namespace>
kubectl rollout status deployment/dpn-file-scan-service -n <namespace>
```

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - File Scan Service** (`dpn-file-scan-service/.github/workflows/dpn-gha-file-scan-rollback.yaml`) with `environment`, `cluster`, `cloud: azure` (the default is `aws` — change it), `targetRevision` (`0` = previous stable revision) and `confirm: dpn-file-scan-service`. It rolls back the `dpn-file-scan-service` release in `ns-dpn-01` as described in [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component). The manual equivalent is:

```bash
helm history dpn-file-scan-service -n <namespace>
helm rollback dpn-file-scan-service <rollbackRevision> -n <namespace>
```

Because the File Scanning Service depends on the Data Pipeline's `dp-consumer-stage` container already existing (see [Rollback Sequence Across Components](#rollback-sequence-across-components)), confirm the Data Pipeline is healthy before or immediately after rolling this component back — rolling this back in isolation while the Data Pipeline is also broken will not resolve end-to-end file flow.

**Verification:**

```bash
kubectl get pods -n <namespace>
kubectl logs -f <dpn-file-scan-service-pod> -n <namespace>
```

Re-run the verification steps from the File Scanning Service's Installation Process (clean file lands in `dp-consumer-stage`; EICAR test file is blocked) to confirm scanning behaviour is intact post-rollback.

---

## Part 5 — DPN Health Monitoring Service Rollback

Every sub-component (Kafka, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, OTel Collector, DPN Portal) has its own CD workflow in `dpn-health-monitoring-service/.github/workflows/` (`dpn-gha-kafka-cd.yaml`, `dpn-gha-opensearch-cd.yaml`, etc.), but these are **`workflow_call`-only** — they can't be triggered standalone from the Actions tab, only invoked by the `dpn-gha-health-monitoring-cd-install.yaml` orchestrator.

> **Note:** `dpn-portal` — a tile landing page that links out to the observability UIs — has replaced the retired `nginx-observability` reverse proxy as the last component in this chain; it is fronted by its own `oauth2-proxy` gateway rather than acting as the reverse proxy itself. The `oauth2-proxy` gateways that used to front Kafka UI, Prometheus, and Thanos directly have also been retired: Kafka UI now uses native Keycloak OIDC login and is exposed on its own internal load balancer, and Prometheus/Thanos are no longer browsed directly (both are consumed through Perses).

**Strategy 1 — re-run the orchestrator:** go to **Actions → DPN Health Monitoring → Run workflow** (`dpn-gha-health-monitoring-cd-install.yaml`, `cloud: azure` — the default is `aws`). This redeploys the full dependency chain (Kafka → OpenSearch → Prometheus → Thanos, etc.) — the OTel Collector's `imageTag` is an input, and DPN Portal likewise requires its own `portalImageRepository`/`portalImageTag` inputs since that chart ships no default image; other sub-components don't take an image tag from the orchestrator today, so an image-tag rollback for those means Strategy 2 instead.

**Strategy 2 — Helm revision rollback for the affected sub-component:** run **DPN Rollback - Health Monitoring** (`dpn-health-monitoring-service/.github/workflows/dpn-gha-rollback-health-monitoring.yaml`) with:

| Input | Value |
|-------|-------|
| `environment` | `dev` / `test` (default `dev`) |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` (default) or `aws` |
| `releaseName` | `all`, `oauth2-portal`, `oauth2-perses`, `oauth2-jaeger`, `portal`, `otel`, `oauth2-osd`, `redis-ui`, `perses`, `thanos`, `jaeger`, `data-prepper`, `prometheus`, `opensearch` or `kafka` |
| `targetRevision` | `0` (default) = previous stable revision, or a revision number from `helm history`; with `all`, `0` is resolved separately for each release |
| `confirm` | The `releaseName` value, retyped exactly |

The workflow always works in `ns-dpn-health-01` and runs under the GitHub Environment `<environment>-<cluster>`, so any required reviewers on that environment act as the approval gate. For each selected release it shows the history, refuses a target revision whose status is not `deployed` or `superseded`, runs `helm rollback --dry-run` and then `helm rollback <release> <revision> --wait --timeout 15m`. With `all` it works in reverse deployment order (`oauth2-portal` → `oauth2-perses` → `oauth2-jaeger` → `portal` → `otel` → `oauth2-osd` → `redis-ui` → `perses` → `thanos` → `jaeger` → `data-prepper` → `prometheus` → `opensearch` → `kafka`) and skips, rather than fails, any component that is not installed or has no earlier stable revision.

The manual equivalent for any sub-component uses the release names set in each `dpn-gha-*-cd.yaml` workflow: `dpn-kafka-stack`, `dpn-opensearch`, `dpn-prometheus`, `dpn-thanos`, `dpn-data-prepper`, `dpn-jaeger`, `dpn-perses`, `dpn-otel-collector-health`, `dpn-portal`, `dpn-oauth2-proxy-osd`, `dpn-oauth2-proxy-jaeger`, `dpn-oauth2-proxy-perses`, `dpn-oauth2-proxy-portal` and `dpn-redis-ui-health`.

```bash
helm rollback <release-name> <rollbackRevision> -n ns-dpn-health-01
```

**Rollback order matters here**, mirroring the deployment dependency graph (`Init → Kafka → OpenSearch → Prometheus → Thanos → DataPrepper`/`Jaeger → Perses → OTel → DPN Portal`): if rolling back a component others depend on (e.g. Kafka), check whether dependent components also need attention afterward. This is a sequence *within* Health Monitoring Service specifically — separate from, and unaffected by, the cross-component sequence in [Rollback Sequence Across Components](#rollback-sequence-across-components).

**A rollback of the OTEL Collector specifically** interrupts telemetry collection platform-wide during the rollout — factor this into timing per the [Pre-Rollback Checklist](#pre-rollback-checklist).

**Verification:**

```bash
kubectl get pods -n ns-dpn-health-01
kubectl get hpa -n ns-dpn-health-01
```

Trigger a known event upstream and confirm it still reaches all three dashboards after the rollback.

---

## Part 6 — DPN Authentication Service Rollback

**Strategy 1 — standard CD workflow (`dpn-gha-keycloak-cd.yaml`, DPN CD - Keycloak):** re-run with an older `keycloakImageTag` (and/or `postgresImageTag`). Left blank, these inputs use the tag configured for the environment.

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - Keycloak** (`dpn-authentication-service/.github/workflows/dpn-gha-keycloak-rollback.yaml`) with `environment`, `cluster`, `cloud: azure` (the default is `aws` — change it), `targetRevision` (`0` = previous stable revision) and `confirm: dpn-keycloak`. It rolls back the `dpn-keycloak` release, which includes the bundled PostgreSQL sub-chart, in `ns-dpn-01` as described in [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component). The manual equivalent is:

```bash
helm history dpn-keycloak -n <namespace>
helm rollback dpn-keycloak <rollbackRevision> -n <namespace>
```

A rollback reverts the chart version, values and templated configuration only. It does **not** revert realm or client configuration written by `configure-keycloak.sh`, and the PostgreSQL PersistentVolumeClaim is not affected.

**Verification:**

```bash
kubectl get pods -n <namespace> -l app=dpn-keycloak
kubectl get pods -n <namespace> -l app=dpn-keycloak-postgres
```

---

## Part 7 — DPN REST Federator Gateway Rollback

**Strategy 1 — standard CD workflow (`dpn-gha-rest-federator-cd.yaml`):** re-run with an older `imageTag`. The Demo Runner releases are deployed by `dpn-gha-demo-runner-cd.yaml`, which also takes an `imageTag`.

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - REST Federator Gateway** (`dpn-rest-federator-gateway/.github/workflows/dpn-gha-rest-federator-rollback.yaml`) with:

| Input | Value |
|-------|-------|
| `environment` | `dev` / `test` (default `dev`) |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` (the default is `aws` — change it) |
| `releaseName` | `dpn-redis`, `dpn-rest-federator`, `dpn-demo-runner-server` or `dpn-demo-runner-client` (no `all` option) |
| `targetRevision` | `0` (default) = previous stable revision, or a revision number from `helm history` |
| `confirm` | The `releaseName` value, retyped exactly |

It rolls back the one selected release in `ns-dpn-01` as described in [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component). The manual equivalent is:

```bash
helm rollback <release-name> <rollbackRevision> -n <namespace>
```

**Verification:**

```bash
kubectl get pods -n <namespace>
helm history <release-name> -n <namespace>
```

---

## Kafka Topic Recovery

Applicable to any component that produces to or consumes from Kafka (Data Pipeline, Federator Gateway, Health Monitoring Service's `otel-metrics`/`otel-logs`/`otel-traces` topics):

- **Delete invalid messages** — inspect and remove via the relevant Kafka UI.
- **Recreate a topic** — delete and recreate if the topic's own configuration (partitions, retention, replication factor) is wrong, not just its contents.
- **Resume from last offset** — redeploying a consumer without deleting anything resumes from its last committed consumer group offset; usually preferable to deleting messages.

> For Health Monitoring Service specifically: Kafka there is currently single-broker and non-persistent in `dev`/`devtest` — a topic-level recovery action may be moot if the underlying broker has already lost the data across a restart.

---

## Post-Rollback Verification (All Components)

```bash
kubectl get pods -n <namespace>
kubectl get svc -n <namespace>
kubectl get deployments -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

Component-specific additions:

| Component | Additional check |
|-----------|----------------------|
| Federator Certificate Manager / Vault | `kubectl -n <namespace> exec <pod-name> -- ls /tls` — confirm P12 keystore/truststore present |
| Data Pipeline / Federator Gateway | Kafka UI — confirm topics and message flow |
| File Scanning Service | Upload a clean test file and confirm it still lands in `dp-consumer-stage` post-rollback |
| Health Monitoring Service | `kubectl get hpa -n ns-dpn-health-01` — confirm the OTEL Collector's HPA is healthy post-rollback |

If more than one component was rolled back, work through this table **in the same order used in [Rollback Sequence Across Components](#rollback-sequence-across-components)** rather than checking them in whatever order is convenient — a downstream check passing doesn't mean much if an upstream component hasn't actually been confirmed healthy yet.

---

## Disaster Recovery Considerations

- Rebuild container images from the last stable tagged Git commit if no registry tag is usable.
- Reload the certificate bundle into Vault from a **secure offline copy** — without it, a corrupted Vault has no recovery path short of a new CSR to DSI DSM.
- Restore Kafka topics if data corruption occurred, understanding that Health Monitoring Service's current single-broker, non-persistent Kafka configuration may mean "restore" means "accept the data is gone."
- Re-run the CI/CD workflows with corrected configuration once the root cause is fixed, not just the symptom rolled back.

Organisations should maintain:

- Versioned Helm charts with revision history retained (don't `helm uninstall`/reinstall routinely — this resets revision history to 1, losing Strategy 2 targets).
- Versioned container images in the registry with previous build tags preserved, not garbage-collected aggressively — Strategy 1 depends on old tags still being pullable.
- Tagged Git releases for all components.
- A securely stored copy of the certificate bundle outside the cluster.

---

## Config and Installation Guide Cross-References

- **Each component's Installation Process** should link to this document from its own Troubleshooting section, and vice versa.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
