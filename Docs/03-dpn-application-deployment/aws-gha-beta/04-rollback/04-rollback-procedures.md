# DPN Rollback and Recovery Process

---

## Table of Contents

- [Overview](#overview)
- [Rollback Strategy](#rollback-strategy)
- [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component)
  - [Central Rollback Workflows](#central-rollback-workflows)
- [Pre-Rollback Checklist](#pre-rollback-checklist)
- [Rollback Sequence Across Components](#rollback-sequence-across-components)
- [Part 1 — DPN Data Pipeline Rollback](#part-1--dpn-data-pipeline-rollback)
  - [Strategy 1 — Redeploy a Previous Build via the Standard CD Workflow](#strategy-1--redeploy-a-previous-build-via-the-standard-cd-workflow)
  - [Strategy 2 — Helm Revision Rollback](#strategy-2--helm-revision-rollback)
  - [Which Strategy to Use](#which-strategy-to-use)
  - [Verification](#verification)
  - [Legacy Pre-2.1.0 Releases](#legacy-pre-210-releases)
- [Part 2 — DPN Federator Gateway Rollback](#part-2--dpn-federator-gateway-rollback)
- [Part 3 — DPN Federator Certificate Manager Rollback](#part-3--dpn-federator-certificate-manager-rollback)
- [Part 4 — DPN File Scanning Service Rollback](#part-4--dpn-file-scanning-service-rollback)
- [Part 5 — DPN Health Monitoring Service Rollback](#part-5--dpn-health-monitoring-service-rollback)
- [Kafka Topic Recovery](#kafka-topic-recovery)
- [Post-Rollback Verification (All Components)](#post-rollback-verification-all-components)
- [Disaster Recovery Considerations](#disaster-recovery-considerations)
- [Config and Installation Guide Cross-References](#config-and-installation-guide-cross-references)
- [Review Notes](#review-notes)

---

## Overview

This document describes rollback and recovery procedures across **all DPN components**: Vault, Federator Certificate Manager, Federator Gateway, Data Pipeline, File Scanning Service, and Health Monitoring Service.

The repository has one CD workflow per component (or, for Health Monitoring, one orchestrator that chains the sub-component workflows), and that same workflow is what you re-run to roll forward to an older image. Alongside them it has **three Helm-revision rollback workflows**: `dpn-gha-rollback-all-components.yml` (**DPN Rollback - All Components Pipelines**) for releases in the main namespace, `dpn-gha-rollback-health-monitoring.yml` (**DPN Rollback - Health Monitoring**) for `ns-dpn-health-01`, and `dpn-gha-self-service-rollback.yml` (**DPN Rollback - Self-Service Data Pipelines**) for `ns-dpn-dp-01` — see [Central Rollback Workflows](#central-rollback-workflows). This document generalises a two-mode approach (Helm revision vs. image tag) to every component via a mix of re-running the standard CD workflow, the rollback workflows, and manual `helm rollback`/`helm upgrade` commands.

All rollback operations here work at the **Helm release / container image** layer. Every rollback pipeline reduces to the same two modes, regardless of component — see [Rollback Strategy](#rollback-strategy).

Because several DPN components depend on one another at runtime (certificates, message flow, shared storage), rolling back more than one component at a time is not order-independent — see [Rollback Sequence Across Components](#rollback-sequence-across-components) before acting on more than one Part below.

---

## Rollback Strategy

There are **two separate mechanisms**, not two modes of one workflow — this is the key distinction to get right:

| | Mechanism used | What you provide | What it does |
|---|------------------|----------------------|-------------------|
| **Strategy 1 — Image tag rollback** | The **same, standard CD workflow** used for every normal deployment (`Actions → Run workflow`) | A previous **image tag** | Runs exactly like any other deployment — a fresh `helm upgrade --install` — except pointed at an older, already-built image instead of the latest one |
| **Strategy 2 — Helm revision rollback** | One of the central rollback workflows (see [Central Rollback Workflows](#central-rollback-workflows)), or a manual `helm rollback` command for a release those workflows don't list | A **Helm revision number** | Runs `helm rollback <release> <revision>`, reverting the release — chart *and* values — to exactly how it was at that revision |

The distinction matters for what actually gets reverted:

- **Strategy 1** The standard CD workflow deploys whatever the environment/cluster values file currently defines, just with an older `imageTag` substituted in. If the *values* are also wrong (not just the image), Strategy 1 alone won't fix that — it'll faithfully redeploy the bad values with an old image.

- **Strategy 2 reverts everything about that revision** — chart version, values, and therefore whatever image tag was in use at that revision too. It doesn't let you pick an image tag independently of the revision; you get exactly what that revision was.

**On image tags:** components pull from GHCR (`ghcr.io/energy-dsi/...`) by default, so `imageTag` is typically a semantic version or a DSI-provided stable tag rather than a numeric build ID — check your registry's tag history (GHCR package page, or `aws ecr describe-images` if you push to your own ECR) for what's actually available before choosing one to roll back to.

---

## Rollback Workflow Availability by Component

| Component | Standard CD workflow (Strategy 1) | Dedicated rollback workflow (Strategy 2) | 
|-----------|--------------------------------------|-----------------------------------------------|
| DPN Data Pipeline (2.1.0 Self-Service: `dpn-self-service`, `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor`) | `dpn-gha-self-service-cd.yml` | `dpn-gha-self-service-rollback.yml` |
| DPN Data Pipeline (releases deployed by `dpn-gha-cd-data-pipelines.yml`, incl. legacy pre-2.1.0 releases) | `dpn-gha-cd-data-pipelines.yml` | `dpn-gha-rollback-all-components.yml` for the releases in its choice list (e.g. `dpn-producer-file-adaptor-default`, `dpn-producer-topic-adaptor-eqbd`); otherwise manual `helm rollback` |
| DPN Federator Gateway (`dpn-platform`) | `dpn-gha-federator-gateway-cd.yml` | `dpn-gha-rollback-all-components.yml` |
| DPN Federator Certificate Manager (`dpn-certificate-manager`) | `dpn-gha-certificate-manager-cd.yml` | `dpn-gha-rollback-all-components.yml` |
| Vault (`vault-https`) | `dpn-gha-vault-https-cd.yml` | `dpn-gha-rollback-all-components.yml` |
| DPN REST Federator Gateway (`dpn-rest-federator`, `dpn-redis`) | `dpn-gha-rest-federator-cd.yml` | `dpn-gha-rollback-all-components.yml` |
| DPN Demo Runner (`dpn-demo-runner-server`, `dpn-demo-runner-client`) | `dpn-gha-demo-runner-cd.yml` | `dpn-gha-rollback-all-components.yml` |
| DPN Authentication Service (`dpn-keycloak`) | `dpn-gha-keycloak-cd.yml` | `dpn-gha-rollback-all-components.yml` |
| DPN File Scanning Service (`dpn-file-scan-service`) | `dpn-gha-file-scan-cd.yml` | `dpn-gha-rollback-all-components.yml` |
| DPN Health Monitoring Service | `dpn-gha-health-monitoring-cd-install.yml` (orchestrator — the per-component workflows are `workflow_call`-only and can't be triggered standalone) | `dpn-rollback-health-monitoring.yml` for Kafka, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses and OTel; manual `helm rollback` for DPN Portal, the `oauth2-proxy` releases and `dpn-redis-ui-health` |

### Central Rollback Workflows

The three rollback workflows share the same pattern. Go to **Actions → <workflow> → Run workflow** and set:

| Input | `dpn-gha-rollback-all-components.yml` | `dpn-gha-rollback-health-monitoring.yml` | `dpn-gha-self-service-rollback.yml` |
|-------|-----------------------------------|--------------------------------------|---------------------------------|
| `environment` | `dev` / `test` (default `dev`) | `dev` / `test` (default `dev`) | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02` | `dpn01` / `dpn02` | `dpn01` / `dpn02` |
| `cloud` | `aws` (default is `azure` — change it) | `aws` (default is `azure` — change it) | `aws` (default) |
| Release input | `releaseName` — one exact Helm release from the choice list | `releaseName` — `all`, `otel`, `perses`, `jaeger`, `data-prepper`, `thanos`, `prometheus`, `opensearch` or `kafka` | `release_name` — `dpn-self-service`, `dpn-consumer-file-extractor` or `dpn-consumer-topic-extractor` |
| `targetRevision` | `0` (default) = previous stable revision, or a revision number from `helm history` | Same; with `all`, `0` is resolved separately for each release | Same |
| `confirm` | Retype the `releaseName` value exactly | Retype the `releaseName` value exactly | Retype the `release_name` value exactly |

Each workflow loads `.pipelines/github-action-pipelines/config/aws/<environment>-<cluster>.json`, signs in to EKS through the `cloud-login` composite action (GitHub OIDC → `oidc_github_runner_admin` in the target account), and runs on the self-hosted runner under the GitHub Environment `<environment>-<cluster>`, so any required reviewers on that environment act as the approval gate. It then shows the release history, refuses a target revision whose status is not `deployed` or `superseded`, runs `helm rollback --dry-run`, and finally `helm rollback <release> <revision> --wait` (timeout 15 minutes; 10 minutes for the Self-Service workflow).

- `dpn-gha-rollback-all-components.yml` works in the `NAMESPACE` from the config JSON (`ns-dpn-01`) and rolls back exactly one release per run.
- `dpn-gha-rollback-health-monitoring.yml` always works in `ns-dpn-health-01`. With `releaseName: all` it rolls back every listed component in reverse deployment order and skips, rather than fails, any component that is not installed or has no earlier stable revision. Its `nginx` option targets the retired `dpn-nginx-observability` release and has nothing to roll back on a current install.
- `dpn-gha-self-service-rollback.yml` always works in `ns-dpn-dp-01`, and shows the image each revision would run so a bad revision is easy to spot.

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

**If only one component is broken, there is no sequence to worry about** — follow the relevant Part (1–5) on its own. A sequence only matters when a bad release touched more than one component at once, or when rolling back one component could invalidate what a dependent component is currently using.

The runtime dependency chain across DPN components is:

```
Vault
  └─→ Federator Certificate Manager (persists certs to Vault)
        └─→ Federator Gateway (uses issued certs for mTLS)
              └─→ Data Pipeline (hands off data via Federator Gateway)
                    └─→ File Scanning Service (writes into Data Pipeline's dp-consumer-stage bucket)

Health Monitoring Service — independent of the chain above; every other component sends telemetry to it, but nothing above depends on it to function
```

When multiple components need rolling back together, work **down the chain, from Vault outward**, for the same reason you'd deploy in that order: a downstream component's current config assumes the upstream one is in a known-good state.

1. **Vault** — only if the certificate bundle itself is suspect (not just the Certificate Manager's code). Restore from a secure offline copy per [Disaster Recovery Considerations](#disaster-recovery-considerations) before touching anything downstream, since every other component's mTLS depends on Vault's contents being valid.
2. **Federator Certificate Manager** — roll back its deployment (Part 3) if the manager's own code is at fault. This does not affect Vault's stored certificates, so it's safe to do independently of step 1 unless the manager's rollback would reintroduce code that mismanages Vault contents.
3. **Federator Gateway** — roll back (Part 2) only after Vault/Certificate Manager are confirmed healthy; otherwise the Gateway may roll back into a config that expects certificates Vault no longer has in the expected state.
4. **Data Pipeline** — roll back (Part 1) once the Federator Gateway is confirmed healthy, since the Data Pipeline hands data off through it.
5. **File Scanning Service** — roll back (Part 4) last in the chain, since it depends on the Data Pipeline's `dp-consumer-stage` container already existing and being written to correctly.
6. **Health Monitoring Service** — roll back (Part 5) at any point relative to the above, but do it **after** the others if you still need its dashboards to confirm the other rollbacks succeeded. If Health Monitoring itself is the only thing broken, there's no ordering constraint with the rest of the chain at all.

If you're rolling back the *whole platform* to a prior known-good state (e.g. after a bad multi-component release), apply this same order rather than rolling back whichever component's alert fired first — an out-of-order rollback (e.g. Data Pipeline before Federator Gateway) risks the component you just fixed immediately breaking again once its upstream dependency changes under it.

---

## Part 1 — DPN Data Pipeline Rollback

In the 2.1.0 Self-Service design the Data Pipeline is three Helm releases in `ns-dpn-dp-01` — `dpn-self-service`, `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` — deployed by the central `dpn-self-service-cd.yml` workflow from the charts in `dpn-data-pipelines/` (`service/charts`, `blueprints/consumer/file/extractor/charts`, `blueprints/consumer/topic/extractor/charts`) (see [Execute Data Pipeline CD Workflow](../03-installation/07-dpn-data-pipeline-installation-process.md#step-02c-execute-data-pipeline-cd-workflow)). Producer data products are created by the Self-Service UI as plain Deployments, not Helm releases, so there is nothing to roll back for them with Helm. 

### Strategy 1 — Redeploy a Previous Build via the Standard CD Workflow

Go to **Actions → DPN CD - Self-Service Data Pipelines → Run workflow** (`dpn-gha-self-service-cd.yml`) — the same workflow used for every normal deployment, not a rollback-specific one — select `environment` and `cluster`, and set `imageTag` to a previous, known-good tag. All three releases are redeployed with that tag. See [Execute Data Pipeline CD Workflow](../03-installation/07-dpn-data-pipeline-installation-process.md#step-02c-execute-data-pipeline-cd-workflow) for the full list of inputs.

**Finding a previous tag:** the CI image tag is the CI run number. Check the GHCR package page for the image, or if pushing to your own ECR:

```bash
aws ecr describe-images --repository-name <image-name> --region <AWS_REGION> --query 'sort_by(imageDetails,& imagePushedAt)[*].imageTags'
```

### Strategy 2 — Helm Revision Rollback

**Workflow:** the central repository provides **DPN Rollback - Self-Service Data Pipelines** (`.pipelines/github-action-pipelines/workflows/dpn-self-service-rollback.yml`). It rolls back one release at a time in `ns-dpn-dp-01`:

| Input | Value |
|-------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `release_name` | `dpn-self-service`, `dpn-consumer-file-extractor` or `dpn-consumer-topic-extractor` |
| `targetRevision` | Revision to roll back to; `0` (default) for the previous stable revision |
| `confirm` | The `release_name` value, retyped exactly |

The workflow waits for approval on the GitHub Environment `<environment>-<cluster>`, lists the last five revisions with the image each one runs, runs a `--dry-run` and then `helm rollback <release_name> <revision> -n ns-dpn-dp-01 --wait --timeout 10m`.

**Manual equivalent:**

```bash
helm history <release-name> -n ns-dpn-dp-01
helm rollback <release-name> <rollbackRevision> -n ns-dpn-dp-01
```

`helm rollback` will simply fail if the revision number doesn't exist, so check the history first.

### Which Strategy to Use

| Situation | Use |
|-----------|-----|
| The image build is broken (bad code, bad dependency) but the Helm values/chart are fine | **Strategy 1** — redeploy an older build number |
| A values/config change was bad (wrong secret reference, wrong scheduling config, wrong resource limits) | **Strategy 2** — revert to a prior Helm revision |
| Both the image *and* the values changed and both are suspect | **Strategy 2** first (reverts both), then confirm the image at that revision is actually the one you want — use Strategy 1 afterward only if you need an even older image than what that revision had |

### Verification

```bash
kubectl get deployment <release-name> -n ns-dpn-dp-01 \
  -o=jsonpath='{.spec.template.spec.containers[0].image}'

kubectl rollout status deployment/<release-name> -n ns-dpn-dp-01 --timeout=180s
```

### Legacy Pre-2.1.0 Releases

Releases deployed by the central `dpn-cd-data-pipelines.yml` workflow (**DPN CD - Data Pipelines**) rather than by the Self-Service UI live in `ns-dpn-01`. The workflow deploys one release per run from the generic chart `dpn-data-pipelines/blueprints/<configType>/<processType>/<adaptor|extractor>/charts`, named `dpn-<configType>-<processType>-<adaptor|extractor>-<productType>` (for example `dpn-producer-file-adaptor-default`). Roll them back by re-running that workflow with the same `configType`/`processType`/`productType`/`schemaType` and an older `imageTag` (Strategy 1), or with **DPN Rollback - All Components Pipelines** if the release is in its `releaseName` list, or `helm rollback <release-name> <rollbackRevision> -n ns-dpn-01` (Strategy 2). Releases left from older runs may carry earlier names; use `helm list -n ns-dpn-01` to find them. Pre-2.1.0 data products are not imported into the Self-Service UI; to move one to the 2.1.0 design, recreate it in the UI.

---

## Part 2 — DPN Federator Gateway Rollback

**Strategy 1 — standard CD workflow (`dpn-federator-gateway-cd.yml`):** re-run with an older `imageTag`. Since this workflow deploys the entire `dpn-platform` release together (Zookeeper Source/Target, Kafka Source/Target, Kafka UI, Redis, Federator Server, Federator Client), redeploying an old tag rebuilds the whole platform release at that image version, not just one sub-component.

If only one sub-component's image needs to change, target it directly instead of using the platform-wide workflow:

```bash
kubectl set image deployment/dpn-federator-server-1 \
  dpn-federator-server-1=<ecr-url-or-ghcr>/dpn-federator-server:<imageTag> -n ns-dpn-01
kubectl rollout status deployment/dpn-federator-server-1 -n ns-dpn-01
```

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - All Components Pipelines** (`dpn-gha-rollback-all-components.yml`) with `releaseName: dpn-platform`, or manually:

```bash
helm rollback dpn-platform <rollbackRevision> -n ns-dpn-01
```

Reverts the entire combined release — every sub-component — to that revision at once. There's no partial Helm-revision rollback of just one sub-component within a shared release.

**Verification:**

```bash
kubectl get pods -n ns-dpn-01
helm history dpn-platform -n ns-dpn-01
```

---

## Part 3 — DPN Federator Certificate Manager Rollback

**Strategy 1 — standard CD workflow (`dpn-certificate-manager-cd.yml`):** re-run with an older `imageTag`.

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - All Components Pipelines** with `releaseName: dpn-certificate-manager` (or `vault-https` for Vault), or manually:

```bash
helm rollback dpn-certificate-manager <rollbackRevision> -n ns-dpn-01
```

**Neither strategy rolls back Vault's contents** — the certificate manager's deployment revision is independent of what's stored in Vault. If the problem is the *certificate bundle itself* rather than the certificate manager's code, see [Disaster Recovery Considerations](#disaster-recovery-considerations).

**Verification:**

```bash
kubectl get pods -n ns-dpn-01
# keystore/truststore are on the shared PVC pvc-dpn-certs-fileshare, mounted by the Federator Server at /tls
kubectl -n ns-dpn-01 exec deploy/dpn-federator-server-1 -- ls /tls
```

---

## Part 4 — DPN File Scanning Service Rollback

Use the standard CD workflow for Strategy 1, and **DPN Rollback - All Components Pipelines** (`releaseName: dpn-file-scan-service`) or manual Helm commands for Strategy 2, per [Rollback Strategy](#rollback-strategy) and [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component).

**Strategy 1 — re-run `dpn-file-scan-cd.yml` (DPN CD - File Scan Service) with an older `imageTag`.** To change only the image without a workflow run, the direct equivalent is:

```bash
kubectl set image deployment/dpn-file-scan-service \
  dpn-file-scan-service=<ecr-url-or-ghcr>/dpn-file-scan-service:<imageTag> -n ns-dpn-01
kubectl rollout status deployment/dpn-file-scan-service -n ns-dpn-01
```

**Strategy 2 — Helm revision rollback (manual equivalent):**

```bash
helm history dpn-file-scan-service -n ns-dpn-01
helm rollback dpn-file-scan-service <rollbackRevision> -n ns-dpn-01
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

Every sub-component (Kafka, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, OTel Collector, DPN Portal, oauth2-proxy) has its own CD workflow in code (`dpn-cd-kafka.yml`, `dpn-cd-opensearch.yml`, etc.), but these are **`workflow_call`-only** — they can't be triggered standalone from the Actions tab, only invoked by the `dpn-health-monitoring-cd-install.yml` orchestrator.

> **Note:** `dpn-portal` — a tile landing page that links out to the observability UIs — has replaced the retired `nginx-observability` reverse proxy as the last component in this chain; it is fronted by its own `oauth2-proxy` gateway rather than acting as the reverse proxy itself. The `oauth2-proxy` gateways that used to front Kafka UI, Prometheus, and Thanos directly have also been retired: Kafka UI now uses native Keycloak OIDC login and is exposed on its own internal load balancer, and Prometheus/Thanos are no longer browsed directly (both are consumed through Perses).

**Strategy 1 — re-run the orchestrator:** go to **Actions → DPN Health Monitoring → Run workflow** (`dpn-health-monitoring-cd-install.yml`, `cloud: aws`). This redeploys the full dependency chain (Kafka → OpenSearch → Prometheus → Thanos, etc.) — the OTel Collector's `imageTag` (default `0.95.0`) and optional `otelImageRepository` are inputs, and DPN Portal likewise requires its own `portalImageTag` input (with `portalImageRepository`, default `1.0.1/dpn-portal`) since that chart ships no default image; other sub-components don't take an image tag from the orchestrator today, so an image-tag rollback for those means Strategy 2 instead.

**Strategy 2 — Helm revision rollback for the affected sub-component:** run **DPN Rollback - Health Monitoring** (`dpn-rollback-health-monitoring.yml`, see [Central Rollback Workflows](#central-rollback-workflows)) with `releaseName` set to the component (`kafka`, `opensearch`, `prometheus`, `thanos`, `data-prepper`, `jaeger`, `perses`, `otel`), or `all` to roll the whole stack back in reverse dependency order. DPN Portal, the `oauth2-proxy` releases and `dpn-redis-ui-health` are not in that workflow's list, so roll those back manually.

The manual equivalent for any sub-component:

The release names (set in each `dpn-cd-*.yml` workflow) are `dpn-kafka-stack`, `dpn-opensearch`, `dpn-prometheus`, `dpn-thanos`, `dpn-data-prepper`, `dpn-jaeger`, `dpn-perses`, `dpn-otel-collector-health`, `dpn-portal`, `dpn-oauth2-proxy-osd`, `dpn-oauth2-proxy-jaeger`, `dpn-oauth2-proxy-perses`, `dpn-oauth2-proxy-portal` and `dpn-redis-ui-health`.

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
| Federator Certificate Manager / Vault | `kubectl -n ns-dpn-01 exec deploy/dpn-federator-server-1 -- ls /tls` — confirm P12 keystore/truststore present on the shared PVC |
| Data Pipeline / Federator Gateway | Kafka UI — confirm topics and message flow; for the Data Pipeline also `kubectl get pods -n ns-dpn-dp-01` and **Run Now** on a data product in the Self-Service UI |
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
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
