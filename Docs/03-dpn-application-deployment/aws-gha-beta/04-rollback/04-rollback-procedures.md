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
  - [Airflow Rollback](#airflow-rollback)
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

This document describes rollback and recovery procedures across **all DPN components**: Vault, Federator Certificate Manager, Federator Gateway, Data Pipeline (including Airflow), File Scanning Service, and Health Monitoring Service.

**The central deployment repository (`dpn-containerised-deployment-service`) has no rollback workflow for any component** — it has one CD workflow per component (or, for Health Monitoring, one orchestrator that chains the sub-component workflows), and that same workflow is what you re-run to roll forward or back. The one exception is the Data Pipeline Self-Service releases, which have their own rollback workflow in `dpn-data-pipelines` (see [Part 1](#part-1--dpn-data-pipeline-rollback)). This document generalises a two-mode approach (Helm revision vs. image tag) to every component via a mix of re-running the standard CD workflow and manual `helm rollback`/`helm upgrade` commands.

All rollback operations here work at the **Helm release / container image** layer. Every rollback pipeline reduces to the same two modes, regardless of component — see [Rollback Strategy](#rollback-strategy).

Because several DPN components depend on one another at runtime (certificates, message flow, shared storage), rolling back more than one component at a time is not order-independent — see [Rollback Sequence Across Components](#rollback-sequence-across-components) before acting on more than one Part below.

---

## Rollback Strategy

There are **two separate mechanisms**, not two modes of one workflow — this is the key distinction to get right:

| | Mechanism used | What you provide | What it does |
|---|------------------|----------------------|-------------------|
| **Strategy 1 — Image tag rollback** | The **same, standard CD workflow** used for every normal deployment (`Actions → Run workflow`) | A previous **image tag** | Runs exactly like any other deployment — a fresh `helm upgrade --install` — except pointed at an older, already-built image instead of the latest one |
| **Strategy 2 — Helm revision rollback** | A manual `helm rollback` command — only the Data Pipeline Self-Service releases have a dedicated rollback workflow | A **Helm revision number** | Runs `helm rollback <release> <revision>`, reverting the release — chart *and* values — to exactly how it was at that revision |

The distinction matters for what actually gets reverted:

- **Strategy 1** The standard CD workflow deploys whatever the environment/cluster values file currently defines, just with an older `imageTag` substituted in. If the *values* are also wrong (not just the image), Strategy 1 alone won't fix that — it'll faithfully redeploy the bad values with an old image.

- **Strategy 2 reverts everything about that revision** — chart version, values, and therefore whatever image tag was in use at that revision too. It doesn't let you pick an image tag independently of the revision; you get exactly what that revision was.

**On image tags:** components pull from GHCR (`ghcr.io/energy-dsi/...`) by default, so `imageTag` is typically a semantic version or a DSI-provided stable tag rather than a numeric build ID — check your registry's tag history (GHCR package page, or `aws ecr describe-images` if you push to your own ECR) for what's actually available before choosing one to roll back to.

---

## Rollback Workflow Availability by Component

| Component | Standard CD workflow (Strategy 1) | Dedicated rollback workflow (Strategy 2) | 
|-----------|--------------------------------------|-----------------------------------------------|
| DPN Data Pipeline (2.1.0 Self-Service: `dpn-self-service`, `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor`) | `dpn-self-service-cd.yaml` (in `dpn-data-pipelines`) | `dpn-self-service-rollback.yaml` (in `dpn-data-pipelines`) |
| Airflow (`dpn-airflow`) | `dpn-cd-airflow.yml` | None — manual `helm rollback` only |
| DPN Data Pipeline (legacy pre-2.1.0 releases) | `dpn-cd-data-pipelines.yml` | None — manual `helm rollback` only |
| DPN Federator Gateway | `dpn-federator-gateway-cd.yml` | None — manual `helm rollback` only |
| DPN Federator Certificate Manager | `dpn-certificate-manager-cd.yml` | None — manual `helm rollback` only |
| Vault (`vault-https`) | `dpn-vault-https-cd.yml` | None — manual `helm rollback` only |
| DPN REST Federator Gateway (`dpn-rest-federator`, `dpn-redis`) | `dpn-rest-federator-cd.yml` | None — manual `helm rollback` only |
| DPN Authentication Service (`dpn-keycloak`) | `dpn-keycloak-cd.yml` | None — manual `helm rollback` only |
| DPN File Scanning Service | `dpn-file-scan-cd.yml` | None — manual `helm rollback` only |
| DPN Health Monitoring Service | `dpn-health-monitoring-cd-install.yml` (orchestrator — the 10 per-component workflows are `workflow_call`-only and can't be triggered standalone) | None — manual `helm rollback` per sub-component release |

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

In the 2.1.0 Self-Service design the Data Pipeline is three Helm releases in `ns-dpn-dp-01` — `dpn-self-service`, `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` — deployed by `dpn-self-service-cd.yaml` in `dpn-data-pipelines` (see [Execute Data Pipeline CD Workflow](../03-installation/07-dpn-data-pipeline-installation-process.md#step-02c-execute-data-pipeline-cd-workflow)). Producer data products are created by the Self-Service UI as plain Deployments, not Helm releases, so there is nothing to roll back for them with Helm. Airflow (`dpn-airflow`) and any legacy pre-2.1.0 releases are covered at the end of this Part.

> **Note:** The AWS Self-Service workflows (`dpn-self-service-cd.yaml`, `dpn-self-service-rollback.yaml`) are not on the `develop` branch of `dpn-data-pipelines`. Restore them from the repository's git history (the commit before `Temporarily remove AWS GitHub Actions pipelines`).

### Strategy 1 — Redeploy a Previous Build via the Standard CD Workflow

Go to **Actions → DPN Self-Service — Deploy (AWS EKS) → Run workflow** (`dpn-self-service-cd.yaml`) — the same workflow used for every normal deployment, not a rollback-specific one — and set `imageTag` to a previous, known-good tag. All three releases are redeployed with that tag. See [Execute Data Pipeline CD Workflow](../03-installation/07-dpn-data-pipeline-installation-process.md#step-02c-execute-data-pipeline-cd-workflow) for the full list of inputs.

**Finding a previous tag:** the CI image tag is the CI run number. Check the GHCR package page for the image, or if pushing to your own ECR:

```bash
aws ecr describe-images --repository-name <image-name> --region <AWS_REGION> --query 'sort_by(imageDetails,& imagePushedAt)[*].imageTags'
```

### Strategy 2 — Helm Revision Rollback

**Workflow:** `dpn-data-pipelines` provides **DPN Self-Service — Rollback (AWS EKS)** (`.pipelines/github-actions-pipelines/aws-pipelines/cd-pipelines/dpn-self-service-rollback.yaml`). It rolls back one release at a time in `ns-dpn-dp-01`:

| Input | Value |
|-------|-------|
| `environment` | `dev` / `devtest` |
| `cluster` | `dpn01` / `dpn02` |
| `roleToAssume` | ARN of the IAM role assumed through GitHub OIDC |
| `release_name` | `dpn-self-service`, `dpn-consumer-file-extractor` or `dpn-consumer-topic-extractor` |
| `revision` | Revision to roll back to; leave blank for the previous stable revision |

The workflow lists the last five revisions, waits for approval on the GitHub Environment `dpn-self-service-<environment>`, runs a `--dry-run` and then `helm rollback <release_name> <revision> -n ns-dpn-dp-01 --wait --timeout 10m`.

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

### Airflow Rollback

Airflow is the Helm release `dpn-airflow` in `ns-dpn-01`, deployed by the central `dpn-cd-airflow.yml` workflow (**DPN CD - Airflow**). There is no rollback workflow.

- **Strategy 1:** re-run **DPN CD - Airflow** with older `airflowImageTag` (and, if needed, `postgresImageTag`/`redisImageTag`). Blank inputs fall back to the tags in the environment's values file.
- **Strategy 2:** `helm history dpn-airflow -n ns-dpn-01`, then `helm rollback dpn-airflow <rollbackRevision> -n ns-dpn-01`. The `dpn-airflow-init` Job has immutable fields; the CD workflow deletes it before every upgrade, so do the same before a manual rollback if it fails on that Job: `kubectl delete job dpn-airflow-init -n ns-dpn-01 --ignore-not-found`.

### Legacy Pre-2.1.0 Releases

Releases deployed before the Self-Service design by the central `dpn-cd-data-pipelines.yml` workflow (**DPN CD - Data Pipelines**) live in `ns-dpn-01` and are named `dpn-<configType>-<processType>-<base_name>-<schemaType>` for producers and `dpn-<configType>-<processType>-<base_name>` for consumers, where a `schema_mapper` folder becomes `mapper`. Roll them back by re-running that workflow with an older `imageTag` (Strategy 1), or with `helm rollback <release-name> <rollbackRevision> -n ns-dpn-01` (Strategy 2). Pre-2.1.0 data products are not imported into the Self-Service UI; to move one to the 2.1.0 design, recreate it in the UI.

---

## Part 2 — DPN Federator Gateway Rollback

**Strategy 1 — standard CD workflow (`dpn-federator-gateway-cd.yml`):** re-run with an older `imageTag`. Since this workflow deploys the entire `dpn-platform` release together (Zookeeper Source/Target, Kafka Source/Target, Kafka UI, Redis, Federator Server, Federator Client), redeploying an old tag rebuilds the whole platform release at that image version, not just one sub-component.

If only one sub-component's image needs to change, target it directly instead of using the platform-wide workflow:

```bash
kubectl set image deployment/dpn-federator-server-1 \
  dpn-federator-server-1=<ecr-url-or-ghcr>/dpn-federator-server:<imageTag> -n ns-dpn-01
kubectl rollout status deployment/dpn-federator-server-1 -n ns-dpn-01
```

**Strategy 2 — manual Helm revision rollback:**

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

**Strategy 2 — manual Helm revision rollback:**

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

There is no dedicated rollback workflow for the File Scanning Service — use the standard CD workflow for Strategy 1, and manual Helm commands for Strategy 2, per [Rollback Strategy](#rollback-strategy) and [Rollback Workflow Availability by Component](#rollback-workflow-availability-by-component).

**Strategy 1 — re-run `dpn-file-scan-cd.yml` (DPN CD - File Scan Service) with an older `imageTag`.** To change only the image without a workflow run, the direct equivalent is:

```bash
kubectl set image deployment/dpn-file-scan-service \
  dpn-file-scan-service=<ecr-url-or-ghcr>/dpn-file-scan-service:<imageTag> -n ns-dpn-01
kubectl rollout status deployment/dpn-file-scan-service -n ns-dpn-01
```

**Strategy 2 — manual Helm revision rollback:**

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

**Strategy 1 — re-run the orchestrator:** go to **Actions → DPN Health Monitoring → Run workflow**. This redeploys the full dependency chain (Kafka → OpenSearch → Prometheus → Thanos, etc.) — the OTel Collector's `imageTag` is an input, and DPN Portal likewise requires its own `portalImageRepository`/`portalImageTag` inputs since that chart ships no default image; other sub-components don't take an image tag from the orchestrator today, so an image-tag rollback for those means Strategy 2 instead.

**Strategy 2 — manual Helm revision rollback for the affected sub-component:**

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
