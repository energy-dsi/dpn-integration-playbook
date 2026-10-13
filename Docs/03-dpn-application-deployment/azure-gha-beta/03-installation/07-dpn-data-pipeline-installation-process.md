# DPN Data Pipeline Installation Process

---

## Table of Contents

- [Overview](#overview)
- [STEP-01: Installation Prerequisites](#step-01-installation-prerequisites)
  - [STEP-01a: Clone and Prepare Source Repositories](#step-01a-clone-and-prepare-source-repositories)
  - [STEP-01b: Prepare Infrastructure and Application Prerequisites](#step-01b-prepare-infrastructure-and-application-prerequisites)
  - [STEP-01c: Identify Pipeline Repository Structure](#step-01c-identify-pipeline-repository-structure)
  - [STEP-01d: Configure Environment Approval Gates](#step-01d-configure-environment-approval-gates)
- [STEP-02: Install DPN Data Pipeline](#step-02-install-dpn-data-pipeline)
  - [STEP-02a: Validate the Built Image](#step-02a-validate-the-built-image)
  - [STEP-02b: Execute Data Pipeline CD Workflow](#step-02b-execute-data-pipeline-cd-workflow)
  - [STEP-02c: Validate Data Pipeline CD Workflow](#step-02c-validate-data-pipeline-cd-workflow)
- [STEP-03: Create the First Data Product](#step-03-create-the-first-data-product)
- [STEP-04: Troubleshooting](#step-04-troubleshooting)
  - [Container Image Not Found](#container-image-not-found)
  - [Image Pull Failures](#image-pull-failures)
  - [Pods Not Starting](#pods-not-starting)
  - [Container CrashLoopBackOff](#container-crashloopbackoff)
  - [Self-Service UI Not Reachable or Login Fails](#self-service-ui-not-reachable-or-login-fails)
  - [Data Product Cannot Be Created](#data-product-cannot-be-created)
  - [HPA Not Scaling](#hpa-not-scaling)
  - [Kafka Topic and Authentication Issues](#kafka-topic-and-authentication-issues)
- [Review Notes](#review-notes)

---

## Overview

This document provides step-by-step instructions for installing and deploying the **DPN Data Pipeline component** using **GitHub Actions** workflows.

The deployment uses the following repository:

- https://github.com/energy-dsi/dpn-data-pipelines.git

The deployment process consists of:

- **Continuous Integration (CI)** — not part of this GitHub Actions-based deployment path (see [Common Configuration, Continuous Integration](../02-configuration/00-common-dpn-configuration.md#continuous-integration-ci)). The five container images are built and pushed to the GitHub Container Registry (GHCR) under `ghcr.io/energy-dsi/dsi/`:

  | Image | Purpose |
  |-------|---------|
  | `dpn-producer-file-adaptor-generic` | Generic producer image for the file pathway |
  | `dpn-producer-topic-adaptor-generic` | Generic producer image for the topic pathway |
  | `dpn-consumer-file-extractor` | Consumer file extractor |
  | `dpn-consumer-topic-extractor` | Consumer topic extractor |
  | `dpn-self-service` | DPN Self-Service UI |

  > **Registry discrepancy, unresolved as of this writing:** CI pushes all five images to GHCR, but the confirmed Azure consumer CD workflow (see [STEP-02b](#step-02b-execute-data-pipeline-cd-workflow)) pulls from this environment's own attached **ACR** instead, with its own image-naming scheme (`consumer-<type>-<base_name>`, no `dpn-` prefix). Whether images are mirrored from GHCR into ACR by a separate process, or the Azure consumer workflow is simply out of date, was not established — confirm with the platform team before assuming either registry is authoritative end-to-end.

- **Continuous Deployment (CD)** — deploys into **Azure Kubernetes Service (AKS)** using Helm:
  - the two **consumer pipelines** (one file extractor, one topic extractor), via the confirmed GitHub Actions workflow `dpn-cd-data-pipelines.yml`.

> **Self-Service UI deployment is not yet automated via GitHub Actions for Azure.** As of this writing, `dpn-data-pipelines` has a dedicated Self-Service CI/CD GitHub Actions pipeline for **AWS** (`aws-pipelines/cd-pipelines/dpn-self-service-cd.yaml`) and **GCP** (`gcp-pipelines/cd-pipelines/dpn-self-service-cd.yaml`), but no equivalent exists under `azure-pipelines/` in that repository. For Azure, the Self-Service UI is currently deployed via the **Azure DevOps pipeline** `dpn-self-service-cd.yaml` (`.pipelines/azure-pipelines/cd-pipelines/`) — see the equivalent installation step in [azure-ado-beta](../../azure-ado-beta/03-installation/07-dpn-data-pipeline-installation-process.md). Confirm with the platform team whether a GHA port of this workflow is planned; until then, treat this section as covering the consumer pipelines only, with the Self-Service UI deployed separately via ADO before continuing.

**Producer data products are not deployed by either workflow.** They are created at runtime from the already-running Self-Service UI, which launches the generic producer image with that product's configuration (see [STEP-03](#step-03-create-the-first-data-product) and the [Configuration Guide](../02-configuration/07-configure-dpn-data-pipelines.md#step-01-set-up-a-new-data-product-self-service)). No per-product CI/CD run, folder copy or image build is required.

> **Upgrading from a release before 2.1.0:** data products created before DPN release 2.1.0 (deployed as separate per-product producer/consumer Helm releases) are **not automatically imported** into the Self-Service UI. Each must be recreated (rehosted) manually through the UI after this installation (see [STEP-03](#step-03-create-the-first-data-product)), and the old releases removed afterwards as described in [Uninstall DPN Data Pipeline](../05-uninstall/05-uninstall-decommissioning.md#part-2--uninstall-dpn-data-pipeline).

---

## STEP-01: Installation Prerequisites

The following prerequisites must be completed before beginning the installation process.

### STEP-01a: Clone and Prepare Source Repositories

Clone the official repository from GitHub.

```bash
git clone https://github.com/energy-dsi/dpn-data-pipelines.git
```

Switch to the desired branch.

```bash
git checkout main
```

or

```bash
git checkout release/<version>
```

---

### STEP-01b: Prepare Infrastructure and Application Prerequisites

Ensure the following prerequisites are completed before deployment:

- AKS cluster provisioned and accessible, with the **metrics-server** add-on running (enabled by default on AKS)
- GitHub Actions OIDC federated credential for the Azure subscription configured, as used by every other CD workflow on this path (see [Continuous Deployment (CD)](../02-configuration/00-common-dpn-configuration.md#continuous-deployment-cd))
- DPN Streaming Service (Kafka) deployed, with SASL/TLS authentication through DPN Authentication Service (Keycloak) — see [Configure Kafka Security](../02-configuration/07-configure-dpn-data-pipelines.md#step-08b-configure-kafka-security-sasltls). Topics do **not** need to be pre-created; the pipeline creates them (see [DPN Streaming Service (Kafka)](../02-configuration/07-configure-dpn-data-pipelines.md#step-09b-configure-streaming-service-kafka))
- DPN Health Monitoring Service deployed and the OTEL collector container in a running state
- Storage accounts available for the `file` integration pathway. Blob containers are created by the pipeline — see [Storage Blob Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step-09a-storage-blob-configuration)
- The data pipeline namespace `ns-dpn-dp-01` created first, as part of the one-time cluster bootstrap in [AKS Namespace Configuration](../02-configuration/00-common-dpn-configuration.md#step23-aks-namespace-configuration). No workflow creates it. The shared secrets created in `ns-dpn-01` (`dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, `producer-file-dp-secret` and `consumer-file-dp-secret`) must then be copied into `ns-dpn-dp-01` as described in that step. `dpn-tls-cd.yaml` copies `dpn-tls` and `tls-auth-secret` automatically, but only if `ns-dpn-dp-01` already existed when it ran.
- The following Kubernetes secrets created **in the data pipeline namespace** (`ns-dpn-dp-01` by default) before the CD workflow runs. The containers refuse to start without valid values:

  | Secret | Purpose |
  |--------|---------|
  | `dpn-tls` | Kafka truststore (`truststore.jks`), mounted into pods |
  | `tls-auth-secret` | `TRUSTSTORE_PASSWORD` and `KEYSTORE_PASSWORD` |
  | `dpn-keycloak-secrets` | Keycloak client secret (`KC_SERVICE_CLIENT_SECRET`) |
  | `dpn-health-ca` | CA bundle for the OTEL collector's TLS listener |
  | `producer-file-dp-secret` | Blob Storage connection strings used by the Self-Service UI and the file producers |
  | `consumer-file-dp-secret` | Blob Storage connection strings for the consumer file extractor |
  | `ghcr-pull-secret` | Pull secret for the private GHCR registry |

  See [Secrets Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step-08-configure-secrets) for the contents of each. On the first deployment into a new environment, restart the pods once the secrets exist; see [One-time setup for a new environment](#one-time-setup-for-a-new-environment-create-secrets-and-restart-pods).
- Keycloak client `dpn-service-client` configured for the Self-Service UI login: **Standard flow** enabled, and the UI's `<externalUrl>/oauth2/callback` registered as a valid redirect URI. The realm roles `dpnadmin`, `dpnoperator` and `dpnreader` assigned to the people who will use the UI.
- Network and firewall rules applied as described in [Network and Ports Configuration](../02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration), including outbound access to `ghcr.io`
- Software prerequisites (GitHub Actions access, GHCR access)

[Refer to the **Prerequisites** and **Configuration** documentation for details](../01-prerequisites/01-dpn-prerequisites.md)

**Note:** Organisations must review the CI/CD workflow code for the following.

- If running your own CI, keep only the relevant build, unit test, and image-push steps — DSI's own CI examples include tool usage such as CheckMarx, SonarQube, and JFrog Xray that your organisation may not need
- The container image is appropriate and referred from the GHCR repository unless the organisation plans to use a separate image repository of its own
- There should not be any placeholder values left in `.pipelines/github-actions-pipelines/config/azure/<environment>-<cluster>.json` (for example `dev-dpn01.json`). The DSI package provides these to ensure configuration is modified by Organisations.
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- Both CI and CD are verified for the above prerequisites before execution

---

### STEP-01c: Identify Pipeline Repository Structure

The confirmed consumer-pipelines CD workflow lives at:

```text
root/
└── .pipelines/
    └── github-actions-pipelines/
        └── azure-pipelines/
            └── workflows/
                └── dpn-cd-data-pipelines.yml
```

> **Config file path is unconfirmed/inconsistent as of this writing.** The workflow's own `PARAMETERS_FILE` env var reads from `.github/config/<environment>-<cluster>.json` (no per-cloud subfolder, unlike the shared `.pipelines/github-actions-pipelines/config/azure/...` convention used by the other DPN components in `dpn-containerised-deployment-service`), but no `.github/config/` directory actually exists in this repository — the checked-in config JSON files instead live at `.pipelines/github-actions-pipelines/azure-pipelines/config/<environment>-<cluster>.json`. This looks like a real discrepancy between the workflow and the repo layout, not a documentation gap on our side — confirm the correct path with the platform team before running this workflow for the first time in a new environment.

---

### STEP-01d: Configure Environment Approval Gates

There is no ADO-style approval-check concept for GitHub Actions workflows by default. If you want a manual sign-off before running the CD workflow against a given environment, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

---

## STEP-02: Install DPN Data Pipeline

> **This step covers the two consumer pipelines only** (confirmed via the real `dpn-cd-data-pipelines.yml` workflow). The Self-Service UI must already be deployed separately — see the gap callout in the [Overview](#overview) — before [STEP-03](#step-03-create-the-first-data-product) can be exercised.
>
> **Discrepancies worth confirming with the platform/data-pipelines team before relying on this section:**
> - This workflow pulls consumer images from this environment's own **attached Azure Container Registry (ACR)** (`az acr login --name "$ACR_NAME"`, image reference `<acrName>.azurecr.io/dsi/consumer-<type>-<base_name>`), **not GHCR** — unlike the rest of this doc set, where GHCR is the shared default registry on every cloud. No `ghcr-pull-secret`/`imagePullSecrets` step appears in this workflow.
> - Its Helm-deploy logic loops over every chart directory under `blueprints/consumer/<processType>/*/charts`, and still contains explicit handling for a `schema_mapper` chart (renamed to a `mapper` release) — this suggests the consumer pathway on this specific Azure GHA workflow may not (yet) match the "single container, no separate mapper" simplified design described elsewhere in this document; the two may be out of sync.
> - Azure authentication in this workflow reads `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` directly from GitHub Actions secrets, not resolved from the environment/cluster config JSON the way `dpn-containerised-deployment-service`'s shared `cloud-login` composite action does it.

---

### STEP-02a: Validate the Built Image

Verify that the target ACR (or your organisation's chosen registry, if different from the default described above) contains the `consumer-file-*` / `consumer-topic-*` images with the expected image tag before running the CD workflow.

---

### STEP-02b: Execute Data Pipeline CD Workflow

Go to the following location and execute the data pipeline CD workflow (one run per pathway):

```text
root/
└── .pipelines/
    └── github-actions-pipelines/
        └── azure-pipelines/
            └── workflows/
                └── dpn-cd-data-pipelines.yml
```

Provide the following parameters:

| Input | Value |
|---|---|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `processType` | `file` or `topic` — run the workflow once per pathway you need deployed |
| `imageTag` | The image tag to deploy |

> **Notes:**
> - The namespace itself is not created by the workflow and must exist already (see [AKS Namespace Configuration](../02-configuration/00-common-dpn-configuration.md#step23-aks-namespace-configuration)).
> - Consumer scheduling defaults to `SCHEDULER_BACKEND: interval`. Confirm the value in the consumer charts' `values.yaml` before running (see [Configure Scheduling](../02-configuration/07-configure-dpn-data-pipelines.md#step-06-configure-scheduling)).

#### One-time setup for a new environment: create secrets and restart pods

Every time the DPN Data Pipeline is deployed into a **new environment** (a new `<environment>-<cluster>`, or a newly created `ns-dpn-dp-01`), do the following once:

1. Create the secrets in `ns-dpn-dp-01`. Copy the shared secrets from `ns-dpn-01` as described in [Copy shared secrets into ns-dpn-dp-01](../02-configuration/00-common-dpn-configuration.md#copy-shared-secrets-into-ns-dpn-dp-01-data-pipelines-prerequisite), and create the storage secrets as described in [Configure Storage Secrets](../02-configuration/07-configure-dpn-data-pipelines.md#step-08a-configure-storage-secrets). Confirm that every secret listed in [STEP-01b](#step-01b-prepare-infrastructure-and-application-prerequisites) exists:

   ```bash
   kubectl get secrets -n ns-dpn-dp-01
   ```

2. Restart the pods so they pick up the secrets. A pod reads secret values only when it starts, so pods created before the secrets existed stay in `CreateContainerConfigError` or `CrashLoopBackOff`, or run without the values, until they are restarted:

   ```bash
   kubectl rollout restart deployment -n ns-dpn-dp-01
   kubectl get pods -n ns-dpn-dp-01 -w
   ```

3. Once every pod shows `Running`, continue with [STEP-02c](#step-02c-validate-data-pipeline-cd-workflow).

This is needed only once per environment. Later CD runs into the same environment reuse the existing secrets. Repeat steps 1 and 2 only when a secret is rotated.

---

### STEP-02c: Validate Data Pipeline CD Workflow

Once the deployment has completed, the namespace should show the deployed consumer pathway's pod(s) running (the Self-Service UI, if already deployed via ADO per the Overview's gap callout, runs as its own separate workload and is not created by this workflow):

```bash
kubectl get pods -n <namespace>
```

Expected workloads (example for the `file` pathway):

```text
dpn-consumer-file-extractor-xxxxxxxx-xxxxx  1/1   Running
```

> If your consumer pathway still includes a `schema_mapper` chart per the discrepancy noted above, a `dpn-consumer-<type>-mapper-xxxxxxxx-xxxxx` pod will also appear — confirm against your actual deployed chart set rather than assuming it is absent.

If oauth2-proxy is enabled, its pod also shows `Running`. Check that the UI is exposed and that the rollout completed:

```bash
kubectl rollout status deployment/dpn-self-service -n <namespace>
kubectl get svc dpn-self-service-external -n <namespace>
```

Verify clean logs inside a container:

```bash
kubectl logs <pod-name> -n <namespace>
```

---

## STEP-03: Create the First Data Product

Producer data products are created from the Self-Service UI, not from a workflow.

1. Open the UI at the address reported in [STEP-02c](#step-02c-validate-data-pipeline-cd-workflow) and sign in with a user holding the `dpnadmin` or `dpnoperator` role.
2. Create a data product following [Set Up a New Data Product (Self-Service)](../02-configuration/07-configure-dpn-data-pipelines.md#step-01-set-up-a-new-data-product-self-service): choose the `product_type`, the `file` or `topic` pathway and the schedule, then review and confirm the proposed names.
3. Verify that a Deployment named `dpn-producer-<pathway>-<product_type>` is running:

   ```bash
   kubectl get deployments -n <namespace>
   ```

4. Use **Run Now** and the logs view in the UI to confirm a first cycle completes.

See the [DPN Data Pipeline UI Operations guide](../../../05-dpn-user-interfaces/11-dpn-data-pipeline-ui-operations.md) for the UI screens in detail.

> **Rehosting data products from a release before 2.1.0:** repeat steps 2–4 for every data product that existed before the upgrade. Pre-2.1.0 products (separate per-product producer/consumer Helm releases) are **not automatically imported** into the Self-Service UI and must be recreated manually. The UI only accepts storage container and Kafka topic names that do not exist yet, so confirm new names and update anything that used the old ones. Once each recreated product is verified, remove the old releases as described in [Uninstall DPN Data Pipeline](../05-uninstall/05-uninstall-decommissioning.md#part-2--uninstall-dpn-data-pipeline).

---

## STEP-04: Troubleshooting

### Container Image Not Found

Check that all five images were pushed to GHCR under the tag supplied to the CD workflow.

If the expected package or tag is not listed, rebuild and push the missing image before running the CD workflow.

---

### Image Pull Failures

If pods show `ImagePullBackOff` or `ErrImagePull`:

- If the image digest is private, confirm the `ghcr-pull-secret` referenced by the chart exists in the target namespace and contains a valid, non-expired GitHub PAT with `read:packages`.
- Confirm the AKS node pool has correct access to `ghcr.io` to pull the images.
- Confirm the image reference (`imageRegistry`/`imageName`/`imageTag`) matches an actual published tag — a typo here produces the same failure as a genuine access issue.
- For products created from the UI, confirm the Self-Service UI was deployed with the correct `env.DPN_IMAGE_REGISTRY`, `env.DPN_IMAGE_TAG` and `env.DPN_IMAGE_PULL_SECRET`, since it passes these to the producer pods it creates.

---

### Pods Not Starting

Check pod events to identify scheduling or image pull issues:

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Review the `Events` section at the bottom of the output. Common causes include insufficient node resources, a missing Secret that the pod references, or image pull errors.

---

### Container CrashLoopBackOff

A `CrashLoopBackOff` status means the container starts, crashes, and Kubernetes repeatedly attempts to restart it. Check the logs to identify the root cause:

```bash
kubectl logs <pod-name> -n <namespace>
```

Common causes:

- Invalid or missing environment variables — the container validates its configuration at start-up and reports the missing value. Check the Helm values for typographical errors or missing entries.
- Missing secrets or an incorrect connection string for Blob Storage — verify the required Kubernetes secrets exist with the correct names and values (the connection-string values must be base64-encoded; see [Configure Storage Secrets](../02-configuration/07-configure-dpn-data-pipelines.md#step-08a-configure-storage-secrets)).
- Missing Kafka truststore secret or wrong `TRUSTSTORE_PASSWORD` — a wrong password fails the container deliberately rather than falling back.
- The Self-Service UI's cloud provider is wrong (`DPN_CLOUD_PROVIDER` must be `azure` on AKS) — the UI's registry restore at start-up then uses the wrong storage API and the pod never becomes healthy.

---

### Self-Service UI Not Reachable or Login Fails

- Confirm `dpn-self-service-external` has an IP assigned (`kubectl get svc dpn-self-service-external -n <namespace>`).
- Confirm the Keycloak client `dpn-service-client` has **Standard flow** enabled and `<externalUrl>/oauth2/callback` registered as a valid redirect URI, plus the post-logout redirect URI and web origin.
- Confirm the user holds one of the realm roles `dpnadmin`, `dpnoperator` or `dpnreader`.
- A `401` on every request usually means the request bypassed oauth2-proxy (for example a `kubectl port-forward` straight to the pod). Access the UI through its external address.
- A `403` on an action means the user's role is not allowed: only `dpnadmin` and `dpnoperator` can create, start, stop and run products, and only `dpnadmin` can delete.

---

### Data Product Cannot Be Created

- **Name already exists** — every confirmed storage container and Kafka topic name must be new. The pre-check blocks creation if the name already exists in the storage account or on the broker. Choose a different name.
- **Invalid `product_type`** — use lowercase letters, digits and hyphens only, and keep the name short enough that `dpn-producer-<pathway>-<product_type>` stays within 63 characters.
- **Invalid container name** — storage container names must be 3–63 characters of lowercase letters, digits and single hyphens, starting and ending with a letter or digit.
- **Pre-check hangs or fails** — confirm the UI pod can reach the storage account and the Kafka broker, and that the platform storage secret (`producer-file-dp-secret`) is valid.

---

### HPA Not Scaling

HPA is disabled by default and should stay disabled while `SCHEDULER_BACKEND: interval` is in use (see [Configure HPA](../02-configuration/07-configure-dpn-data-pipelines.md#step-05-configure-horizontal-pod-autoscaler-hpa)).

If HPA has been enabled and `kubectl get hpa` shows `<unknown>` under `TARGETS`:

- Confirm metrics-server is running: `kubectl get deployment metrics-server -n kube-system`.
- Confirm the affected pods have CPU/memory `requests` set in their Deployment spec. HPA cannot compute a percentage without a request baseline.

If metrics are available but the replica count never changes, confirm `hpa.minReplicas`/`hpa.maxReplicas` allow room to scale, and that current load actually crosses the configured `hpa.scaleUp.cpuUtilization`/`hpa.scaleUp.memoryUtilization` thresholds.

---

### Kafka Topic and Authentication Issues

Verify Kafka topics using the Kafka UI:

```text
http://kafka-ui:8086
```

Check that:

- The topic exists in the expected Kafka cluster (source or target). Topics are normally created automatically when a product runs.
- The topic name in the configuration matches exactly (topic names are case-sensitive).
- There are no consumer group errors shown in the Kafka UI for the pipeline's consumer group(s).
- For the `topic` pathway, `srcGroupId` values are unique per product.
- A SASL `invalid_token` error means the Keycloak token endpoint URL points at the load-balancer hostname. It must use the plain `dpn-keycloak` ClusterIP service so that the token's issuer matches what the broker expects.
- A TLS handshake or truststore password error means `tls-auth-secret` has a wrong `TRUSTSTORE_PASSWORD`, or `dpn-tls` is missing `truststore.jks`.
- On the consumer topic extractor, messages missing `orgName` or `productType` headers are skipped by design.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Draft  | V2.0.0 |
