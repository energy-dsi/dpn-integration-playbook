Release : 2.1.0 - Oct 2026

# DPN Data Pipeline Configuration

---

## Table of Contents

- [Overview](#overview)
- [STEP-01: Configuration Table](#step-01-configuration-table)
- [STEP-02: Secrets Table](#step-02-secrets-table)
- [Review Notes](#review-notes)

---

## Overview

This guide lists **only what a participant organisation must set** to run the DPN Data Pipeline on Azure. Everything not listed here is preconfigured or handled by the platform and must be left at its default.

| Action | Where |
|--------|-------|
| **Required participant action:** update the values in the Configuration Table | [STEP-01](#step-01-configuration-table) |
| **Required participant action:** create the secrets in the Secrets Table | [STEP-02](#step-02-secrets-table) |

> **Informational (no action required):**
> - Pipeline images, registry and tag are set by the CI/CD pipelines.
> - Kafka connection and security (`SASL_SSL` with `OAUTHBEARER`), observability (OpenTelemetry), scheduling (`interval`) and autoscaling (off) are preconfigured; keep the defaults.
> - Storage containers and Kafka topics are created automatically by the pipeline. Their names must not already exist.
> - Files keep their original name in the target container.

---

## STEP-01: Configuration Table

Update **only** the values below in `values.yaml`, per environment.

### Organisation

| Parameter | Default | Set to |
|-----------|---------|--------|
| orgName | `example-org` | Your organisation name abbreviation, no spaces. **Required: the default must be changed** |

### Cloud provider

| Parameter | Default | Set to |
|-----------|---------|--------|
| DPN_CLOUD_PROVIDER | `azure` | **Fixed for Azure: do not change.** Set by the Self-Service UI deployment and inherited by every product. Shown here for reference; verify it is lowercase `azure` |

### Observability (all components)

OpenTelemetry settings are **preconfigured** and are not participant settings. Keep the defaults shown below. **Do not change them** unless your health monitoring deployment differs from the standard setup (for example, a collector in a different namespace or plaintext transport).

| Parameter | Default (do not change) | Change only if |
|-----------|-------------------------|----------------|
| OTEL_EXPORTER_OTLP_ENDPOINT | `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` | Your OTel collector runs at a different address. The port is `4318` when `OTEL_EXPORTER_OTLP_INSECURE` is `false`, and `4317` when it is `true` |
| OTEL_EXPORTER_OTLP_INSECURE | `false` | Plaintext transport is required. Change the endpoint port to `4317` at the same time |
| OTEL_OAUTH_DISABLED | `false` | Keep `false` in **all environments**. Setting it to `true` turns OAuth off, so the pipelines would no longer authenticate to the OTel collector |

For the Self-Service UI, the same parameters are named `DPN_OTEL_EXPORTER_OTLP_ENDPOINT`, `DPN_OTEL_EXPORTER_OTLP_INSECURE` and `DPN_OTEL_OAUTH_DISABLED`.

---

## STEP-02: Secrets Table

The secrets below are required in the data pipeline namespace (`ns-dpn-dp-01`) **before** you run the CD pipeline. The containers do not start without them.

> **Required: these secrets must exist in the `ns-dpn-01` namespace first.** Kubernetes secrets cannot be shared across namespaces, so the secrets are sourced from `ns-dpn-01` and copied into `ns-dpn-dp-01`. Follow this order for **each** secret in the table:
> 1. **Verify** it exists in `ns-dpn-01` (command below).
> 2. **If it exists**, **copy** it into `ns-dpn-dp-01` with the copy commands below.
> 3. **If it does not exist**, **create** it directly in `ns-dpn-dp-01`. `dpn-tls` and `dpn-keycloak-secrets` are platform-provided and must not be created by hand: if either is missing from `ns-dpn-01`, complete the DPN Certificate Manager / Authentication Service installation first.

| Secret | Keys | Value | Used by |
|--------|------|-------|---------|
| `producer-file-dp-secret` | `SRC_CONNECTION_STRING`, `TARGET_CONNECTION_STRING` | Blob Storage connection strings for the producer source and target storage accounts. The same value may be used for both | Self-Service UI and producer file products |
| `consumer-file-dp-secret` | `SRC_CONNECTION_STRING`, `TARGET_CONNECTION_STRING` | Blob Storage connection strings for the consumer source and target storage accounts. The same value may be used for both | Consumer file extractor |
| `dpn-tls` | `ca.crt`, `keystore.jks`, `truststore.jks` | Copy from `ns-dpn-01`. Do not change the contents | All pipeline containers (Kafka TLS trust) |
| `dpn-keycloak-secrets` | `KC_SERVICE_CLIENT_SECRET` | Copy from `ns-dpn-01`. Do not change the contents | All pipeline containers (Kafka OAuth) |

**Verify the secrets in `ns-dpn-01`:**

```bash
kubectl get secret dpn-tls dpn-keycloak-secrets producer-file-dp-secret consumer-file-dp-secret -n ns-dpn-01
```

Any secret reported as `NotFound` does not exist in `ns-dpn-01`; create it in `ns-dpn-dp-01` (storage secrets only, see below).

**Copy the secrets into `ns-dpn-dp-01`** (for each secret that exists in `ns-dpn-01`). Run each command below (PowerShell) for that secret:

```powershell
# dpn-tls
kubectl get secret dpn-tls -n ns-dpn-01 -o json | ConvertFrom-Json | ForEach-Object { @{apiVersion="v1";kind="Secret";type=$_.type;data=$_.data;metadata=@{name=$_.metadata.name;namespace="ns-dpn-dp-01"}} } | ConvertTo-Json -Depth 10 | kubectl apply -f -

# dpn-keycloak-secrets
kubectl get secret dpn-keycloak-secrets -n ns-dpn-01 -o json | ConvertFrom-Json | ForEach-Object { @{apiVersion="v1";kind="Secret";type=$_.type;data=$_.data;metadata=@{name=$_.metadata.name;namespace="ns-dpn-dp-01"}} } | ConvertTo-Json -Depth 10 | kubectl apply -f -

# producer-file-dp-secret
kubectl get secret producer-file-dp-secret -n ns-dpn-01 -o json | ConvertFrom-Json | ForEach-Object { @{apiVersion="v1";kind="Secret";type=$_.type;data=$_.data;metadata=@{name=$_.metadata.name;namespace="ns-dpn-dp-01"}} } | ConvertTo-Json -Depth 10 | kubectl apply -f -

# consumer-file-dp-secret
kubectl get secret consumer-file-dp-secret -n ns-dpn-01 -o json | ConvertFrom-Json | ForEach-Object { @{apiVersion="v1";kind="Secret";type=$_.type;data=$_.data;metadata=@{name=$_.metadata.name;namespace="ns-dpn-dp-01"}} } | ConvertTo-Json -Depth 10 | kubectl apply -f -
```

Repeat the copy for `dpn-tls` and `dpn-keycloak-secrets` whenever either is rotated in `ns-dpn-01`.

**Create the storage secrets (only if they do not exist in `ns-dpn-01`).** Connection string format: `https://<storage-account>.blob.core.windows.net/?<sas-token>`. The values must be **base64-encoded** before they are stored, because the container decodes them itself:

```bash
kubectl create secret generic producer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n '<source connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n '<target connection string>' | base64)" \
  -n ns-dpn-dp-01
```

Repeat with the name `consumer-file-dp-secret` and the consumer connection strings.

**Confirm the result:**

```bash
kubectl get secret dpn-tls dpn-keycloak-secrets producer-file-dp-secret consumer-file-dp-secret -n ns-dpn-dp-01
```

> **Informational (no action required):** The secrets `tls-auth-secret` and `dpn-health-ca` are provided by the DPN Certificate Manager and Health Monitoring services. Verify that they exist in `ns-dpn-dp-01`.

> **Note:** The topic pathway needs no storage secret.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 |
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 |
| Oct-2026 | DSI Assurance   | Draft  | V3.0.0 |
