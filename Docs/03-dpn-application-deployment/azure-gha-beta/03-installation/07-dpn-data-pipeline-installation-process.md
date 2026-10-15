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

- **Continuous Integration (CI)** — not part of this GitHub Actions-based deployment path (see [Common Configuration, Continuous Integration](../02-configuration/00-common-dpn-configuration.md#continuous-integration-ci)). The five container images are built and pushed to the GitHub Container Registry (GHCR) under `ghcr.io/energy-dsi`:

  | Image | Purpose |
  |-------|---------|
  | `dpn-producer-file-adaptor-generic` | Generic producer image for the file pathway |
  | `dpn-producer-topic-adaptor-generic` | Generic producer image for the topic pathway |
  | `dpn-consumer-file-extractor` | Consumer file extractor |
  | `dpn-consumer-topic-extractor` | Consumer topic extractor |
  | `dpn-self-service` | DPN Self-Service UI |

  > **Registry on Azure:** the Azure config JSON (`.github/config/azure/<environment>-<cluster>.json`) has no `IMAGE_REGISTRY` key and no Azure values files are checked in for these charts, so the CD workflow does not set an image registry on Azure by default. See the known limitation in [STEP-02b](#step-02b-execute-data-pipeline-cd-workflow) before running it.

- **Continuous Deployment (CD)** — deploys into **Azure Kubernetes Service (AKS)** with the **`DPN CD - Self-Service Data Pipelines`** workflow (`dpn-gha-self-service-cd.yaml`, `cloud: azure`), which installs three Helm releases into `ns-dpn-dp-01`:
  - `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` — the two fixed consumer pipelines
  - `dpn-self-service` — the DPN Self-Service UI

**Producer data products are not deployed by a workflow.** They are created at runtime from the Self-Service UI, which launches the generic producer image with that product's configuration (see [STEP-03](#step-03-create-the-first-data-product) and the [DPN Data Pipeline UI Operations guide](../../../05-dpn-user-interfaces/11-dpn-data-pipeline-ui-operations.md)). No per-product CI/CD run, folder copy or image build is required.

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
- GitHub Actions OIDC federated credential for the Azure subscription configured, as used by every other CD workflow on this path (see [Continuous Deployment (CD)](../02-configuration/00-common-dpn-configuration.md#continuous-deployment-cd)). The workflows read `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` from GitHub repository or Environment secrets
- DPN Streaming Service (Kafka) deployed, with SASL/TLS authentication through DPN Authentication Service (Keycloak). Topics do **not** need to be pre-created; the pipeline creates them (see the [Configuration Guide overview](../02-configuration/07-configure-dpn-data-pipelines.md#overview))
- DPN Health Monitoring Service deployed and the OTEL collector container in a running state
- Storage accounts available for the `file` integration pathway. Blob containers are created by the pipeline — see the [Configuration Guide overview](../02-configuration/07-configure-dpn-data-pipelines.md#overview)
- The data pipeline namespace `ns-dpn-dp-01` created first, as part of the one-time cluster bootstrap in [AKS Namespace Configuration](../02-configuration/00-common-dpn-configuration.md#step23-aks-namespace-configuration). No workflow creates it. The shared secrets created in `ns-dpn-01` (`dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, `producer-file-dp-secret` and `consumer-file-dp-secret`) must then be copied into `ns-dpn-dp-01` as described in that step. `dpn-gha-tls-cd.yml` copies `dpn-tls` and `tls-auth-secret` automatically, but only if `ns-dpn-dp-01` already existed when it ran.
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

  See the [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table) for the contents of each. On the first deployment into a new environment, restart the pods once the secrets exist; see [One-time setup for a new environment](#one-time-setup-for-a-new-environment-create-secrets-and-restart-pods).
- Keycloak client `dpn-service-client` configured for the Self-Service UI login: **Standard flow** enabled, and the UI's `<externalUrl>/oauth2/callback` registered as a valid redirect URI. The realm roles `dpnadmin`, `dpnoperator` and `dpnreader` assigned to the people who will use the UI.
- Network and firewall rules applied as described in [Network and Ports Configuration](../02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration), including outbound access to `ghcr.io`
- Software prerequisites (GitHub Actions access, GHCR access)

[Refer to the **Prerequisites** and **Configuration** documentation for details](../01-prerequisites/01-dpn-prerequisites.md)

**Note:** Organisations must review the CI/CD workflow code for the following.

- If running your own CI, keep only the relevant build, unit test, and image-push steps — DSI's own CI examples include tool usage such as CheckMarx, SonarQube, and JFrog Xray that your organisation may not need
- The container image is appropriate and referred from the GHCR repository unless the organisation plans to use a separate image repository of its own
- There should not be any placeholder values left in `.github/config/azure/<environment>-<cluster>.json` (for example `dev-dpn01.json`). The DSI package provides these to ensure configuration is modified by Organisations.
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- Both CI and CD are verified for the above prerequisites before execution

---

### STEP-01c: Identify Pipeline Repository Structure

All CD workflows, their per-cloud configuration and the charts they deploy live in the `dpn-data-pipelines` repository itself:

```text
dpn-data-pipelines/
├── .github/
│   ├── workflows/
│   │   ├── dpn-gha-self-service-cd.yaml          <- DPN CD - Self-Service Data Pipelines (standard path)
│   │   ├── dpn-gha-self-service-rollback.yaml    <- DPN Rollback - Self-Service Data Pipelines
│   │   ├── dpn-gha-self-service-uninstall.yaml   <- DPN Uninstall - Self-Service Data Pipelines
│   │   ├── dpn-gha-data-pipelines-cd.yaml        <- DPN CD - Data Pipelines (single reference chart per run)
│   │   ├── dpn-gha-data-pipelines-rollback.yaml  <- DPN Rollback - Data Pipelines
│   │   └── dpn-gha-data-pipelines-uninstall.yaml <- DPN Uninstall - Data Pipelines
│   ├── actions/
│   │   └── cloud-login/action.yml
│   └── config/
│       └── azure/<environment>-<cluster>.json
├── blueprints/{producer,consumer}/{file,topic}/{adaptor|extractor}/charts/values.yaml
└── service/charts/values.yaml
```

Each workflow reads `.github/config/azure/<environment>-<cluster>.json` and logs in through the repository's `.github/actions/cloud-login` action with `cloud: azure`, which uses `ARM_SUBSCRIPTION_ID`, `RESOURCE_GROUP` and `AKS_CLUSTER` from that file to get the AKS context. `dpn-gha-self-service-cd.yaml` also uses the optional `OAUTH2_PROXY_EXTERNAL_URL`.

All workflows run on a self-hosted runner with the labels `[self-hosted, vmss]` (register a runner with those labels, or change `runs-on` to a runner pool you control) and use the GitHub Environment `<environment>-<cluster>` (for example `test-dpn01`), which must exist in the repository.

---

### STEP-01d: Configure Environment Approval Gates

There is no ADO-style approval-check concept for GitHub Actions workflows by default. If you want a manual sign-off before running the CD workflow against a given environment, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

---

## STEP-02: Install DPN Data Pipeline

> **This step deploys the two consumer pipelines and the Self-Service UI** with `dpn-gha-self-service-cd.yaml`. Producer data products are then created from the UI in [STEP-03](#step-03-create-the-first-data-product).

---

### STEP-02a: Validate the Built Image

Verify that the image registry the charts will pull from contains `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor`, `dpn-self-service` and the two generic producer images with the expected image tag before running the CD workflow.

---

### STEP-02b: Execute Data Pipeline CD Workflow

Go to **Actions → DPN CD - Self-Service Data Pipelines → Run workflow** (`.github/workflows/dpn-gha-self-service-cd.yaml`), and supply:

| Input | Value |
|---|---|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02` (default `dpn01`) |
| `cloud` | `azure` (the default is `aws`, so change it) |
| `imageTag` | The image tag to deploy |

In one run it:

1. Verifies the `ns-dpn-dp-01` namespace exists.
2. Installs `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` from `blueprints/consumer/{file,topic}/extractor/charts`, applying `values/azure/<environment>-<cluster>.yaml` only if the chart ships one (otherwise the chart defaults are used), setting `imageName` to the release name, `imageTag` to the input and `cloudProviderType` to `azure`.
3. Installs `dpn-self-service` from `service/charts` the same way, with `env.DPN_CLOUD_PROVIDER` and `loadBalancer.cloud` set to `azure` and `env.DPN_IMAGE_TAG` set to the input. The oauth2-proxy (Keycloak login, HTTPS) is enabled with `oauth2Proxy.externalUrl` set to the config JSON's `OAUTH2_PROXY_EXTERNAL_URL`, or else to the address of the existing `dpn-self-service-external` LoadBalancer. On a first deploy with neither, it installs once with the proxy off, waits up to 3 minutes for an IP, then redeploys with the proxy on — register `<that URL>/oauth2/callback` on `dpn-service-client` afterwards (the workflow prints a warning with the URL).

> **Known limitation on Azure:** `service/charts/values/` contains only an `aws/` folder, and the Azure config JSON has no `IMAGE_REGISTRY` key, so on Azure the workflow sets no image registry, no Self-Service pull secret (`imagePullSecretName`, `env.DPN_IMAGE_PULL_SECRET`) and no producer registry (`env.DPN_IMAGE_REGISTRY`): the consumer charts default to an empty `imageRegistry` and the Self-Service chart falls back to `<acrName>.azurecr.io/dsi`. The repository's own workflow README describes `dpn-gha-self-service-cd.yaml` as effectively AWS-only today for this reason. Before running it on Azure, add `IMAGE_REGISTRY` to `.github/config/azure/<environment>-<cluster>.json` and/or add `values/azure/<environment>-<cluster>.yaml` files to the charts with your registry, pull secret and Self-Service settings.

> **Notes:**
> - The namespace itself is not created by the workflow and must exist already (see [AKS Namespace Configuration](../02-configuration/00-common-dpn-configuration.md#step23-aks-namespace-configuration)).
> - Consumer scheduling defaults to `SCHEDULER_BACKEND: interval`. This is preconfigured in the consumer charts' `values.yaml`; keep the default (see the [Configuration Guide overview](../02-configuration/07-configure-dpn-data-pipelines.md#overview)).
> - One other data pipeline CD workflow exists: **DPN CD - Data Pipelines** (`dpn-gha-data-pipelines-cd.yaml`, inputs `environment`, `cluster`, `cloud`, `configType`, `processType`, `productType`, `schemaType`, `imageTag`, optional `imageName`) helm-installs a single reference chart, `blueprints/<configType>/<processType>/<adaptor|extractor>/charts`, as release `dpn-<configType>-<processType>-<adaptor|extractor>-<productType>` into the config JSON's `NAMESPACE`. It always passes `-f <chart>/values/<cloud>/<environment>-<cluster>.yaml`, which the blueprint charts do not currently ship. Use `dpn-gha-self-service-cd.yaml` for the standard deployment.

#### One-time setup for a new environment: create secrets and restart pods

Every time the DPN Data Pipeline is deployed into a **new environment** (a new `<environment>-<cluster>`, or a newly created `ns-dpn-dp-01`), do the following once:

1. Create the secrets in `ns-dpn-dp-01`. Copy the shared secrets from `ns-dpn-01` as described in [Copy shared secrets into ns-dpn-dp-01](../02-configuration/00-common-dpn-configuration.md#copy-shared-secrets-into-ns-dpn-dp-01-data-pipelines-prerequisite), and create the storage secrets as described in the [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table). Confirm that every secret listed in [STEP-01b](#step-01b-prepare-infrastructure-and-application-prerequisites) exists:

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

> **Rollback and uninstall:** the three releases are rolled back with **DPN Rollback - Self-Service Data Pipelines** (`dpn-gha-self-service-rollback.yaml`, inputs `environment`, `cluster`, `cloud`, `release_name`, `targetRevision`, `confirm`) and removed with **DPN Uninstall - Self-Service Data Pipelines** (`dpn-gha-self-service-uninstall.yaml`, inputs `environment`, `cluster`, `cloud`, `release_name`, `confirm`; `release_name` can also be `all`). Neither touches UI-created producer Deployments, which are managed from the UI. Releases deployed by `dpn-gha-data-pipelines-cd.yaml` in `ns-dpn-01` have their own workflows, **DPN Rollback - Data Pipelines** (`dpn-gha-data-pipelines-rollback.yaml`) and **DPN Uninstall - Data Pipelines** (`dpn-gha-data-pipelines-uninstall.yaml`). All four default to `cloud: aws`, so select `azure`. See [Rollback Procedures, Part 1](../04-rollback/04-rollback-procedures.md#part-1--dpn-data-pipeline-rollback) and [Uninstall DPN Data Pipeline](../05-uninstall/05-uninstall-decommissioning.md#part-2--uninstall-dpn-data-pipeline).

---

### STEP-02c: Validate Data Pipeline CD Workflow

Once the deployment has completed, the namespace (`ns-dpn-dp-01`) should show the two consumer pipelines and the Self-Service UI running:

```bash
kubectl get pods -n <namespace>
```

Expected workloads:

```text
dpn-consumer-file-extractor-xxxxxxxx-xxxxx   1/1   Running
dpn-consumer-topic-extractor-xxxxxxxx-xxxxx  1/1   Running
dpn-self-service-xxxxxxxx-xxxxx              1/1   Running
```


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
2. Create a data product following the [DPN Data Pipeline UI Operations guide](../../../05-dpn-user-interfaces/11-dpn-data-pipeline-ui-operations.md): choose the `product_type`, the `file` or `topic` pathway and the schedule, then review and confirm the proposed names.
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
- Missing secrets or an incorrect connection string for Blob Storage — verify the required Kubernetes secrets exist with the correct names and values (the connection-string values must be base64-encoded; see the [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table)).
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

HPA is disabled by default and should stay disabled while `SCHEDULER_BACKEND: interval` is in use (see the [Configuration Guide overview](../02-configuration/07-configure-dpn-data-pipelines.md#overview)).

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
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
