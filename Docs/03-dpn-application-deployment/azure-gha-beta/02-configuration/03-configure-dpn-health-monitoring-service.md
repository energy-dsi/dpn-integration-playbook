Release : 2.1.0 - Oct 2026

# DPN Health Monitoring Service Configuration Guide

---

## Table of Contents

- [Overview](#overview)
- [Continuous Deployment (CD)](#continuous-deployment-cd)
- [Step 1: Prepare Environment Configuration File](#step-1-prepare-environment-configuration-file)
- [Step 2: Prepare Secrets Configuration](#step-2-prepare-secrets-configuration)
- [Review Notes](#review-notes)

---

## Overview

The DPN Health Monitoring Service hosts the observability platform for DPN — Kafka, OpenSearch, an OpenTelemetry Collector, Prometheus+Thanos, Data Prepper, Jaeger, Perses, and the **DPN Portal** tile landing page. It is deployed in a separate namespace, `ns-dpn-health-01`, on Azure Kubernetes Service (AKS).

> **The Nginx observability proxy has been retired.** `dpn-nginx-observability` (basic-auth reverse proxy in front of OpenSearch/Jaeger/Perses/Kafka UI/Thanos) and its chart/CD workflow have been removed. Its role is now split between the **DPN Portal** (tile landing page, `charts/dpn-portal`) and one **`oauth2-proxy`** Keycloak-gateway release per UI — see [Step 2](#step-2-prepare-secrets-configuration) below.

---

## Continuous Deployment (CD)

Deployment is orchestrated by the `dpn-gha-health-monitoring-cd-install.yaml` GitHub Actions workflow (display name **DPN Health Monitoring**), which chains each sub-component's own CD workflow as a dependent job in this order: Kafka → OpenSearch → Prometheus → Thanos (with Data Prepper and Jaeger branching off Kafka+OpenSearch, Perses off Prometheus+Thanos) → OTel Collector → **DPN Portal** → **OAuth2 Proxy** (OpenSearch → Jaeger → Perses → Portal, chained sequentially) → Validate.

```text
root/
├── .github/
│   ├── actions/
│   │   └── cloud-login/action.yml                      # OIDC login + AKS kubeconfig, used by every component workflow
│   ├── config/
│   │   └── azure/<environment>-<cluster>.json
│   └── workflows/
│       ├── dpn-gha-health-monitoring-cd-install.yaml   # orchestrator — trigger this one
│       ├── dpn-gha-{kafka,opensearch,prometheus,thanos,data-prepper,jaeger,perses,otel,portal,oauth2-proxy}-cd.yaml
│       ├── dpn-gha-validate.yaml
│       ├── dpn-gha-rollback-health-monitoring.yaml
│       └── dpn-gha-uninstall-health-monitoring.yaml
└── charts/
    ├── {kafka-stack,opensearch,prometheus,thanos,data-prepper,jaeger,perses,otel-collector,dpn-portal,oauth2-proxy}/
    │   └── values/azure/<environment>-<cluster>.yaml
    └── oauth2-proxy-redis/                             # values.yaml only, no per-cluster file
```

The Helm charts live under `charts/<chart>`, and each component workflow uses the per-cluster values file `charts/<chart>/values/azure/<environment>-<cluster>.yaml`. On Azure, OpenSearch and Prometheus layer that file over shared base values (`charts/opensearch/opensearch-community-values.yaml`, `charts/prometheus/prometheus-community-values.yaml`); Thanos layers it over the chart's own `values.yaml`; and `oauth2-proxy` layers it over the per-UI `values-<component>.yaml`.

Trigger it via **Actions → DPN Health Monitoring → Run workflow**, supplying `environment` (dev/test), `cluster` (dpn01/dpn02), `cloud` (select `azure` — the input defaults to `aws`), `imageTag` (OTel Collector image tag, default `0.95.0`), and **`portalImageTag`** (the DPN Portal container image tag from GHCR — required, no default). `otelImageRepository` (the OTel Collector image path after `ghcr.io/energy-dsi/`) is optional — leave it blank to use the environment's configured repository. `portalImageRepository` (the GHCR path after `ghcr.io/energy-dsi/`) defaults to `dpn-portal` if left blank. The orchestrator's `init` job (**Resolve Deployment Config**) reads the rest of the component config from `.github/config/azure/<environment>-<cluster>.json` and passes it to every job.

**What the pipeline does automate:**

Each `oauth2-proxy` release's `SecretProviderClass` syncs the Keycloak client secret from **Azure Key Vault** into the namespace automatically on every run, using the cluster's user-assigned managed identity (`akv.keyvaultName`, `akv.tenantId` and `akv.userAssignedIdentityID` in `charts/oauth2-proxy/values/azure/<environment>-<cluster>.yaml`) — this is idempotent and requires no manual `kubectl create secret`. `dpn-gha-oauth2-proxy-cd.yaml` (**DPN CD - OAuth2 Proxy (Keycloak Gateway)**) also installs/updates the shared `dpn-redis-ui-health` session store (`charts/oauth2-proxy-redis`) on every run.

**What the pipeline does *not* automate:**

- The Keycloak `dpn-service-client` credential must already exist in Azure Key Vault (`KEY_VAULT_NAME` from the config JSON), as the secret `KC-SERVICE-CLIENT-SECRET` — the same secret `dpn-gha-keycloak-cd.yaml` (DPN Authentication Service) reads on its Azure deploy path; neither workflow creates it, so load it before deploying Keycloak (see [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md)).

- The `dpn-health-tls` Secret (a `kubernetes.io/tls` Secret holding `tls.crt`, `tls.key` and `ca.crt`) must already exist in `ns-dpn-health-01` — every `oauth2-proxy` release and the OTel Collector's TLS-enabled OTLP receivers consume it, and none of them create it.

- The Kubernetes Secret backing Thanos' long-term object storage (see [Step 1](#step-1-prepare-environment-configuration-file)) — no workflow creates it.

- A DPN Portal container image already built and pushed to GHCR, with its tag known ahead of triggering the workflow — this repository's pipeline deploys that image, it does not build it.

See the [installation guide](../03-installation/03-dpn-health-monitoring-service-installation-process.md) for the exact commands.

---

## Step 1: Prepare Environment Configuration File

Organisations should prepare a config file per environment/cluster where the health monitoring service is deployed, and keep it in the following location. This file will be read by the `init` job of the orchestrator workflow during deployment.

```text
root/
└── .github/
    └── config/
        └── azure/
            └── <environment>-<cluster>.json
```

This config file's keys are the same common ones described in [Step2.2: Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration) — this service has no health-monitoring-specific keys of its own in that JSON file. The namespace is fixed to `ns-dpn-health-01` by the orchestrator itself, regardless of the file's `NAMESPACE` value. Two things beyond the JSON file still need preparing per environment/cluster before deploying:

- **Thanos' long-term object storage.**

    `charts/prometheus/prometheus-community-values.yaml` (the shared Azure base values for Prometheus) points Thanos' sidecar at `objectStorageConfig.existingSecret.name: dpn-mon-storage-connection-string` — a Kubernetes Secret (key `objstore.yml`) that you must create yourself; no workflow creates it.

    As currently checked in, this chart uses a static `objstore.yml` blob (Azure Blob Storage connection details; `charts/thanos/objstore.yaml` shows the expected `type: AZURE` shape) rather than a workload-identity-scoped ServiceAccount + container name — confirm with your platform team which Blob Storage authentication method (static connection string inside `objstore.yml`, or workload identity) your organisation intends before relying on this, since no managed-identity annotation ships in this chart for Thanos itself.

- **The DPN Portal image.**

    The orchestrator's `portalImageTag` input (and optionally `portalImageRepository`, default `dpn-portal`) is supplied at trigger time, not read from the JSON config file — see [Continuous Deployment (CD)](#continuous-deployment-cd) above.

    **Image path convention.**

    This service's Azure values files for Perses, OTel Collector, Data Prepper, Jaeger, Thanos, and the Kafka/Zookeeper/Kafka UI images used by its Kafka stack reference the `ghcr.io/energy-dsi/<component>` path; the DPN Portal image defaults to `ghcr.io/energy-dsi/dpn-portal`. OpenSearch and Prometheus on Azure take their images from the shared community values instead (`opensearchproject/opensearch`, the kube-prometheus-stack chart defaults, and `quay.io/thanos/thanos` for the Thanos sidecar). See [Reference: Container Images Used](../03-installation/03-dpn-health-monitoring-service-installation-process.md#reference-container-images-used) in the installation guide.

---

**Environment-specific values in the Helm values files.** Set them in `charts/<chart>/values/azure/<environment>-<cluster>.yaml`:

| Key | Chart | Description | Example (placeholder) |
|-----|-------|-------------|-----------------------|
| `clusterName` and the `cluster` attribute `value` | `otel-collector` | AKS cluster name; the collector tags every metric, log and trace with it as the `cluster` attribute. Use the same value in both places | `aks-dpn-<env>-<region>` |
| `akv.keyvaultName` | `oauth2-proxy`, `opensearch` (`opensearchOidc.akv`), `kafka-stack` (`kafkaUi.…akv`) | Azure Key Vault the Secrets Store CSI driver reads the Keycloak client secrets from | `<key-vault-name>` |
| `akv.tenantId` | `oauth2-proxy`, `kafka-stack` | Microsoft Entra tenant ID of that Key Vault | `<tenant-id>` |
| `akv.userAssignedIdentityID` | `oauth2-proxy`, `kafka-stack` | Client ID of the user-assigned managed identity with Key Vault `get` on those secrets | `<managed-identity-client-id>` |
| `service.loadBalancerIP` | `oauth2-proxy`, `opensearch` | Static private IP of the internal LoadBalancer; an unused address in the AKS subnet. Each service needs its own address | `<private-ip-in-aks-subnet>` |
| `prometheusHealthUi.loadBalancerIP` | `prometheus` | Static private IP of the Prometheus UI internal LoadBalancer | `<private-ip-in-aks-subnet>` |
| `kafkaUi.service.loadBalancerIP` | `kafka-stack` | Static private IP of the Kafka UI internal LoadBalancer | `<private-ip-in-aks-subnet>` |
| `service.loadBalancerIP` (under the Thanos query block) | `thanos` | Static private IP of the Thanos Query internal LoadBalancer | `<private-ip-in-aks-subnet>` |
| `storage_account` | `thanos` (`objstore.yaml`) | Storage account holding the `thanos-metrics` container. This file is the content of the `objstore.yml` key in the `dpn-mon-storage-connection-string` Secret | `<storage-account-name>` |
| `storage_connection_string` | `thanos` (`objstore.yaml`) | Blob endpoint plus SAS token for that storage account. Treat it as a secret and never commit the real value | `BlobEndpoint=https://<storage-account-name>.blob.core.windows.net/;SharedAccessSignature=<sas-token>` |

---

## Step 2: Prepare Secrets Configuration

DPN Health Monitoring requires the following Kubernetes secrets/external secrets to be created for deployment. The `dpn-nginx-basic-auth` secret previously required here is **no longer needed** — the Nginx observability proxy it authenticated has been retired.

| secret-name | Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
| dpn-mon-storage-connection-string | Thanos long-term object storage config (`objstore.yml` key) | Kubernetes Secret, created manually — see [Step 1](#step-1-prepare-environment-configuration-file) |
| dpn-health-tls | `kubernetes.io/tls` cert/key/CA used by `oauth2-proxy` and the OTel Collector's TLS OTLP receivers | Kubernetes Secret, created manually (not created by this pipeline) |
| KC-SERVICE-CLIENT-SECRET | The `dpn-service-client` Keycloak client credential | Azure Key Vault secret, created manually (also read by `dpn-gha-keycloak-cd.yaml`'s Azure deploy path) — must exist before `dpn-gha-oauth2-proxy-cd.yaml` runs |

`dpn-gha-oauth2-proxy-cd.yaml` verifies this secret's presence in Key Vault, then relies on each release's `SecretProviderClass` to sync it into the namespace via the cluster's user-assigned managed identity — no manual `kubectl create secret` needed for that part.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| Oct-2026 | DSI Assurance | Final | V1.0.0 |
