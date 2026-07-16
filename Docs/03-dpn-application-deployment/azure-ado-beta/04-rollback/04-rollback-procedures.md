# DPN Rollback and Recovery Process

---

## Table of Contents

- [Overview](#overview)
- [Rollback Strategy](#rollback-strategy)
- [Rollback Pipeline Availability by Component](#rollback-pipeline-availability-by-component)
- [Pre-Rollback Checklist](#pre-rollback-checklist)
- [Part 1 — DPN Data Pipeline Rollback](#part-1--dpn-data-pipeline-rollback)
  - [Strategy 1 — Redeploy a Previous Build via the Standard CD Pipeline](#strategy-1--redeploy-a-previous-build-via-the-standard-cd-pipeline)
  - [Strategy 2 — Dedicated Rollback Pipeline (Helm Revision)](#strategy-2--dedicated-rollback-pipeline-helm-revision)
  - [Which Strategy to Use](#which-strategy-to-use)
  - [Verification](#verification)
- [Part 2 — DPN Federator Gateway Rollback](#part-2--dpn-federator-gateway-rollback)
- [Part 3 — DPN Federator Certificate Manager Rollback](#part-3--dpn-federator-certificate-manager-rollback)
- [Part 4 — DPN Health Monitoring Service Rollback](#part-4--dpn-health-monitoring-service-rollback)
- [Kafka Topic Recovery](#kafka-topic-recovery)
- [Post-Rollback Verification (All Components)](#post-rollback-verification-all-components)
- [Disaster Recovery Considerations](#disaster-recovery-considerations)
- [Config and Installation Guide Cross-References](#config-and-installation-guide-cross-references)
- [Review Notes](#review-notes)

---

## Overview

This document describes rollback and recovery procedures across **all DPN components**: Vault, Federator Certificate Manager, Federator Gateway, Data Pipeline, File Scanning Service, and Health Monitoring Service.

This document uses that pipeline as the concrete, technical reference for how DPN's rollback strategy actually works, then generalises the same two-mode approach (Helm revision vs. image tag) to every other component via manual `helm rollback`/`helm upgrade` commands, since no equivalent dedicated pipeline was found for them.

All rollback operations here work at the **Helm release / container image** layer. Every rollback pipeline reduces to the same two modes, regardless of component — see [Rollback Mechanisms](#rollback-strategy).

---

## Rollback Strategy

There are **two separate pipelines**, not two modes of one pipeline — this is the key distinction to get right:

| | Pipeline used | What you provide | What it does |
|---|------------------|----------------------|-------------------|
| **Strategy 1 — Image tag rollback** | The **same, standard CD pipeline** used for every normal deployment | A previous **image tag** (an Azure DevOps Build ID / build number) | Runs exactly like any other deployment — a fresh `helm upgrade --install` — except pointed at an older, already-built image instead of the latest one |
| **Strategy 2 — Helm revision rollback** | A **separate, dedicated rollback pipeline** | A **Helm revision number** | Runs `helm rollback <release> <revision>`, reverting the release — chart *and* values — to exactly how it was at that revision |

The distinction matters for what actually gets reverted:

- **Strategy 1** The standard CD pipeline deploys whatever `values.yaml` currently defines, just with an older `imageTag` substituted in. If the *values* are also wrong (not just the image), Strategy 1 alone won't fix that — it'll faithfully redeploy the bad values with an old image.

- **Strategy 2 reverts everything about that revision** — chart version, values, and therefore whatever image tag was in use at that revision too. It doesn't let you pick an image tag independently of the revision; you get exactly what that revision was.

**On image tags being build numbers:** every component's CI pipeline is assumed to tag images with a numeric Azure DevOps Build ID (e.g. `1042`), pushed to its registry — confirmed for the Data Pipeline. The `imageTag` value you type into Strategy 1 **is a build number**, not a semantic version or a date, unless/until a component has migrated to GHCR with fixed semantic-version tags (see [Config and Installation Guide Cross-References](#config-and-installation-guide-cross-references)).

---

## Rollback Pipeline Availability by Component

| Component | Standard CD pipeline (Strategy 1) | Dedicated rollback pipeline (Strategy 2) | Confidence |
|-----------|--------------------------------------|-----------------------------------------------|--------------|
| DPN Data Pipeline | `dsi-data-pipelines-cd.yaml` | `dsi-data-pipelines-rollback-cd.yaml` | 
| DPN Federator Gateway | `azure-dpn-cd.yaml` | `federator-gateway-rollback-cd.yaml` |
| DPN Federator Certificate Manager | `certificate-manager-cd.yaml` | `certificate-manager-rollback-cd.yaml`|

---

## Pre-Rollback Checklist

Before initiating any rollback:

1. Confirm the CI/CD pipeline currently running (if any) has stopped or completed — don't roll back into an in-progress deployment.
2. Decide which strategy applies: is the problem a bad **image build** (use Strategy 1) or a bad **configuration/values change** (use Strategy 2)? Using the wrong one either won't fix the actual problem or will revert more than intended.
3. For Strategy 1: identify the last known-good image tag/build number. For Strategy 2: identify the last known-good Helm revision number.
4. For the Data Pipeline specifically: confirm no active file ingestion is mid-flight, and that Kafka topics for the affected product are not actively being written to, where practical.
5. For Vault/Certificate Manager rollbacks: confirm you have a secure, offline copy of the certificate bundle before touching Vault contents.
6. Notify anyone actively using the affected component's dashboards/endpoints, especially for Health Monitoring Service, since a rollback there briefly interrupts telemetry collection platform-wide.

## Part 1 — DPN Data Pipeline Rollback

Both pipelines below were read directly from the `develop-rollback` branch of `dpn-data-pipelines`.

### Strategy 1 — Redeploy a Previous Build via the Standard CD Pipeline

This is `.pipelines/azure-pipelines/cd-pipelines/dsi-data-pipelines-cd.yaml` — the same pipeline used for every normal deployment, not a rollback-specific one.

| Parameter | Purpose | Values |
|-----------|---------|--------|
| `environment` | Target environment |`pdev`, `ptest`, `puat` |
| `configType` | Producer or consumer | `producer`, `consumer` |
| `processType` | Integration pathway | `file`, `topic` |
| `productType` | Product type name (producer only) | free text, default `default` |
| `schemaType` | Schema type (producer only) | free text, default `default` |
| `imageTag` | **Image Tag To Deploy** — the build number to roll back to | free text, **no default — must be supplied every run** |

To roll back: trigger this pipeline exactly as you would for a normal deployment, but set `imageTag` to a previous, known-good build number instead of the latest one. There is no separate "rollback mode" — the pipeline has a single `Deploy` stage that always runs `helm upgrade --install` against whatever `imageTag` you give it, whether that's the newest build or an older one.

**Finding a previous build number:**

```bash
az acr repository show-tags --name <acr-name> --repository <image-name> --orderby time_desc
```

Tags are Azure DevOps Build IDs — cross-reference against the CI pipeline's run history to confirm what a given build number actually corresponds to before choosing one.

### Strategy 2 — Dedicated Rollback Pipeline (Helm Revision)

This is the separate `.pipelines/azure-pipelines/cd-pipelines/dsi-data-pipelines-rollback-cd.yaml`.

| Parameter | Purpose | Values |
|-----------|---------|--------|
| `environment` / `cluster` / `ServiceConnection` / `configType` / `processType` / `productType` / `schemaType` | Same as Strategy 1 | Same as Strategy 1 |
| `rollbackRevision` | **Helm Revision** to roll back to | free text |

Release/image names are derived the same way as the standard pipeline: `{configType}-{processType}-{base_name}-{schemaType}` for producer, `{configType}-{processType}-{base_name}` for consumer, where a `schema_mapper` folder is remapped to `mapper` in the release name.

```bash
helm rollback $RELEASE_NAME <rollbackRevision> -n $NAMESPACE
```

The pipeline does not independently verify the revision number exists before attempting the rollback — `helm rollback` will simply fail if it doesn't. Check history first:

```bash
helm history <release-name> -n <namespace>
```

> **Note:** the pipeline file also contains a `rollbackMode`/`imageTag` code path in addition to the Helm-revision path described above. **Strategy 1 (the standard CD pipeline) is the intended, documented way to perform an image-tag-based rollback** — treat any image-tag capability inside the rollback pipeline itself as redundant with Strategy 1, not a third option, unless confirmed otherwise.

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

**Strategy 1 — standard CD pipeline (`azure-dpn-cd.yaml`):** re-run with an older `imageTag` (Build ID). Since this pipeline deploys the entire `dpn-platform` release together (Zookeeper Source/Target, Kafka Source/Target, Kafka UI, Redis, Federator Server, Federator Client), redeploying an old build number rebuilds the whole platform release at that image version, not just one sub-component.

If only one sub-component's image needs to change, target it directly instead of using the platform-wide pipeline:

```bash
kubectl set image deployment/federator-server \
  federator-server=<acr-url>/dpn-federator-server:<imageTag> -n <namespace>
kubectl rollout status deployment/federator-server -n <namespace>
```

**Strategy 2 — dedicated rollback pipeline:**

```bash
helm rollback dpn-platform <rollbackRevision> -n <namespace>
```

Reverts the entire combined release — every sub-component — to that revision at once. There's no partial Helm-revision rollback of just one sub-component within a shared release.

**Verification:**

```bash
kubectl get pods -n <namespace>
helm history dpn-platform -n <namespace>
```

---

## Part 3 — DPN Federator Certificate Manager Rollback

**Strategy 1 — standard CD pipeline (`certificate-manager-cd.yaml`):** re-run with an older `imageTag`.

**Strategy 2 — dedicated rollback pipeline:**

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

## Part 4 — DPN Health Monitoring Service Rollback

Every sub-component (`dpn-kafka-health`, `dpn-otel-collector`, OpenSearch, Prometheus, Thanos, Data Prepper, Jaeger, Perses, nginx-observability) has its own standard CD pipeline today (confirmed in code).

**Strategy 1 — standard CD pipeline for the affected sub-component:** re-run with an older `imageTag`.

**Strategy 2 — dedicated rollback pipeline for that sub-component:**

```bash
helm rollback <release-name> <rollbackRevision> -n ns-dpn-health-01
```

**Rollback order matters here**, mirroring the deployment dependency graph (`Init → Kafka → OpenSearch → Prometheus → Thanos → DataPrepper`/`Jaeger → Perses → OTel → NginxObservability`): if rolling back a component others depend on (e.g. Kafka), check whether dependent components also need attention afterward.

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
| Federator Certificate Manager / Vault | `kubectl -n <namespace> exec <pod-name> -- ls /tls` — confirm P12 keystore/truststore present |
| Data Pipeline / Federator Gateway | Kafka UI — confirm topics and message flow |
| Health Monitoring Service | `kubectl get hpa -n ns-dpn-health-01` — confirm the OTEL Collector's HPA is healthy post-rollback |

---

## Disaster Recovery Considerations

- Rebuild container images from the last stable tagged Git commit if no registry tag is usable.
- Reload the certificate bundle into Vault from a **secure offline copy** — without it, a corrupted Vault has no recovery path short of a new CSR to DSI DSM.
- Restore Kafka topics if data corruption occurred, understanding that Health Monitoring Service's current single-broker, non-persistent Kafka configuration may mean "restore" means "accept the data is gone."
- Restart CI/CD pipelines with corrected configuration once the root cause is fixed, not just the symptom rolled back.

Organisations should maintain:

- Versioned Helm charts with revision history retained (don't `helm uninstall`/reinstall routinely — this resets revision history to 1, losing Strategy 2 targets).
- Versioned container images in the registry with previous build tags preserved, not garbage-collected aggressively — Strategy 1 depends on old tags still being pullable.
- Tagged Git releases for all components.
- A securely stored copy of the certificate bundle outside the cluster.

---

## Config and Installation Guide Cross-References

- **Configuration Guide (`dpn-data-pipelines/config.md`)** documents `IMAGE_REGISTRY`/GHCR as the **target** registry state. This document reflects what the confirmed pipelines actually use today (`ACR_NAME`, per-environment ACR, build-number tags). If/when the GHCR migration lands, Strategy 1's `az acr repository show-tags` command becomes a GHCR equivalent, and tags become semantic versions rather than build numbers — for every component, not just Data Pipeline.
- **Each component's Installation Process** should link to this document from its own Troubleshooting section, and vice versa.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
