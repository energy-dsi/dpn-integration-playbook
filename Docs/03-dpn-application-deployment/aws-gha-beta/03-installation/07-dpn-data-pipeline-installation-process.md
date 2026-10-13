# DPN Data Pipeline Installation Process

---

## Table of Contents

- [Overview](#overview)
- [Step1: Installation Prerequisites](#step1-installation-prerequisites)
  - [Step1a. Clone and Prepare Source Repositories](#step1a-clone-and-prepare-source-repositories)
  - [Step1b. Prepare Infrastructure and Application Prerequisites](#step1b-prepare-infrastructure-and-application-prerequisites)
  - [Step1c. Identify Pipeline Repository Structure](#step1c-identify-pipeline-repository-structure)
  - [Step1d. Configure Environment Approval Gates](#step1d-configure-environment-approval-gates)
- [Step2: Install DPN Data Pipeline](#step2-install-dpn-data-pipeline)
  - [Step2a. Data Pipeline CI (component source repository)](#step2a-data-pipeline-ci-component-source-repository)
  - [Step2b. Validate the Built Image](#step2b-validate-the-built-image)
  - [Step2c. Execute Data Pipeline CD Workflow](#step2c-execute-data-pipeline-cd-workflow)
  - [Step2d. Verify Deployed Containers](#step2d-verify-deployed-containers)
  - [Step2e. Validate Data Pipeline CD Workflow](#step2e-validate-data-pipeline-cd-workflow)
- [Step3: Create the First Data Product](#step3-create-the-first-data-product)
- [Step4: Troubleshooting](#step4-troubleshooting)
  - [Container Image Not Found](#container-image-not-found)
  - [Image Pull Failures](#image-pull-failures)
  - [Values File Not Found](#values-file-not-found)
  - [Pods Not Starting](#pods-not-starting)
  - [Container CrashLoopBackOff](#container-crashloopbackoff)
  - [Self-Service UI Not Reachable or Login Fails](#self-service-ui-not-reachable-or-login-fails)
  - [Data Product Cannot Be Created](#data-product-cannot-be-created)
  - [HPA Not Scaling](#hpa-not-scaling)
  - [TRUSTSTORE_PASSWORD / Kafka TLS Handshake Errors](#truststore_password--kafka-tls-handshake-errors)
  - [Kafka Topic Issues](#kafka-topic-issues)
- [Step5: Containerized Deployment Using DSI Provided Container Images](#step5-containerized-deployment-using-dsi-provided-container-images)
- [Review Notes](#review-notes)

---

## Overview

This document provides step-by-step instructions for installing and deploying **DPN Data Pipeline component** using the **GitHub Actions pipeline**.

The deployment uses the following repository:

- https://github.com/energy-dsi/dpn-containerised-deployment-service.git — the data pipeline source, blueprints and Helm charts live under its `dpn-data-pipelines/` folder, and the CD workflows under `.pipelines/github-action-pipelines/workflows/`

The deployment process consists of:

- **Continuous Integration (CI)** — builds the container images (see [Step2a](#step2a-data-pipeline-ci-component-source-repository))
- **Continuous Deployment (CD)** — deploys into **Amazon Elastic Kubernetes Service (EKS)** with the **`DPN CD - Self-Service Data Pipelines`** workflow (`dpn-gha-self-service-cd.yml`), which installs three Helm releases into `ns-dpn-dp-01`:
  - `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` — the two fixed consumer pipelines
  - `dpn-self-service` — the DPN Self-Service UI

**Producer data products are not deployed by a workflow.** They are created at runtime from the Self-Service UI, which launches the generic producer image with that product's configuration (see [Step3](#step3-create-the-first-data-product) and the [Configuration Guide](../02-configuration/07-configure-dpn-data-pipelines.md#step1-setup-a-new-data-product-self-service)). No per-product CI/CD run, folder copy or image build is required.

> **Upgrading from an earlier release:** data products deployed as separate per-product producer/consumer Helm releases are **not automatically imported** into the Self-Service UI. Recreate each one through the UI after this installation (see [Step3](#step3-create-the-first-data-product)), then remove the old releases as described in [Uninstall and Decommissioning](../05-uninstall/05-uninstall-decommissioning.md).

---

## Step1: Installation Prerequisites

The following prerequisites must be completed before beginning the installation process.

### Step1a. Clone and Prepare Source Repositories

Clone the official repository from GitHub.

```bash
git clone https://github.com/energy-dsi/dpn-containerised-deployment-service.git
```

Switch to the desired branch.

```bash
git checkout main
```

or

```bash
git checkout release/<version>
```

Deployment itself runs directly against the GitHub repository via GitHub Actions — there is no separate push-to-pipeline-repository step.

---

### Step1b. Prepare Infrastructure and Application Prerequisites

Ensure the following prerequisites are completed before deployment:

- EKS cluster provisioned and accessible, with the **metrics-server** add-on running (required for HPA)
- The data pipeline namespace `ns-dpn-dp-01` created once on the cluster. `dpn-gha-self-service-cd.yml` checks for it and fails if it is missing:

  ```bash
  kubectl create namespace ns-dpn-dp-01
  ```

- IRSA (IAM Roles for Service Accounts) enabled on the EKS cluster, with the IAM roles referenced by `serviceAccount.irsaRoleArn` in the Self-Service and consumer file extractor AWS values files created beforehand — `dpn-gha-self-service-cd.yml` does not create them. See [Configure Storage Secrets](../02-configuration/07-configure-dpn-data-pipelines.md#step8a-configure-storage-secrets) in the Configuration Guide
- DPN Streaming Service (Kafka) deployed, with SASL/TLS authentication through DPN Authentication Service (Keycloak). Topics do **not** need to be pre-created; the pipeline creates them (see [DPN Streaming Service (Kafka)](../02-configuration/07-configure-dpn-data-pipelines.md#step9b-configure-streaming-service-kafka) in the Configuration Guide)
- DPN Health Monitoring Service deployed and OTEL collector container is in running state
- S3 buckets for the `file` integration pathway are created by the pipeline when needed (see [Storage Blob / S3 Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step9a-storage-blob--s3-configuration))
- Kubernetes secrets created in `ns-dpn-dp-01` (`dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, `dpn-health-ca`, `ghcr-pull-secret` — see [Secrets Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step8-configure-secrets)). On the first deployment into a new environment, restart the pods once the secrets exist; see [One-time setup for a new environment](#one-time-setup-for-a-new-environment-create-secrets-and-restart-pods).
- Keycloak client `dpn-service-client` configured for the Self-Service UI login: **Standard flow** enabled, and the UI's `<externalUrl>/oauth2/callback` registered as a valid redirect URI. The realm roles `dpnadmin`, `dpnoperator` and `dpnreader` assigned to the people who will use the UI
- Network and firewall rules applied as described in [Network and Ports Configuration](../02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration), including outbound access to `ghcr.io`
- Software prerequisites (GitHub Actions access, GHCR access — see Step2 below)

[Refer to the **Prerequisites** and **Configuration** documentation for details](../01-prerequisites/01-dpn-prerequisites.md)

**Note:** Organisations must review the CI/CD workflow code for the following. 

- If running your own CI, keep only the relevant build, unit test, and image-push steps — DSI's own CI examples include tool usage such as CheckMarx, SonarQube, and JFrog Xray that your organisation may not need
- The container image is appropriate and referred from GHCR repository unless Organisation plans to use a separate image repository on their own
- The config JSON's environment parameters are pointing to correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- Both CI and CD are verified for the above prerequisites before execution

---

### Step1c. Identify Pipeline Repository Structure

All CD workflows, their per-cloud configuration and the charts they deploy live in the central repository:

```
.pipelines/
├── github-action-pipelines/
│   ├── workflows/
│   │   ├── dpn-gha-self-service-cd.yml             <- DPN CD - Self-Service Data Pipelines (standard path)
│   │   ├── dpn-self-service-rollback.yml       <- DPN Rollback - Self-Service Data Pipelines
│   │   ├── dpn-self-service-uninstall.yml      <- DPN Uninstall - Self-Service Data Pipelines
│   │   ├── dpn-gha-cd-data-pipelines.yml           <- DPN CD - Data Pipelines (single reference chart per run)
│   │   └── dpn-gha-cd-data-pipelines-aws-poc.yml   <- DPN CD - Data Pipelines (AWS PoC)
│   ├── actions/
│   │   └── cloud-login/action.yml
│   └── config/
│       └── aws/<environment>-<cluster>.json
└── dpn-data-pipelines/
    ├── blueprints/{producer,consumer}/{file,topic}/{adaptor|extractor}/charts/values/aws/<environment>-<cluster>.yaml
    └── service/charts/values/aws/<environment>-<cluster>.yaml
```

`dpn-gha-self-service-cd.yml` reads `.github/config/aws/<environment>-<cluster>.json` (`AWS_REGION`, `AWS_ACCOUNT_ID`, `EKS_CLUSTER`, `IMAGE_REGISTRY`, and the optional `OAUTH2_PROXY_EXTERNAL_URL`) and logs in through the shared `cloud-login` action with `cloud: aws`.

---

### Step1d. Configure Environment Approval Gates

There is no ADO-style approval-check concept for GitHub Actions workflows by default. If you want a manual sign-off before running the CD workflow against a given environment, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

---

## Step2: Install DPN Data Pipeline

The DPN Data Pipeline is a set of single-container pipeline stages — one producer adaptor per data product and one consumer extractor per pathway — as outlined in the [Configuration Guide](../02-configuration/07-configure-dpn-data-pipelines.md#overview).

The following diagram represents an overview of DPN Producer Data Pipeline CI/CD architecture. 

![DPN Data Pipeline Producer DevOPS Architecture](../../../04-dpn-architecture/images/dpn_data_pipeline_producer.png)

The following diagram represents an overview of DPN Consumer Data Pipeline CI/CD architecture. 

![DPN Data Pipeline Consumer DevOPS Architecture](../../../04-dpn-architecture/images/dpn_data_pipeline_consumer.png)


---

### Step2a. Data Pipeline CI (component source repository)

CI (build, test, and image push to GHCR) for the data pipeline components is not part of the central repository's GitHub Actions workflows — build images via your own CI process, or use the DSI-provided prebuilt GHCR images (see [Step5](#step5-containerized-deployment-using-dsi-provided-container-images)).

Five images are needed, one per blueprint plus the UI — there is no per-schema or per-product image:

| Image | Built from | Purpose |
|-------|------------|---------|
| `dpn-producer-file-adaptor-generic` | `blueprints/producer/file/adaptor/Dockerfile` | Generic producer image for the file pathway |
| `dpn-producer-topic-adaptor-generic` | `blueprints/producer/topic/adaptor/Dockerfile` | Generic producer image for the topic pathway |
| `dpn-consumer-file-extractor` | `blueprints/consumer/file/extractor/Dockerfile` | Consumer file extractor |
| `dpn-consumer-topic-extractor` | `blueprints/consumer/topic/extractor/Dockerfile` | Consumer topic extractor |
| `dpn-self-service` | `service/Dockerfile` | DPN Self-Service UI |

> **Notes:**
> - Schema type and product type are no longer build parameters. Product identity is supplied as environment variables when the UI launches a product.

---

#### Step2b. Validate the Built Image

Verify that the image registry contains the five images above with the expected image tag before running the CD workflow.

---

<a id="step-02c-execute-data-pipeline-cd-workflow"></a>

#### Step2c. Execute Data Pipeline CD Workflow

Go to **Actions → DPN CD - Self-Service Data Pipelines → Run workflow** (`dpn-gha-self-service-cd.yml`), and supply:

| Input | Value |
|---|---|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02` (default `dpn01`) |
| `imageTag` | The image tag to deploy |

There is no `cloud` input — the workflow is AWS-only. In one run it:

1. Verifies the `ns-dpn-dp-01` namespace exists.
2. Installs `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` from `blueprints/consumer/{file,topic}/extractor/charts` with `values/aws/<environment>-<cluster>.yaml`, setting `imageRegistry` to the config JSON's `IMAGE_REGISTRY` and `imageTag` to the input.
3. Installs `dpn-self-service` from `service/charts` with `values/aws/<environment>-<cluster>.yaml`. The oauth2-proxy (Keycloak login, HTTPS) is enabled with `oauth2Proxy.externalUrl` set to the config JSON's `OAUTH2_PROXY_EXTERNAL_URL`, or else to the hostname of the existing `dpn-self-service-external` LoadBalancer. On a first deploy with neither, it installs once with the proxy off, waits up to 3 minutes for AWS to assign an NLB hostname, then redeploys with the proxy on — register `<that URL>/oauth2/callback` on `dpn-service-client` afterwards (the workflow prints a warning with the URL).

> **Notes:**
> - Consumer scheduling defaults to `SCHEDULER_BACKEND: interval`. Confirm the value in the consumer charts' values before running (see [Configure Scheduling](../02-configuration/07-configure-dpn-data-pipelines.md#step6-configure-scheduling)).
> - The `imageTag` input is applied to the three Helm releases. The image tag used for UI-created producers comes from the Self-Service chart's `env.DPN_IMAGE_TAG` (default `latest`), which this workflow does not override — set it in the values file if producers must run a pinned tag.
> - Two other data pipeline CD workflows exist: **DPN CD - Data Pipelines** (`dpn-gha-cd-data-pipelines.yml`, inputs `environment`, `cluster`, `cloud`, `configType`, `processType`, `productType`, `schemaType`, `imageTag`, optional `imageName`) helm-installs a single reference chart, `blueprints/<configType>/<processType>/<adaptor|extractor>/charts`, as release `dpn-<configType>-<processType>-<adaptor|extractor>-<productType>` into the config JSON's `NAMESPACE`; with `cloud: aws` and `processType: file` it also creates the source/target S3 buckets and the chart's IRSA role. **DPN CD - Data Pipelines (AWS PoC)** (`dpn-gha-cd-data-pipelines-aws-poc.yml`) is a narrower proof-of-concept variant hardcoded to AWS. Use `dpn-gha-self-service-cd.yml` for the standard deployment.

##### One-time setup for a new environment: create secrets and restart pods

Every time the DPN Data Pipeline is deployed into a **new environment** (a new `<environment>-<cluster>`), do the following once:

1. Create the secrets the data pipeline pods read, in `ns-dpn-dp-01`, as described in [Secrets Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step8-configure-secrets). Confirm they exist:

   ```bash
   kubectl get secrets -n ns-dpn-dp-01
   ```

2. Restart the pods so they pick up the secrets. A pod reads secret values only when it starts, so pods created before the secrets existed stay in `CreateContainerConfigError` or `CrashLoopBackOff`, or run without the values, until they are restarted:

   ```bash
   kubectl rollout restart deployment -n ns-dpn-dp-01
   kubectl get pods -n ns-dpn-dp-01 -w
   ```

3. Once every pod shows `Running`, continue with [Step2d](#step2d-verify-deployed-containers).

This is needed only once per environment. Later CD runs into the same environment reuse the existing secrets. Repeat steps 1 and 2 only when a secret is rotated.

> **Rollback and uninstall:** the three releases are rolled back with **DPN Rollback - Self-Service Data Pipelines** (`dpn-self-service-rollback.yml`, inputs `environment`, `cluster`, `cloud`, `release_name`, `targetRevision`, `confirm`) and removed with **DPN Uninstall - Self-Service Data Pipelines** (`dpn-self-service-uninstall.yml`, `release_name` can also be `all`). Neither touches UI-created producer Deployments, which are managed from the UI. See [Rollback Procedures](../04-rollback/04-rollback-procedures.md) and [Uninstall and Decommissioning](../05-uninstall/05-uninstall-decommissioning.md).

---

#### Step2d. Verify Deployed Containers

Verify that the containers are deployed on the EKS cluster. Immediately after the CD workflow, the namespace shows the two consumer pipelines and the Self-Service UI:

```
dpn-consumer-file-extractor-xxxxxxxx-xxxxx
dpn-consumer-topic-extractor-xxxxxxxx-xxxxx
dpn-self-service-xxxxxxxx-xxxxx
```

When the oauth2-proxy is enabled its pod also shows `Running`. Each producer data product created from the UI then adds one Deployment:

```
dpn-producer-{integration type}-{product_type}-xxxxxxxx-xxxxx
```

---

#### Step2e. Validate Data Pipeline CD Workflow

Once a successful deployment has completed, check that the pods are running and that the UI is exposed:

```bash
kubectl get pods -n ns-dpn-dp-01
kubectl rollout status deployment/dpn-self-service -n ns-dpn-dp-01
kubectl get svc dpn-self-service-external -n ns-dpn-dp-01   # internal NLB hostname
```

![DPN Reference Implementation](../../../04-dpn-architecture/images/dpn_ref_implementation.png)

Verify clean logs inside the container:

```bash
kubectl logs <pod-name> -n ns-dpn-dp-01
```

---

## Step3: Create the First Data Product

Producer data products are created from the Self-Service UI, not from a workflow.

1. Open the UI at the address from [Step2e](#step2e-validate-data-pipeline-cd-workflow) and sign in with a user holding the `dpnadmin` role (only `dpnadmin` can create products).
2. Create a data product following [Setup a New Data Product (Self-Service)](../02-configuration/07-configure-dpn-data-pipelines.md#step1-setup-a-new-data-product-self-service): choose the `product_type`, the `file` or `topic` pathway and the schedule, then review and confirm the proposed names.
3. Verify that a Deployment named `dpn-producer-<pathway>-<product_type>` is running:

   ```bash
   kubectl get deployments -n ns-dpn-dp-01
   ```

4. Use **Run Now** and the logs view in the UI to confirm a first cycle completes. See [Operate a Data Product](../02-configuration/07-configure-dpn-data-pipelines.md#step7-operate-a-data-product) for the other actions.

---

## Step4: Troubleshooting

### Container Image Not Found

Check that all five images were pushed to the registry under the tag supplied to the CD workflow.

If the expected package/tag is not listed, rebuild and push the missing image before running the CD workflow.

---

### Image Pull Failures

If pods show `ImagePullBackOff` or `ErrImagePull`:

- Confirm `ghcr-pull-secret` exists in `ns-dpn-dp-01` and contains a valid, non-expired GitHub PAT with `read:packages`.

- Confirm the EKS node group has outbound access to `ghcr.io` to pull the images

- Confirm the image reference (`imageRegistry`/`imageName`/`imageTag`) matches an actual published tag — a typo here produces the same failure as a genuine access issue. The consumer charts take `imageRegistry` from the config JSON's `IMAGE_REGISTRY`; the Self-Service UI takes it from its values file.

- For products created from the UI, confirm the Self-Service values set the correct `env.DPN_IMAGE_REGISTRY`, `env.DPN_IMAGE_TAG` and `env.DPN_IMAGE_PULL_SECRET`, since the UI passes these to the producer pods it creates.

---

### Values File Not Found

If `helm upgrade` fails because `values/aws/<environment>-<cluster>.yaml` does not exist, add the values file for that environment/cluster under the consumer extractor charts and `service/charts` (AWS values are checked in for `test-dpn01` and `test-dpn02` only).

---

### Pods Not Starting

Check pod events to identify scheduling or image pull issues:

```bash
kubectl describe pod <pod-name> -n ns-dpn-dp-01
```

Review the `Events` section at the bottom of the output. Common causes include insufficient node resources, a missing Secret that the pod references, or image pull errors due to incorrect image credentials

---

### Container CrashLoopBackOff

A `CrashLoopBackOff` status means the container starts, crashes, and Kubernetes repeatedly attempts to restart it. Check the logs to identify the root cause:

```bash
kubectl logs <pod-name> -n ns-dpn-dp-01
```

Common causes:

- Invalid or missing environment variables — the container validates its configuration at start-up and reports the missing value (`config.validation.failed`). Check the Helm values file for typographical errors or missing entries
- Missing secrets, or S3 access denied — verify the Kubernetes secrets exist and that the IRSA role bound to the pod's ServiceAccount grants access to the buckets (including bucket creation for UI-created products)
- Missing Kafka truststore secret or wrong `TRUSTSTORE_PASSWORD`
- The Self-Service UI's cloud provider is wrong — `env.DPN_CLOUD_PROVIDER` must be `aws` on EKS

---

### Self-Service UI Not Reachable or Login Fails

- Confirm `dpn-self-service-external` has an NLB hostname assigned (`kubectl get svc dpn-self-service-external -n ns-dpn-dp-01`). If the workflow warned that no hostname was assigned within 3 minutes, re-run it once AWS has assigned one.
- Confirm the Keycloak client `dpn-service-client` has **Standard flow** enabled and `<externalUrl>/oauth2/callback` registered as a valid redirect URI, plus the post-logout redirect URI and web origin.
- Confirm the user holds one of the realm roles `dpnadmin`, `dpnoperator` or `dpnreader`.
- A `401` on every request usually means the request bypassed oauth2-proxy (for example a `kubectl port-forward` straight to the pod). Access the UI through its external address.
- A `403` on an action means the user's role is not allowed: only `dpnadmin` and `dpnoperator` can start, stop, pause, resume and run products, and only `dpnadmin` can create and delete.

---

### Data Product Cannot Be Created

- **Name already exists** — every confirmed bucket and Kafka topic name must be new. The pre-check blocks creation if the name already exists in S3 or on the broker. Choose a different name.
- **Invalid `product_type`** — use lowercase letters, digits and hyphens only, and keep `dpn-producer-<pathway>-<product_type>` within 63 characters.
- **Invalid bucket name** — 3–63 characters of lowercase letters, digits and hyphens, starting and ending with a letter or digit.
- **Pre-check hangs or fails** — confirm the UI pod can reach S3 and the Kafka broker, and that its IRSA role is valid.

---

### HPA Not Scaling

HPA is disabled by default and should stay disabled while `SCHEDULER_BACKEND: interval` is in use (see [Configure HPA](../02-configuration/07-configure-dpn-data-pipelines.md#step5-configure-horizontal-pod-autoscaler-hpa)).

If HPA has been enabled and `kubectl get hpa` shows `<unknown>` under `TARGETS`:

- Confirm metrics-server is running: `kubectl get deployment metrics-server -n kube-system`.
- Confirm the affected pods have CPU/memory `requests` set in their Deployment spec — HPA cannot compute a percentage without a request baseline.

If metrics are available but replica count never changes, confirm `hpa.minReplicas`/`hpa.maxReplicas` allow room to scale, and that current load is actually crossing the configured `hpa.scaleUp.cpuUtilization`/`hpa.scaleUp.memoryUtilization` thresholds.

---

### TRUSTSTORE_PASSWORD / Kafka TLS Handshake Errors

If a pod fails to authenticate to Kafka with an error reading the truststore, confirm the `tls-auth-secret` secret carries the `TRUSTSTORE_PASSWORD` and `KEYSTORE_PASSWORD` keys, and that the `dpn-tls` secret carries `truststore.jks` and `keystore.jks` (plus `ca.crt` for UI-created producers, which read the CA from `/etc/kafka/secrets/ca.crt`). The Keycloak client secret is read from `dpn-keycloak-secrets` (key `KC_SERVICE_CLIENT_SECRET`).

### Kafka Topic Issues

Verify Kafka topics using the Kafka UI:

```
http://kafka-ui:8086
```

Check that:

- The topic exists in the expected Kafka cluster (source or target). Topics are normally created automatically when a product runs
- The topic name in the data pipeline configuration matches exactly (topic names are case-sensitive)
- There are no consumer group errors shown in the Kafka UI for the data pipeline's consumer group(s)
- For the `topic` pathway specifically, `srcGroupId` values are unique per product
- On the consumer topic extractor, messages missing `orgName` or `productType` headers are skipped by design

---

## Step5: Containerized Deployment Using DSI Provided Container Images

This section covers deployment using **custom container images** published by DSI to the `ghcr.io/energy-dsi` image repository. Organisations using this approach pull DSI-provided images directly rather than building container images via CI pipelines.

Data Pipeline service images are found in GHCR with following name

| Image Name | GHCR Path | Tag |
|---|---|---|
| dpn-producer-file-adaptor-generic | `ghcr.io/energy-dsi/dpn-producer-file-adaptor-generic` | `<version>` |
| dpn-producer-topic-adaptor-generic | `ghcr.io/energy-dsi/dpn-producer-topic-adaptor-generic` | `<version>` |
| dpn-consumer-file-extractor | `<IMAGE_REGISTRY>/dpn-consumer-file-extractor` (e.g. `ghcr.io/energy-dsi/dpn-consumer-file-extractor`) | `<version>` |
| dpn-consumer-topic-extractor | `<IMAGE_REGISTRY>/dpn-consumer-topic-extractor` (e.g. `ghcr.io/energy-dsi/dpn-consumer-topic-extractor`) | `<version>` |
| dpn-self-service | `ghcr.io/energy-dsi/dpn-self-service` | `<version>` |

The producer and Self-Service registry paths come from the Self-Service AWS values file (`imageRegistry`, `env.DPN_IMAGE_REGISTRY`); the consumer path comes from the config JSON's `IMAGE_REGISTRY`.

Image access setup and the workflow trigger are covered in [Step2](#step2-install-dpn-data-pipeline) above — there is no separate GHCR-specific workflow to run, `dpn-gha-self-service-cd.yml` already deploys from these GHCR images by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
