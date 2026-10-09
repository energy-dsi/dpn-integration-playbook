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
  - [STEP-02a: Configure Data Pipeline CI Pipeline](#step-02a-configure-data-pipeline-ci-pipeline)
  - [STEP-02b: Execute Data Pipeline CI Pipeline](#step-02b-execute-data-pipeline-ci-pipeline)
  - [STEP-02c: Validate Data Pipeline CI Pipeline](#step-02c-validate-data-pipeline-ci-pipeline)
  - [STEP-02d: Configure Data Pipeline CD Pipeline](#step-02d-configure-data-pipeline-cd-pipeline)
  - [STEP-02e: Execute Data Pipeline CD Pipeline](#step-02e-execute-data-pipeline-cd-pipeline)
  - [STEP-02f: Validate Data Pipeline CD Pipeline](#step-02f-validate-data-pipeline-cd-pipeline)
- [STEP-03: Create the First Data Product](#step-03-create-the-first-data-product)
- [STEP-04: Troubleshooting](#step-04-troubleshooting)
  - [CI Pipeline Failure](#ci-pipeline-failure)
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

This document provides step-by-step instructions for installing and deploying the **DPN Data Pipeline component** using **Azure DevOps (ADO) pipelines**.

The deployment uses the following repository:

- https://github.com/energy-dsi/dpn-data-pipelines.git

The deployment process consists of:

- **Continuous Integration (CI)** — scans, tests, builds and pushes **five container images** to the Azure Container Registry (ACR):

  | Image | Purpose |
  |-------|---------|
  | `dpn-producer-file-adaptor-generic` | Generic producer image for the file pathway |
  | `dpn-producer-topic-adaptor-generic` | Generic producer image for the topic pathway |
  | `dpn-consumer-file-extractor` | Consumer file extractor |
  | `dpn-consumer-topic-extractor` | Consumer topic extractor |
  | `dpn-self-service` | DPN Self-Service UI |

- **Continuous Deployment (CD)** — deploys into **Azure Kubernetes Service (AKS)** using Helm:
  - the **Self-Service UI**, and
  - the two **consumer pipelines** (one file extractor, one topic extractor).

**Producer data products are not deployed by the pipelines.** They are created at runtime from the Self-Service UI, which launches the generic producer image with that product's configuration (see [STEP-03](#step-03-create-the-first-data-product) and the [Configuration Guide](../02-configuration/07-configure-dpn-data-pipelines.md#step-01-set-up-a-new-data-product-self-service)). No per-product CI/CD run, folder copy or image build is required.

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

Push the code to the organisation's Azure DevOps repository.

```bash
git remote add ado https://dev.azure.com/<org>/<project>/_git/<repository>
git push -u ado main
```

---

### STEP-01b: Prepare Infrastructure and Application Prerequisites

Ensure the following prerequisites are completed before deployment:

- AKS cluster provisioned and accessible, with the **metrics-server** running (enabled by default on AKS)
- Azure Container Registry (ACR) available, and attached to the AKS cluster so nodes can pull images without an image pull secret
- DPN Streaming Service (Kafka) deployed, with SASL/TLS authentication through DPN Authentication Service (Keycloak) — see [Configure Kafka Security](../02-configuration/07-configure-dpn-data-pipelines.md#step-08b-configure-kafka-security-sasltls). Topics do **not** need to be pre-created; the pipeline creates them (see [DPN Streaming Service (Kafka)](../02-configuration/07-configure-dpn-data-pipelines.md#step-09b-configure-streaming-service-kafka))
- DPN Health Monitoring Service deployed and the OTEL collector container in a running state
- Storage accounts available for the `file` integration pathway (containers are created by the pipeline — see [Storage Blob / S3 Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step-09a-storage-blob--s3-configuration))
- The following Kubernetes secrets created **in the data pipeline namespace** (`ns-dpn-dp-01` by default) before the CD pipeline runs. The containers refuse to start without valid values:

  | Secret | Purpose |
  |--------|---------|
  | `dpn-tls` | Kafka truststore (`truststore.jks`), mounted into pods |
  | `tls-auth-secret` | `TRUSTSTORE_PASSWORD` and `KEYSTORE_PASSWORD` |
  | `dpn-keycloak-secrets` | Keycloak client secret (`KC_SERVICE_CLIENT_SECRET`) |
  | `dpn-health-ca` | CA bundle for the OTEL collector's TLS listener |
  | `producer-file-dp-secret` | Platform storage connection strings (`SRC_CONNECTION_STRING`, `TARGET_CONNECTION_STRING`) used by the Self-Service UI and file producers |
  | `consumer-file-dp-secret` | Consumer storage connection strings for the file extractor |

  See [Secrets Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step-08-configure-secrets) for the contents of each.
- Keycloak client `dpn-service-client` configured for the Self-Service UI login: **Standard flow** enabled, and the UI's `<externalUrl>/oauth2/callback` registered as a valid redirect URI. The realm roles `dpnadmin`, `dpnoperator` and `dpnreader` assigned to the people who will use the UI.
- Network and firewall rules applied as described in [Network and Ports Configuration](../02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration)
- Software prerequisites (Azure DevOps access)

[Refer to the **Prerequisites** and **Configuration** documentation for details](../01-prerequisites/01-dpn-prerequisites.md)

**Note:** Organisations must review the CI/CD pipeline code for the following.

- The DSI package contains security and quality tool stages in the CI pipeline (for example Checkmarx, FOSSA, SonarQube and JFrog X-Ray). Organisations should keep only the stages relevant to them and remove or replace the others carefully before running the CI pipeline.
- The agent pool name has been changed to the Organisation's agent pool name.
- There should not be any `<<Your specific value>>` placeholders in the parameters. The DSI package provides these to ensure configuration is modified by Organisations.
- The container registry, service connection and environment parameters point to the correct deployment environment.
- The per-environment configuration files under `.pipelines/azure-pipelines/config/` (for example `dev-dpn01.json`) contain the organisation's ACR name, subscription, resource group, AKS cluster, Key Vault, namespace and `OAUTH2_PROXY_EXTERNAL_URL` values.
- Required firewall rules are applied.
- Both CI and CD pipelines are verified for the above before execution.

---

### STEP-01c: Identify Pipeline Repository Structure

The repository includes the necessary CI and CD pipelines in the following folder structure for reference.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        ├── ci-pipelines/
        │     └── dpn-self-service-ci.yaml
        ├── cd-pipelines/
        │     ├── dpn-self-service-cd.yaml
        │     ├── dpn-self-service-rollback.yaml
        │     └── dpn-self-service-uninstall-cd.yaml
        └── config/
              └── <environment>-<cluster>.json
```

---

### STEP-01d: Configure Environment Approval Gates

Before running the CD pipeline against any environment, confirm the corresponding Azure DevOps Environment has its approval check configured (Project Settings → Environments → Approvals and checks). The CD pipeline has a single approval gate on its deploy job; the approver group depends on the selected environment.

---

## STEP-02: Install DPN Data Pipeline

The DPN Data Pipeline is deployed as a Self-Service UI plus two fixed consumer pipelines. Each pipeline stage runs in a single container; there are no separate adaptor and mapper components to deploy.

---

### STEP-02a: Configure Data Pipeline CI Pipeline

Create a new Azure DevOps Pipeline from the CI pipeline YAML file located at the following path:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── dpn-self-service-ci.yaml
```

---

### STEP-02b: Execute Data Pipeline CI Pipeline

The CI pipeline builds all five images in one run. It takes no product, process type or consumer parameters. The image tag is the run's own build number, so queuing the pipeline never prompts for a tag.

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | Azure service connection used to push to the ACR for the selected environment |
| `environment` | Target environment, e.g. `dev`. Selects which ACR the images are pushed to |
| `cluster` | `dpn01` (DSI provides two DPN configurations per environment. Organisations may keep only one, such as `dpn01`, to run a single DPN cluster) |

The pipeline stages are:

1. **Announce Image Tag** — displays the tag used for this run.
2. **Checkmarx scan**, **FOSSA scan**, **Unit tests and coverage** (pytest, SBOM generation) and **SonarQube scan**.
3. **Build & Push Images** — builds the five images, pushes them to the ACR under `<acr>.azurecr.io/dsi/<image>:<tag>`, and records each image digest.
4. **JFrog X-Ray scan** of the pushed images.

> **Note:** Record the **image tag** (the run's `Build.BuildNumber`, shown in the run summary). It is the `imageTag` input for the CD pipeline.

---

### STEP-02c: Validate Data Pipeline CI Pipeline

Verify that the ACR contains all five repositories under `dsi/` with the expected image tag:

```bash
az acr repository show-tags --name <acr-name> --repository dsi/dpn-producer-file-adaptor-generic --output table
```

---

### STEP-02d: Configure Data Pipeline CD Pipeline

Create a new Azure DevOps Pipeline from the CD pipeline YAML file located at the following path:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-self-service-cd.yaml
```

> **Notes:**
> - The CD pipeline only runs `helm upgrade --install`. It never builds or pushes images, so the CI pipeline must have completed first for the same image tag.
> - It deploys three Helm releases into the data pipeline namespace (`ns-dpn-dp-01`): `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor` and `dpn-self-service`.
> - Consumer scheduling defaults to `SCHEDULER_BACKEND: interval`. Confirm the value in the consumer charts' `values.yaml` before running (see [Configure Scheduling](../02-configuration/07-configure-dpn-data-pipelines.md#step-06-configure-scheduling)).
> - Self-Service UI login (oauth2-proxy with Keycloak) is enabled by the pipeline. If `OAUTH2_PROXY_EXTERNAL_URL` is set in the environment's config JSON it is used as the UI's address. Otherwise the pipeline reuses the load balancer's existing IP, or on a first-ever deployment it creates the load balancer, waits for an IP to be assigned and redeploys with login enabled.

---

### STEP-02e: Execute Data Pipeline CD Pipeline

Execute the CD pipeline with the following runtime parameters.

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | A service connection able to deploy to the target AKS cluster |
| `environment` | Environment abbreviation, e.g. `dev` |
| `cluster` | `dpn01` or `dpn02` |
| `imageTag` | The image tag produced by the CI run in [STEP-02b](#step-02b-execute-data-pipeline-ci-pipeline) |

Approve the deployment when the environment approval gate is raised.

To roll back or remove the platform, use `dpn-self-service-rollback.yaml` and `dpn-self-service-uninstall-cd.yaml`. They operate on the three Helm releases only. Producer data products created from the UI are not Helm releases; stop or delete them from the UI.

---

### STEP-02f: Validate Data Pipeline CD Pipeline

Once the deployment has completed, the namespace should show the Self-Service UI and both consumer pipelines running:

```bash
kubectl get pods -n ns-dpn-dp-01
```

Expected workloads:

```text
dpn-self-service-xxxxxxxx-xxxxx             1/1   Running
dpn-consumer-file-extractor-xxxxxxxx-xxxxx  1/1   Running
dpn-consumer-topic-extractor-xxxxxxxx-xxxxx 1/1   Running
```

If oauth2-proxy is enabled, its pod also shows `Running`. Check that the UI is exposed and that the rollout completed:

```bash
kubectl rollout status deployment/dpn-self-service -n ns-dpn-dp-01
kubectl get svc dpn-self-service-external -n ns-dpn-dp-01
```

Verify clean logs inside a container:

```bash
kubectl logs <pod-name> -n ns-dpn-dp-01
```

---

## STEP-03: Create the First Data Product

Producer data products are created from the Self-Service UI, not from a pipeline.

1. Open the UI at the address reported in [STEP-02f](#step-02f-validate-data-pipeline-cd-pipeline) and sign in with a user holding the `dpnadmin` or `dpnoperator` role.
2. Create a data product following [Set Up a New Data Product (Self-Service)](../02-configuration/07-configure-dpn-data-pipelines.md#step-01-set-up-a-new-data-product-self-service): choose the `product_type`, the `file` or `topic` pathway and the schedule, then review and confirm the proposed names.
3. Verify that a Deployment named `dpn-producer-<pathway>-<product_type>` is running:

   ```bash
   kubectl get deployments -n ns-dpn-dp-01
   ```

4. Use **Run Now** and the logs view in the UI to confirm a first cycle completes.

---

## STEP-04: Troubleshooting

### CI Pipeline Failure

Possible causes:

- Container registry authentication or push failure — verify the service connection has push permission on the ACR for the selected environment.
- A security or quality stage (Checkmarx, FOSSA, SonarQube, JFrog X-Ray) failing or not configured for the organisation — remove or replace the stage as described in [STEP-01b](#step-01b-prepare-infrastructure-and-application-prerequisites).
- Unit test failure in the pytest stage — review the published test results.

Verify pipeline logs and ensure all credentials and parameters are correct.

---

### Container Image Not Found

Check that the CI pipeline pushed all five images to the ACR under the tag supplied to the CD pipeline.

If the expected repository or tag is not listed, re-run the CI pipeline and ensure it completes without errors before running the CD pipeline.

---

### Image Pull Failures

If pods show `ImagePullBackOff` or `ErrImagePull`:

- Confirm the AKS cluster has pull access to the ACR (the ACR is attached to the cluster).
- Confirm the image reference (`imageRegistry`/`imageName`/`imageTag`) matches an actual published tag. A typo produces the same failure as a genuine access issue.
- For products created from the UI, confirm the Self-Service UI was deployed with the correct `env.DPN_IMAGE_REGISTRY` and `env.DPN_IMAGE_TAG`, since it passes these to the producer pods it creates.

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
- Missing secrets or an incorrect connection string/SAS token for Blob storage — verify the required Kubernetes secrets exist with the correct names and values (the connection-string values must be base64-encoded; see [Configure Storage Secrets](../02-configuration/07-configure-dpn-data-pipelines.md#step-08a-configure-storage-secrets)).
- Missing Kafka truststore secret or wrong `TRUSTSTORE_PASSWORD` — a wrong password fails the container deliberately rather than falling back.
- The Self-Service UI's cloud provider is wrong (`DPN_CLOUD_PROVIDER` must be `azure` on AKS) — the UI's registry restore at start-up then uses the wrong storage API and the pod never becomes healthy.

---

### Self-Service UI Not Reachable or Login Fails

- Confirm `dpn-self-service-external` has an IP assigned (`kubectl get svc dpn-self-service-external -n ns-dpn-dp-01`).
- Confirm the Keycloak client `dpn-service-client` has **Standard flow** enabled and `<externalUrl>/oauth2/callback` registered as a valid redirect URI, plus the post-logout redirect URI and web origin.
- Confirm the user holds one of the realm roles `dpnadmin`, `dpnoperator` or `dpnreader`.
- A `401` on every request usually means the request bypassed oauth2-proxy (for example a `kubectl port-forward` straight to the pod). Access the UI through its external address.
- A `403` on an action means the user's role is not allowed: only `dpnadmin` and `dpnoperator` can create, start, stop and run products, and only `dpnadmin` can delete.

---

### Data Product Cannot Be Created

- **Name already exists** — every confirmed storage container and Kafka topic name must be new. The pre-check blocks creation if the name already exists in the storage account or on the broker. Choose a different name.
- **Invalid `product_type`** — use lowercase letters, digits and hyphens only, and keep the name short enough that `dpn-producer-<pathway>-<product_type>` stays within 63 characters.
- **Invalid container name** — storage container names must be 3–63 characters of lowercase letters, digits and single hyphens, starting and ending with a letter or digit.
- **Pre-check hangs or fails** — confirm the UI pod can reach the storage account and the Kafka broker, and that the platform storage secret is valid.

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
http://kafka-ui:8085
```

Check that:

- The topic exists in the expected Kafka cluster (source or target). Topics are normally created automatically when a product runs.
- The topic name in the configuration matches exactly (topic names are case-sensitive).
- There are no consumer group errors shown in the Kafka UI for the pipeline's consumer group(s).
- For the `topic` pathway, `srcGroupId` values are unique per product.
- A SASL `invalid_token` error means the Keycloak token endpoint URL points at the load-balancer hostname. It must use the plain `dpn-keycloak` ClusterIP service so that the token's issuer matches what the broker expects.
- On the consumer topic extractor, messages missing `orgName` or `productType` headers are skipped by design.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 |
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 |
| Oct-2026 | DSI Assurance   | Draft  | V3.0.0 |
