# DPN Deployment Configuration Guide

---

## Table of Contents

- [Overview](#overview)
  - [Continuous Integration (CI)](#continuous-integration-ci)
  - [Continuous Deployment (CD)](#continuous-deployment-cd)

- [Global / Generic Configuration](#global--generic-configuration)
  - [Environment Configuration (pdev / ptest / puat)](#environment-configuration-pdev--ptest--puat)
  - [Environment-Specific Approval Gates](#environment-specific-approval-gates)
  - [Secrets Configuration](#secrets-configuration)
  - [Network and Ports Configuration](#network-and-ports-configuration)

- [Container Image Configuration](#container-image-configuration)

- [Deployment Pipeline Architecture](#deployment-pipeline-architecture)

- [OTEL Collector Configuration and Data Flow](#otel-collector-configuration-and-data-flow)

- [Horizontal Pod Autoscaler (HPA) Configuration](#horizontal-pod-autoscaler-hpa-configuration)

- [Verified Component Reference](#verified-component-reference)
  - [Kafka Sizing and Availability](#kafka-sizing-and-availability)
  - [OpenSearch Resource Sizing](#opensearch-resource-sizing)
  - [Thanos Long-Term Storage](#thanos-long-term-storage)
  - [Alerting Configuration](#alerting-configuration)

- [Dashboard Access Configuration](#dashboard-access-configuration)
- [Review Notes](#review-notes)

---

# Overview

The DPN Health Monitoring Service hosts the observability platform for DPN — an OTEL Collector plus signal-specific stacks for metrics, logs, and traces, plus a dashboard reverse proxy — deployed into `ns-dpn-health-01`.
---

## Continuous Deployment (CD)

**No CI pipeline exists on either branch.** Every component is a third-party Helm chart/image, or (for Kafka/Zookeeper) a custom rebuild whose build step lives outside this repository. Deployment is orchestrated by `monitoring-master-cd.yaml`, calling each component's own CD template as a dependent stage.
---

# Global / Generic Configuration

## DSI DSM Endpoint Configuration

DSI provides predefined endpoints to support the following environments:

- Development
- Integration Testing
- Pre-Production
- Production

These endpoints are publicly accessible to simplify integration and testing. Organisations must configure their pipelines to use the **appropriate endpoint for the corresponding deployment environment** as provided by DSI.

| Environment | Component | URL |
|-------------|-----------|-----|
| Pre Production-Dev | Authentication | https://auth-mtls.dsm01.dsipreprod1.neso.energy |
| Pre Production-Dev | Management Node | https://management.dsm01.dsipreprod1.neso.energy |
| Pre Production-Dev | DSI DPN Producer | https://producer.dpn01.dsipreprod1.neso.energy |
| Pre Production-Test | Authentication | https://auth-mtls.dsm01.dsipreprod2.neso.energy |
| Pre Production-Test | Management Node | https://management.dsm01.dsipreprod2.neso.energy |
| Pre Production-Test | DSI DPN Producer | https://producer.dpn01.dsipreprod2.neso.energy |
| Pre-Production-Uat | Authentication | https://auth-mtls.dsm01.dsipreprod3.neso.energy |
| Pre-Production-Uat | Management Node | https://management.dsm01.dsipreprod3.neso.energy |
| Pre-Production-Uat | DSI DPN Producer | https://producer.dpn01.dsipreprod3.neso.energy |

---

## Environment-Specific Approval Gates

Both branches use the same underlying mechanism: every per-component CD template binds its `deployment:` job to `environment: ${{ parameters.approval_group }}`, defaulting to (and currently only offering) `dsi-ppd` — identical across every environment on both branches. No environment differentiation exists in either branch today. Recommended, adopting `pdev`/`ptest`/`puat` as a graduated sequence:

| Environment | Recommended `approval_group` | Approval Required | Approvers |
|-------------|-------------------------------|---------------------|-----------|
| `pdev` | `dsi-pdev` (new) | None or single lightweight approver | — |
| `ptest` | `dsi-ptest` (new) | Single approver | Test/QA lead |
| `puat` | `dsi-ppd` (existing) | Two approvers | Platform lead + Security representative |

Requires extending the `approval_group` parameter's `values:` list on all nine CD templates and creating the new Azure DevOps Environment resources.

## Secrets Configuration

- Dashboard access is HTTP Basic Auth via a `dpn-nginx-basic-auth` Secret. The chart's own default (`basicAuth.createSecret: false`) and inline comment both say this Secret must be created manually, never via the chart has the actual `.htpasswd` file committed to git**, contradicting that intent. Treat this as applicable regardless of which branch's pipeline logic is in use, since it's the same chart and the same file.
- `config/.env.example`  documents the alerting credential set — see [Alerting Configuration](#alerting-configuration).
- `charts/thanos/thanos-objstore-config.yaml` is a template for the Thanos long-term storage Secret — see [Thanos Long-Term Storage](#thanos-long-term-storage).

## Network and Ports Configuration

| Source | Destination | Protocol | Port(s) | Traffic Flow |
|--------|-------------|----------|---------|---------------|
| Every DPN component | OTEL Collector Service `dpn-otel-collector` (`ns-dpn-health-01`) | OTLP/gRPC, OTLP/HTTP | 4317, 4318 | Inbound to this service |
| OTEL Collector | Kafka (`dpn-kafka-health.ns-dpn-health-01.svc.cluster.local:9092`) | Kafka protocol | 9092 | Outbound — `otel-metrics`, `otel-logs`, `otel-traces` topics (see corrected data flow below) |
| OTEL Collector | `/healthz` on port 13133 | HTTP | 13133 | Liveness/readiness probe target — must be present or the collector CrashLoops |
| DPN Admin | nginx-observability reverse proxy | HTTPS + Basic Auth | 443 | Inbound (dashboard access) |
| AKS node pool | Docker Hub, Quay.io, environment-specific ACR | TLS | 443 | Outbound — see [Container Image Configuration](#container-image-configuration) |

---

# Container Image Configuration

Image sourcing is identical between branches (same upstream images, same versions) — only the registry hostname for Kafka/Zookeeper varies, now per-environment using the `pdev`/`ptest`/`puat` ACR names from the table above.

| Component | Source | Version |
|-----------|--------|---------|
| OTEL Collector | `otel/opentelemetry-collector-contrib` (Docker Hub) | `0.95.0` |
| Kafka / Zookeeper | `{ACR_NAME}.azurecr.io/dpn-kafka` / `dpn-zookeeper` — e.g. `acrdpnpuatppduks01.azurecr.io` on `puat` | `7.5.3` |
| Kafka UI | `provectuslabs/kafka-ui` (Docker Hub) | **`latest`** — unpinned, confirmed on both branches |
| OpenSearch / Dashboards | `opensearchproject/opensearch{,-dashboards}` (Docker Hub) | `2.11.0` (Chart `appVersion: 3.7.0`) |
| Data Prepper | `opensearchproject/data-prepper` (Docker Hub) | `2.6.0` |
| Jaeger Query / Ingester | `jaegertracing/jaeger-{query,ingester}` (Docker Hub) | `1.57.0` (Collector present but **disabled** — see [OTEL Collector Configuration and Data Flow](#otel-collector-configuration-and-data-flow)) |
| Prometheus / Alertmanager / kube-state-metrics | Via `kube-prometheus-stack` chart | Chart-resolved, unpinned in this repo on either branch |
| Thanos | `thanosio/thanos` (query) / `quay.io/thanos/thanos` (sidecar) — two sources, same version | `v0.34.0` |
| Perses | `persesdev/perses` (Docker Hub) | `0.53.1` |
| Nginx | `nginx` (Docker Hub) | `1.27-alpine` |
| curl (init containers) | `curlimages/curl` (Docker Hub) — two different tags across two files | `8.6.0` / `8.8.0` inconsistent |

---

# Deployment Pipeline Architecture

11-stage `monitoring-master-cd.yaml` structure is adopted as-is: `Init → Kafka → OpenSearch → Prometheus → Thanos → DataPrepper`/`Jaeger` (parallel) `→ Perses → OTel → NginxObservability → Validate`, with the same defensive per-component CD pattern (pre-flight existence checks, `helm template` + grep for expected/forbidden resource names before deploying, `helm upgrade --install --wait`, per-Deployment rollout status, final service-existence validation stage). Only the `environment`/`cluster` parameter *values* change per [Reconciling the Two Branches' Environment Models](#reconciling-the-two-branches-environment-models) — the stage graph and per-template logic are unchanged.

---

# Horizontal Pod Autoscaler (HPA) Configuration

Only the OTEL Collector has an `hpa.yaml` template: `autoscaling.enabled: true`, `minReplicas: 1`, `maxReplicas: 10`, `targetCPUUtilizationPercentage: 70`, `targetMemoryUtilizationPercentage: 80`. No other component has one on either branch. Recommend extending the same template to Jaeger Query/Ingester, OpenSearch Dashboards, Perses, and nginx-observability — all stateless. Do not add HPA to Kafka/Zookeeper, OpenSearch data nodes, or Prometheus/Thanos.

---

# Verified Component Reference

Per-component resource/replica/storage figures are identical across both branches' shared chart defaults (only the OTEL Collector's environment-override `replicaCount` differs, noted above).

| Component | Replicas | CPU req / limit | Memory req / limit | Storage | Service type |
|-----------|----------|-------------------|------------------------|---------|----------------|
| Zookeeper | 1 | 100m / 500m | 256Mi / 512Mi | None (emptyDir) | ClusterIP |
| Kafka | 1 (single broker) | 500m / 1500m | 1Gi / 2Gi | **`persistence.enabled: false` — confirmed on both `dev` and `puat`** | ClusterIP |
| Kafka UI | 1 | — | — | — | LoadBalancer (internal) |
| OpenSearch | 3 | 1000m | **100Mi** — see below | 8Gi per node | ClusterIP (StatefulSet) |
| Data Prepper | 1 | 250m / 1000m | 512Mi / 1Gi | None | ClusterIP |
| Jaeger Query | 1 | chart default | — | None | ClusterIP only, via nginx |
| Jaeger Ingester | 1 | chart default | — | None | ClusterIP |
| Jaeger Collector | **0 — disabled** | — | — | — | — |
| Prometheus | 1 | 1000m / 4000m | 4Gi / 8Gi | 100Gi | ClusterIP |
| Alertmanager | 1 | 100m / 500m | 128Mi / 512Mi | 10Gi | ClusterIP |
| Thanos Query | 1 | 100m / 500m | 256Mi / 512Mi | None | LoadBalancer (internal) |
| Perses | 1 | 100m / 500m | 256Mi / 512Mi | 8Gi, `managed-premium` | LoadBalancer (internal) |
| nginx-observability | 1 | 50m / 250m | 64Mi / 256Mi | None | LoadBalancer (internal) |
| OTEL Collector | 1 (`pdev`/`ptest`) or 3 (`puat`) baseline, 1–10 via HPA | 200m / 1000m | 256Mi / 1Gi | None | ClusterIP |

**Confirmed pattern across every component:** no ingress controller anywhere — every user/admin-facing service is a plain `LoadBalancer` Service with the internal Azure LB annotation.

## Kafka Sizing and Availability

Single-broker, non-replicated, non-persistent Kafka sits in the critical path for **every** observability signal (per the corrected data flow above), confirmed unchanged on `puat` — the highest-tier environment among the three being adopted here. A Kafka pod restart loses anything unconsumed at that moment, platform-wide. Confirm whether this is acceptable for `puat` sign-off specifically, given UAT is meant to validate near-production behaviour.

## OpenSearch Resource Sizing

`resources.memory: 100Mi` across 3 replicas is unusually low for OpenSearch and a likely OOM/CrashLoop cause if not deliberate.

## Thanos Long-Term Storage

`charts/thanos/thanos-objstore-config.yaml`: **Azure Blob Storage**, container `thanos-metrics`. The checked-in file only has a `dev`-environment placeholder storage account name — the real `pdev`/`ptest`/`puat` storage account names and keys need to be supplied per environment before this Secret template is usable as-is.

## Alerting Configuration

`config/.env.example`:

| Variable | Purpose |
|----------|---------|
| `ALERT_EMAIL` | OpenSearch alerting failure notification recipient |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_FROM` | SMTP relay for alert emails |
| `SMTP_USER` / `SMTP_PASS` | Optional SMTP auth |
| `ALERT_SEVERITIES` | Comma-separated severities that trigger an alert (default `ERROR,FATAL`) |

OpenSearch's alerting monitor supports only a single destination — multiple recipients need a mailing list or comma-separated address understood by the mail system, not multiple `ALERT_EMAIL` lines.

---

# Dashboard Access Configuration

HTTP Basic Auth via nginx, `dpn-nginx-basic-auth` Secret, intended to be created manually (`basicAuth.createSecret: false` by default, with an explanatory comment in the chart). See the critical finding immediately below for why this intent is currently not being honoured.

---

## Secrets Configuration (Global)

Sensitive credentials must **not be stored in source code repositories**. They must be stored securely in one of the following vaults:

- **HashiCorp Vault** — provided with the DSI DPN package
- **Azure Key Vault** — cloud-specific option for organisations using Azure

| Category | Purpose |
|----------|---------|
| nginx-auth-proxy credentials/OIDC client config | Authenticates DPN Admin access to the dashboards |
| Prometheus/OpenSearch Alert Management webhook & email credentials | Used to send alert notifications |
| Azure Application Insight / Log Analytics / Sentinel credentials | Only required once the WIP Sentinel integration is implemented |

---

## Network and Ports Configuration

This section describes DPN connectivity requirements for ports and protocols, including agent pool requirements for building DPN code.

| Source | Destination | Protocol | Port(s) | Traffic Flow |
|--------|-------------|----------|---------|---------------|
| CI/mirroring agent | Docker Hub, Quay.io, `registry.k8s.io`, GitHub Container Registry, and other origin registries per [Container Image Configuration](#container-image-configuration) | TLS | 443 | Outbound (mirroring only, not a runtime AKS dependency) |
| AKS node pool | `ghcr.io` (pull every stack image) | TLS | 443 | Outbound |
| Every DPN component | OTEL Collector (`ns-dpn-health-01`) | OTLP/gRPC | 4317 | Inbound to this service |
| OTEL Collector | Kafka (`otel-metrics` topic) | Kafka protocol | 9092 | Outbound (metrics) |
| DPN Admin | nginx-auth-proxy | HTTPS | 443 | Inbound (dashboard access) |

> Unlike a mixed repository, **AKS nodes never need to reach any origin third-party registry directly** for this service — GHCR is the single runtime pull source, matching the current inventory's mirror-everything approach.

---

# Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
