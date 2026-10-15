# DPN Rollback and Recovery Process

---

## Table of Contents

- [Overview](#overview)
- [Rollback Strategy](#rollback-strategy)
- [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component)
  - [Rollback Workflows](#rollback-workflows)
- [Pre-Rollback Checklist](#pre-rollback-checklist)
- [Rollback Sequence Across Components](#rollback-sequence-across-components)
- [Part 1 — DPN Data Pipeline Rollback](#part-1--dpn-data-pipeline-rollback)
  - [Strategy 1 — Redeploy a Previous Build via the Standard CD Workflow](#strategy-1--redeploy-a-previous-build-via-the-standard-cd-workflow)
  - [Strategy 2 — Helm Revision Rollback](#strategy-2--helm-revision-rollback)
  - [Which Strategy to Use](#which-strategy-to-use)
  - [Verification](#verification)
  - [Legacy Pre-2.1.0 Releases](#legacy-pre-210-releases)
- [Part 2 — DPN Federator Gateway Rollback](#part-2--dpn-federator-gateway-rollback)
  - [Part 2a — DPN REST Federator Gateway Rollback](#part-2a--dpn-rest-federator-gateway-rollback)
- [Part 3 — DPN Federator Certificate Manager Rollback](#part-3--dpn-federator-certificate-manager-rollback)
- [Part 4 — DPN File Scanning Service Rollback](#part-4--dpn-file-scanning-service-rollback)
- [Part 5 — DPN Health Monitoring Service Rollback](#part-5--dpn-health-monitoring-service-rollback)
- [Part 5a — DPN Authentication Service Rollback](#part-5a--dpn-authentication-service-rollback)
- [Kafka Topic Recovery](#kafka-topic-recovery)
- [Post-Rollback Verification (All Components)](#post-rollback-verification-all-components)
- [Disaster Recovery Considerations](#disaster-recovery-considerations)
- [Config and Installation Guide Cross-References](#config-and-installation-guide-cross-references)
- [Review Notes](#review-notes)

---

## Overview

This document describes rollback and recovery procedures across **all DPN components**: Vault, Federator Certificate Manager, Federator Gateway (and the optional REST Federator Gateway), Data Pipeline, File Scanning Service, Health Monitoring Service, and Authentication Service.

Each component repository has one CD workflow per component under `.github/workflows/` (or, for Health Monitoring, one orchestrator that chains the sub-component workflows), and that same workflow is what you re-run to roll forward to an older image. Alongside them, **each component repository has its own Helm-revision rollback workflow** (two in `dpn-data-pipelines`): `dpn-gha-keycloak-rollback.yaml`, `dpn-gha-certificate-manager-rollback.yaml`, `dpn-gha-federator-gateway-rollback.yaml`, `dpn-gha-rest-federator-rollback.yaml`, `dpn-gha-file-scan-rollback.yaml`, `dpn-gha-data-pipelines-rollback.yaml` and `dpn-gha-self-service-rollback.yaml`, and `dpn-gha-rollback-health-monitoring.yaml` — see [Rollback Workflows](#rollback-workflows). This document generalises a two-mode approach (Helm revision vs. image tag) to every component via a mix of re-running the standard CD workflow, the rollback workflows, and manual `helm rollback`/`helm upgrade` commands.

All rollback operations here work at the **Helm release / container image** layer. Every rollback pipeline reduces to the same two modes, regardless of component — see [Rollback Strategy](#rollback-strategy).

Because several DPN components depend on one another at runtime (certificates, message flow, shared storage), rolling back more than one component at a time is not order-independent — see [Rollback Sequence Across Components](#rollback-sequence-across-components) before acting on more than one Part below.

---

## Rollback Strategy

There are **two separate mechanisms**, not two modes of one workflow — this is the key distinction to get right:

| | Mechanism used | What you provide | What it does |
|---|------------------|----------------------|-------------------|
| **Strategy 1 — Image tag rollback** | The **same, standard CD workflow** used for every normal deployment (`Actions → Run workflow`) | A previous **image tag** | Runs exactly like any other deployment — a fresh `helm upgrade --install` — except pointed at an older, already-built image instead of the latest one |
| **Strategy 2 — Helm revision rollback** | The component's rollback workflow (see [Rollback Workflows](#rollback-workflows)), or a manual `helm rollback` command for a release those workflows don't cover | A **Helm revision number** | Runs `helm rollback <release> <revision>`, reverting the release — chart *and* values — to exactly how it was at that revision |

The distinction matters for what actually gets reverted:

- **Strategy 1** The standard CD workflow deploys whatever the environment/cluster values file currently defines, just with an older `imageTag` substituted in. If the *values* are also wrong (not just the image), Strategy 1 alone won't fix that — it'll faithfully redeploy the bad values with an old image.

- **Strategy 2 reverts everything about that revision** — chart version, values, and therefore whatever image tag was in use at that revision too. It doesn't let you pick an image tag independently of the revision; you get exactly what that revision was.

**On image tags:** components pull from GHCR (`ghcr.io/energy-dsi/...`) by default, so `imageTag` is typically a semantic version or a DSI-provided stable tag rather than a numeric build ID — check your registry's tag history (GHCR package page, or `aws ecr describe-images` if you push to your own ECR) for what's actually available before choosing one to roll back to.

---

## Rollback Workflow Availability by Component

| Component | Standard CD workflow (Strategy 1) | Dedicated rollback workflow (Strategy 2) | 
|-----------|--------------------------------------|-----------------------------------------------|
| DPN Data Pipeline (2.1.0 Self-Service: `dpn-self-service`, `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor`) | `dpn-gha-self-service-cd.yaml` | `dpn-gha-self-service-rollback.yaml` |
| DPN Data Pipeline (releases deployed by `dpn-gha-data-pipelines-cd.yaml`, incl. legacy pre-2.1.0 releases) | `dpn-gha-data-pipelines-cd.yaml` | `dpn-gha-data-pipelines-rollback.yaml` (release name entered as free text) |
| DPN Federator Gateway (`dpn-platform`) | `dpn-gha-federator-gateway-cd.yaml` | `dpn-gha-federator-gateway-rollback.yaml` |
| DPN Federator Certificate Manager (`dpn-certificate-manager`) | `dpn-gha-certificate-manager-cd.yaml` | `dpn-gha-certificate-manager-rollback.yaml` (`releaseName: certificate-manager`) |
| Vault (`vault-https`) | `dpn-gha-vault-https-cd.yaml` | `dpn-gha-certificate-manager-rollback.yaml` (`releaseName: vault-https`) |
| Vault, legacy plain-HTTP (`vault`) | `dpn-gha-vault-cd.yaml` | None — manual `helm rollback` |
| DPN REST Federator Gateway (`dpn-rest-federator`, `dpn-redis`) | `dpn-gha-rest-federator-cd.yaml` | `dpn-gha-rest-federator-rollback.yaml` |
| DPN Demo Runner (`dpn-demo-runner-server`, `dpn-demo-runner-client`) | `dpn-gha-demo-runner-cd.yaml` | `dpn-gha-rest-federator-rollback.yaml` |
| DPN Authentication Service (`dpn-keycloak`) | `dpn-gha-keycloak-cd.yaml` | `dpn-gha-keycloak-rollback.yaml` |
| DPN File Scanning Service (`dpn-file-scan-service`) | `dpn-gha-file-scan-cd.yaml` | `dpn-gha-file-scan-rollback.yaml` |
| DPN Health Monitoring Service | `dpn-gha-health-monitoring-cd-install.yaml` (orchestrator — the per-component workflows are `workflow_call`-only and can't be triggered standalone) | `dpn-gha-rollback-health-monitoring.yaml` for every sub-component release: Kafka, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, OTel, DPN Portal, the four `oauth2-proxy` releases and `dpn-redis-ui-health` |

Each CD workflow lives in its component's own repository under `.github/workflows/` (`dpn-data-pipelines`, `dpn-federator-gateway`, `dpn-federator-certificate-manager`, `dpn-rest-federator-gateway`, `dpn-authentication-service`, `dpn-file-scan-service`, `dpn-health-monitoring-service`), alongside the Helm chart it deploys (for example `dpn-federator-gateway/charts/dpn-platform`, `dpn-federator-certificate-manager/charts/certificate-manager`, `dpn-file-scan-service/charts/file-scan-service`, `dpn-data-pipelines/service/charts`), each with its AWS values file at `values/aws/<environment>-<cluster>.yaml`.

### Rollback Workflows

Every rollback workflow lives in `.github/workflows/` of its component's repository and is run from **Actions → <workflow> → Run workflow**:

| Workflow (repository) | Display name | Release selection | `confirm` value | Namespace |
|-----------------------|--------------|-------------------|-----------------|-----------|
| `dpn-gha-keycloak-rollback.yaml` (`dpn-authentication-service`) | DPN Rollback - Keycloak | None — always `dpn-keycloak` (Keycloak and its bundled PostgreSQL) | `dpn-keycloak` | `NAMESPACE` from the config JSON |
| `dpn-gha-certificate-manager-rollback.yaml` (`dpn-federator-certificate-manager`) | DPN Rollback - Certificate Manager | `releaseName` — `all`, `certificate-manager` (`dpn-certificate-manager`) or `vault-https` (`vault-https`) | The `releaseName` value | `NAMESPACE` from the config JSON |
| `dpn-gha-federator-gateway-rollback.yaml` (`dpn-federator-gateway`) | DPN Rollback - Federator Gateway | None — always `dpn-platform` | `dpn-platform` | `NAMESPACE` from the config JSON |
| `dpn-gha-rest-federator-rollback.yaml` (`dpn-rest-federator-gateway`) | DPN Rollback - REST Federator Gateway | `releaseName` — `dpn-redis`, `dpn-rest-federator`, `dpn-demo-runner-server` or `dpn-demo-runner-client` | The `releaseName` value | `NAMESPACE` from the config JSON |
| `dpn-gha-file-scan-rollback.yaml` (`dpn-file-scan-service`) | DPN Rollback - File Scan Service | None — always `dpn-file-scan-service` | `dpn-file-scan-service` | `NAMESPACE` from the config JSON |
| `dpn-gha-data-pipelines-rollback.yaml` (`dpn-data-pipelines`) | DPN Rollback - Data Pipelines | `releaseName` — free text; the exact release name from `helm list` | The `releaseName` value | `NAMESPACE` from the config JSON |
| `dpn-gha-self-service-rollback.yaml` (`dpn-data-pipelines`) | DPN Rollback - Self-Service Data Pipelines | `release_name` — `dpn-self-service` (default), `dpn-consumer-file-extractor` or `dpn-consumer-topic-extractor` | The `release_name` value | `ns-dpn-dp-01` (fixed) |
| `dpn-gha-rollback-health-monitoring.yaml` (`dpn-health-monitoring-service`) | DPN Rollback - Health Monitoring | `releaseName` — `all`, `oauth2-portal`, `oauth2-perses`, `oauth2-jaeger`, `portal`, `otel`, `oauth2-osd`, `redis-ui`, `perses`, `thanos`, `jaeger`, `data-prepper`, `prometheus`, `opensearch` or `kafka` | The `releaseName` value | `ns-dpn-health-01` (fixed) |

The `NAMESPACE` in every shipped `.github/config/aws/<environment>-<cluster>.json` is `ns-dpn-01`. All of them also take:

| Input | Values |
|-------|--------|
| `environment` | `dev` / `test` (default `dev`; `test` for the Self-Service workflow) |
| `cluster` | `dpn01` / `dpn02` (default `dpn01`) |
| `cloud` | `azure` / `aws` (default `aws`). The Health Monitoring workflow defaults to `azure` — change it to `aws`. The Self-Service workflow lists `aws` / `azure` / `gcp` (default `aws`). |
| `targetRevision` | `0` (default) = the previous stable revision (the last `deployed`/`superseded` revision before the current one), or a revision number from `helm history <release>`. Must be a non-negative integer. |

Each workflow first checks that `confirm` matches and that `targetRevision` is a non-negative integer, then loads `.github/config/aws/<environment>-<cluster>.json` from its own repository, signs in to EKS through the `cloud-login` composite action (GitHub OIDC → `oidc_github_runner_admin` in the target account), and runs on the self-hosted runner under the GitHub Environment `<environment>-<cluster>`, so any required reviewers on that environment act as the approval gate. It then shows the release history, refuses a target revision whose status is not `deployed` or `superseded`, runs `helm rollback --dry-run`, and finally `helm rollback <release> <revision> --wait` (timeout 15 minutes; 10 minutes for the Data Pipelines and Self-Service workflows), and lists the pods and releases afterwards.

- The single-release workflows (Keycloak, Federator Gateway, REST Federator Gateway, File Scan Service, Data Pipelines) fail if the release is not installed or has no earlier stable revision.
- `dpn-gha-certificate-manager-rollback.yaml` with `releaseName: all` rolls back `dpn-certificate-manager` first, then `vault-https`, resolving `0` separately for each. A release that is not installed or has no earlier stable revision is skipped; a release whose rollback fails is reported and fails the run once the other release has been handled. It does not cover the legacy plain-HTTP `vault` release.
- `dpn-gha-rollback-health-monitoring.yaml` always works in `ns-dpn-health-01`. With `releaseName: all` it rolls back every listed component in reverse deployment order (`oauth2-portal` → `oauth2-perses` → `oauth2-jaeger` → `portal` → `otel` → `oauth2-osd` → `redis-ui` → `perses` → `thanos` → `jaeger` → `data-prepper` → `prometheus` → `opensearch` → `kafka`) and skips, rather than fails, any component that is not installed or has no earlier stable revision.
- `dpn-gha-self-service-rollback.yaml` always works in `ns-dpn-dp-01`, and shows the image each revision would run so a bad revision is easy to spot. It also stops before signing in if the config JSON still contains `TODO` placeholder values (the shipped `aws/test-dpn01.json` and `aws/test-dpn02.json` in `dpn-data-pipelines` currently do).

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

In the 2.1.0 Self-Service design the Data Pipeline is three Helm releases in `ns-dpn-dp-01` — `dpn-self-service`, `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` — deployed by the `dpn-gha-self-service-cd.yaml` workflow in `dpn-data-pipelines` from the charts in that repository (`service/charts`, `blueprints/consumer/file/extractor/charts`, `blueprints/consumer/topic/extractor/charts`) (see [Execute Data Pipeline CD Workflow](../03-installation/07-dpn-data-pipeline-installation-process.md#step2c-execute-data-pipeline-cd-workflow)). Producer data products are created by the Self-Service UI as plain Deployments, not Helm releases, so there is nothing to roll back for them with Helm.

> **Note:** The Self-Service CD, rollback and uninstall workflows (`dpn-gha-self-service-cd.yaml`, `dpn-gha-self-service-rollback.yaml`, `dpn-gha-self-service-uninstall.yaml`) are in `dpn-data-pipelines/.github/workflows/`.

### Strategy 1 — Redeploy a Previous Build via the Standard CD Workflow

Go to **Actions → DPN CD - Self-Service Data Pipelines → Run workflow** (`dpn-gha-self-service-cd.yaml`) — the same workflow used for every normal deployment, not a rollback-specific one — select `environment` and `cluster`, and set `imageTag` to a previous, known-good tag. All three releases are redeployed with that tag. See [Execute Data Pipeline CD Workflow](../03-installation/07-dpn-data-pipeline-installation-process.md#step2c-execute-data-pipeline-cd-workflow) for the full list of inputs.

**Finding a previous tag:** the CI image tag is the CI run number. Check the GHCR package page for the image, or if pushing to your own ECR:

```bash
aws ecr describe-images --repository-name <image-name> --region <AWS_REGION> --query 'sort_by(imageDetails,& imagePushedAt)[*].imageTags'
```

### Strategy 2 — Helm Revision Rollback

**Workflow:** `dpn-data-pipelines` provides **DPN Rollback - Self-Service Data Pipelines** (`.github/workflows/dpn-gha-self-service-rollback.yaml`). It rolls back one release at a time in `ns-dpn-dp-01`:

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

Releases deployed by the `dpn-gha-data-pipelines-cd.yaml` workflow in `dpn-data-pipelines` (**DPN CD - Data Pipelines**) rather than by the Self-Service UI live in `ns-dpn-01`. The workflow deploys one release per run from the generic chart `dpn-data-pipelines/blueprints/<configType>/<processType>/<adaptor|extractor>/charts`, named `dpn-<configType>-<processType>-<adaptor|extractor>-<productType>` (for example `dpn-producer-file-adaptor-default`). Roll them back by re-running that workflow with the same `configType`/`processType`/`productType`/`schemaType` and an older `imageTag` (Strategy 1), or with **DPN Rollback - Data Pipelines** (`dpn-gha-data-pipelines-rollback.yaml`, see [Rollback Workflows](#rollback-workflows)) — enter the exact release name from `helm list -n ns-dpn-01` as `releaseName` and retype it in `confirm` — or `helm rollback <release-name> <rollbackRevision> -n ns-dpn-01` (Strategy 2). Releases left from older runs may carry earlier names; use `helm list -n ns-dpn-01` to find them. Pre-2.1.0 data products are not imported into the Self-Service UI; to move one to the 2.1.0 design, recreate it in the UI.

---

## Part 2 — DPN Federator Gateway Rollback

**Strategy 1 — standard CD workflow (`dpn-gha-federator-gateway-cd.yaml`):** re-run with an older `imageTag`. Since this workflow deploys the entire `dpn-platform` release together (Zookeeper Source/Target, Kafka Source/Target, Kafka UI, Redis, Federator Server, Federator Client), redeploying an old tag rebuilds the whole platform release at that image version, not just one sub-component.

If only one sub-component's image needs to change, target it directly instead of using the platform-wide workflow:

```bash
kubectl set image deployment/dpn-federator-server-1 \
  dpn-federator-server-1=<ecr-url-or-ghcr>/dpn-federator-server:<imageTag> -n ns-dpn-01
kubectl rollout status deployment/dpn-federator-server-1 -n ns-dpn-01
```

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - Federator Gateway** (`dpn-gha-federator-gateway-rollback.yaml` in `dpn-federator-gateway`, see [Rollback Workflows](#rollback-workflows)) with `confirm: dpn-platform`, or manually:

```bash
helm rollback dpn-platform <rollbackRevision> -n ns-dpn-01
```

Reverts the entire combined release — every sub-component — to that revision at once. There's no partial Helm-revision rollback of just one sub-component within a shared release. The workflow's checklist notes that rolling back a Kafka/Zookeeper topology change can disrupt in-flight messages, and that the Vault AppRole `role_id` and the federator TLS material are not affected by the rollback.

**Verification:**

```bash
kubectl get pods -n ns-dpn-01
helm history dpn-platform -n ns-dpn-01
```

### Part 2a — DPN REST Federator Gateway Rollback

The optional REST Federator Gateway is deployed as the releases `dpn-rest-federator` and `dpn-redis` by `dpn-gha-rest-federator-cd.yaml`, and the demo runner as `dpn-demo-runner-server` and `dpn-demo-runner-client` by `dpn-gha-demo-runner-cd.yaml`, both in `dpn-rest-federator-gateway`.

**Strategy 1 — standard CD workflow:** re-run `dpn-gha-rest-federator-cd.yaml` (or `dpn-gha-demo-runner-cd.yaml`) with an older `imageTag`.

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - REST Federator Gateway** (`dpn-gha-rest-federator-rollback.yaml`, see [Rollback Workflows](#rollback-workflows)) with `releaseName` set to one of the four releases and the same value retyped in `confirm`. It rolls back one release per run. Manually:

```bash
helm history dpn-rest-federator -n ns-dpn-01
helm rollback dpn-rest-federator <rollbackRevision> -n ns-dpn-01
```

---

## Part 3 — DPN Federator Certificate Manager Rollback

**Strategy 1 — standard CD workflow (`dpn-gha-certificate-manager-cd.yaml`):** re-run with an older `imageTag`.

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - Certificate Manager** (`dpn-gha-certificate-manager-rollback.yaml` in `dpn-federator-certificate-manager`, see [Rollback Workflows](#rollback-workflows)) with `releaseName: certificate-manager` (release `dpn-certificate-manager`), `vault-https` (release `vault-https`), or `all` (`dpn-certificate-manager` first, then `vault-https`), retyping the same value in `confirm`. The workflow's checklist warns that rolling back `vault-https` can affect its TLS/unseal configuration and, if Vault was recently initialised, leave it inconsistent with Vault's own data. The legacy plain-HTTP `vault` release (`dpn-gha-vault-cd.yaml`) has no rollback workflow. Manually:

```bash
helm rollback dpn-certificate-manager <rollbackRevision> -n ns-dpn-01
helm rollback vault-https <rollbackRevision> -n ns-dpn-01
helm rollback vault <rollbackRevision> -n ns-dpn-01        # only if dpn-gha-vault-cd.yaml was used
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

Use the standard CD workflow for Strategy 1, and **DPN Rollback - File Scan Service** (`dpn-gha-file-scan-rollback.yaml` in `dpn-file-scan-service`, with `confirm: dpn-file-scan-service`) or manual Helm commands for Strategy 2, per [Rollback Strategy](#rollback-strategy) and [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component).

**Strategy 1 — re-run `dpn-gha-file-scan-cd.yaml` (DPN CD - File Scan Service) with an older `imageTag`.** To change only the image without a workflow run, the direct equivalent is:

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

Every sub-component (Kafka, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, OTel Collector, DPN Portal, oauth2-proxy) has its own CD workflow in `dpn-health-monitoring-service/.github/workflows/` (`dpn-gha-kafka-cd.yaml`, `dpn-gha-opensearch-cd.yaml`, etc.), but these are **`workflow_call`-only** — they can't be triggered standalone from the Actions tab, only invoked by the `dpn-gha-health-monitoring-cd-install.yaml` orchestrator.

> **Note:** `dpn-portal` — a tile landing page that links out to the observability UIs — has replaced the retired `nginx-observability` reverse proxy as the last component in this chain; it is fronted by its own `oauth2-proxy` gateway rather than acting as the reverse proxy itself. The `oauth2-proxy` gateways that used to front Kafka UI, Prometheus, and Thanos directly have also been retired: Kafka UI now uses native Keycloak OIDC login and is exposed on its own internal load balancer, and Prometheus/Thanos are no longer browsed directly (both are consumed through Perses).

**Strategy 1 — re-run the orchestrator:** go to **Actions → DPN Health Monitoring → Run workflow** (`dpn-gha-health-monitoring-cd-install.yaml`, `cloud: aws`). This redeploys the full dependency chain (Kafka → OpenSearch → Prometheus → Thanos, etc.) — the OTel Collector's `imageTag` (default `0.95.0`) and optional `otelImageRepository` are inputs, and DPN Portal likewise requires its own `portalImageTag` input (with `portalImageRepository`, default `1.0.1/dpn-portal`) since that chart ships no default image; other sub-components don't take an image tag from the orchestrator today, so an image-tag rollback for those means Strategy 2 instead.

**Strategy 2 — Helm revision rollback for the affected sub-component:** run **DPN Rollback - Health Monitoring** (`dpn-gha-rollback-health-monitoring.yaml`, `cloud: aws`, see [Rollback Workflows](#rollback-workflows)) with `releaseName` set to the component (`kafka`, `opensearch`, `prometheus`, `thanos`, `data-prepper`, `jaeger`, `perses`, `redis-ui`, `oauth2-osd`, `otel`, `portal`, `oauth2-jaeger`, `oauth2-perses`, `oauth2-portal`), or `all` to roll the whole stack back in reverse dependency order.

The manual equivalent for any sub-component:

The release names (set in each `dpn-gha-*-cd.yaml` workflow) are `dpn-kafka-stack`, `dpn-opensearch`, `dpn-prometheus`, `dpn-thanos`, `dpn-data-prepper`, `dpn-jaeger`, `dpn-perses`, `dpn-otel-collector-health`, `dpn-portal`, `dpn-oauth2-proxy-osd`, `dpn-oauth2-proxy-jaeger`, `dpn-oauth2-proxy-perses`, `dpn-oauth2-proxy-portal` and `dpn-redis-ui-health`.

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

## Part 5a — DPN Authentication Service Rollback

The Authentication Service is the single Helm release `dpn-keycloak` (Keycloak plus its bundled PostgreSQL), deployed by `dpn-gha-keycloak-cd.yaml` in `dpn-authentication-service`.

**Strategy 1 — standard CD workflow:** re-run `dpn-gha-keycloak-cd.yaml` (**DPN CD - Keycloak**) with an older `keycloakImageTag` (and `postgresImageTag`, if that changed).

**Strategy 2 — Helm revision rollback:** run **DPN Rollback - Keycloak** (`dpn-gha-keycloak-rollback.yaml`, see [Rollback Workflows](#rollback-workflows)) with `confirm: dpn-keycloak`, or manually:

```bash
helm history dpn-keycloak -n ns-dpn-01
helm rollback dpn-keycloak <rollbackRevision> -n ns-dpn-01
```

A rollback reverts the chart, values and templated configuration only. Realm and client configuration written by `configure-keycloak.sh` is not reverted, and the PostgreSQL PVC is not affected.

**Verification:**

```bash
kubectl get pods -n ns-dpn-01 -l app=dpn-keycloak
kubectl get pods -n ns-dpn-01 -l app=dpn-keycloak-postgres
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
