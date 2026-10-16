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

- `dpn-data-pipelines` — the data pipeline source, blueprints and Helm charts live in this repository, and the CD workflows under `.github/workflows/`

The deployment process consists of:

- **Continuous Integration (CI)** — builds the container images (see [Step2a](#step2a-data-pipeline-ci-component-source-repository))
- **Continuous Deployment (CD)** — deploys into **Amazon Elastic Kubernetes Service (EKS)** with the **`DPN CD - Self-Service Data Pipelines`** workflow (`dpn-gha-self-service-cd.yaml`), which installs three Helm releases into `ns-dpn-dp-01`:
  - `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` — the two fixed consumer pipelines
  - `dpn-self-service` — the DPN Self-Service UI

**Producer data products are not deployed by a workflow.** They are created at runtime from the Self-Service UI, which launches the generic producer image with that product's configuration (see [Step3](#step3-create-the-first-data-product) and the [DPN Data Pipeline UI Operations guide](../../../05-dpn-user-interfaces/11-dpn-data-pipeline-ui-operations.md)). No per-product CI/CD run, folder copy or image build is required.

> **Upgrading from an earlier release:** data products deployed as separate per-product producer/consumer Helm releases are **not automatically imported** into the Self-Service UI. Recreate each one through the UI after this installation (see [Step3](#step3-create-the-first-data-product)), then remove the old releases as described in [Uninstall and Decommissioning](../05-uninstall/05-uninstall-decommissioning.md).

---

## Step1: Installation Prerequisites

The following prerequisites must be completed before beginning the installation process.

### Step1a. Clone and Prepare Source Repositories

Clone the official repository from GitHub.

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
- The data pipeline namespace `ns-dpn-dp-01` created once on the cluster. `dpn-gha-self-service-cd.yaml` checks for it and fails if it is missing:

  ```bash
  kubectl create namespace ns-dpn-dp-01
  ```

- IRSA (IAM Roles for Service Accounts) enabled on the EKS cluster, with the IAM role referenced by `serviceAccount.irsaRoleArn` in the Self-Service AWS values files (`service/charts/values/aws/<environment>-<cluster>.yaml`, role `dpn-data-pipeline-s3-role`) created beforehand — `dpn-gha-self-service-cd.yaml` does not create it. See [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table) in the Configuration Guide
- DPN Streaming Service (Kafka) deployed, with SASL/TLS authentication through DPN Authentication Service (Keycloak). Topics do **not** need to be pre-created; the pipeline creates them (see the [Configuration Guide overview](../02-configuration/07-configure-dpn-data-pipelines.md#overview))
- DPN Health Monitoring Service deployed and OTEL collector container is in running state
- S3 buckets for the `file` integration pathway are created by the pipeline when needed (see the [Configuration Guide overview](../02-configuration/07-configure-dpn-data-pipelines.md#overview))
- Kubernetes secrets created in `ns-dpn-dp-01` (`dpn-tls`, `tls-auth-secret`, `dpn-keycloak-secrets`, `dpn-health-ca`, `ghcr-pull-secret` — see [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table)). On the first deployment into a new environment, restart the pods once the secrets exist; see [One-time setup for a new environment](#one-time-setup-for-a-new-environment-create-secrets-and-restart-pods).
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

All CD workflows, their per-cloud configuration and the charts they deploy live in the `dpn-data-pipelines` repository itself:

```
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
│       └── aws/<environment>-<cluster>.json
├── blueprints/{producer,consumer}/{file,topic}/{adaptor|extractor}/charts/values.yaml
└── service/charts/values/aws/<environment>-<cluster>.yaml
```

`dpn-gha-self-service-cd.yaml` reads `.github/config/aws/<environment>-<cluster>.json` (`AWS_REGION`, `AWS_ACCOUNT_ID`, `EKS_CLUSTER`, `IMAGE_REGISTRY`, and the optional `OAUTH2_PROXY_EXTERNAL_URL`) and logs in through the repository's `.github/actions/cloud-login` action with `cloud: aws`. The AWS login uses GitHub OIDC role-chaining into the target account's `oidc_github_runner_admin` role, so no AWS secret is stored in GitHub, but that role and its trust must exist.

All workflows run on a self-hosted runner with the labels `[self-hosted, vmss]` (register a runner with those labels, or change `runs-on` to a runner pool you control) and use the GitHub Environment `<environment>-<cluster>` (for example `test-dpn01`), which must exist in the repository.

---

### Step1d. Configure Environment Approval Gates

There is no ADO-style approval-check concept for GitHub Actions workflows by default. If you want a manual sign-off before running the CD workflow against a given environment, configure a required reviewer on the corresponding GitHub Environment (`<environment>-<cluster>`).

---

## Step2: Install DPN Data Pipeline

The DPN Data Pipeline is a set of single-container pipeline stages — one producer adaptor per data product and one consumer extractor per pathway — as outlined in the [Configuration Guide](../02-configuration/07-configure-dpn-data-pipelines.md#overview).


---

### Step2a. Data Pipeline CI (component source repository)

CI (build, test, and image push to GHCR) for the data pipeline components is not part of the repository's GitHub Actions workflows, which cover CD only — build images via your own CI process, or use the DSI-provided prebuilt GHCR images .

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

Go to **Actions → DPN CD - Self-Service Data Pipelines → Run workflow** (`dpn-gha-self-service-cd.yaml`), and supply:

| Input | Value |
|---|---|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | `dpn01` / `dpn02` (default `dpn01`) |
| `cloud` | `aws` (default `aws`; the input also offers `azure` and `gcp`) |
| `imageTag` | The image tag to deploy |

In one run it:

1. Verifies the `ns-dpn-dp-01` namespace exists.
2. Installs `dpn-consumer-file-extractor` and `dpn-consumer-topic-extractor` from `blueprints/consumer/{file,topic}/extractor/charts`, applying `values/aws/<environment>-<cluster>.yaml` only if the chart ships one (otherwise the chart defaults are used), setting `imageRegistry` to the config JSON's `IMAGE_REGISTRY`, `imageName` to the release name, `imageTag` to the input and `cloudProviderType` to `aws`.
3. Installs `dpn-self-service` from `service/charts` with `values/aws/<environment>-<cluster>.yaml` (checked in for `dev-dpn01`, `dev-dpn02`, `test-dpn01` and `test-dpn02`). The oauth2-proxy (Keycloak login, HTTPS) is enabled with `oauth2Proxy.externalUrl` set to the config JSON's `OAUTH2_PROXY_EXTERNAL_URL`, or else to the hostname of the existing `dpn-self-service-external` LoadBalancer. On a first deploy with neither, it installs once with the proxy off, waits up to 3 minutes for AWS to assign an NLB hostname, then redeploys with the proxy on — register `<that URL>/oauth2/callback` on `dpn-service-client` afterwards (the workflow prints a warning with the URL).

> **Notes:**
> - Consumer scheduling defaults to `SCHEDULER_BACKEND: interval`. This is preconfigured in the consumer charts' values; keep the default (see the [Configuration Guide overview](../02-configuration/07-configure-dpn-data-pipelines.md#overview)).
> - The `imageTag` input is applied to the three Helm releases, and is also passed to the Self-Service UI as `env.DPN_IMAGE_TAG`, so UI-created producers run the same tag.
> - One other data pipeline CD workflow exists: **DPN CD - Data Pipelines** (`dpn-gha-data-pipelines-cd.yaml`, inputs `environment`, `cluster`, `cloud`, `configType`, `processType`, `productType`, `schemaType`, `imageTag`, optional `imageName`) helm-installs a single reference chart, `blueprints/<configType>/<processType>/<adaptor|extractor>/charts`, as release `dpn-<configType>-<processType>-<adaptor|extractor>-<productType>` into the config JSON's `NAMESPACE`; with `cloud: aws` and `processType: file` it also creates the source/target S3 buckets and the chart's IRSA role. Use `dpn-gha-self-service-cd.yaml` for the standard deployment.

##### One-time setup for a new environment: create secrets and restart pods

Every time the DPN Data Pipeline is deployed into a **new environment** (a new `<environment>-<cluster>`), do the following once:

1. Create the secrets the data pipeline pods read, in `ns-dpn-dp-01`, as described in the [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table). Confirm they exist:

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

> **Rollback and uninstall:** the three releases are rolled back with **DPN Rollback - Self-Service Data Pipelines** (`dpn-gha-self-service-rollback.yaml`, inputs `environment`, `cluster`, `cloud`, `release_name`, `targetRevision`, `confirm`) and removed with **DPN Uninstall - Self-Service Data Pipelines** (`dpn-gha-self-service-uninstall.yaml`, inputs `environment`, `cluster`, `cloud`, `release_name`, `confirm`; `release_name` can also be `all`). Neither touches UI-created producer Deployments, which are managed from the UI. Releases deployed by `dpn-gha-data-pipelines-cd.yaml` in `NAMESPACE` have their own **DPN Rollback - Data Pipelines** (`dpn-gha-data-pipelines-rollback.yaml`) and **DPN Uninstall - Data Pipelines** (`dpn-gha-data-pipelines-uninstall.yaml`) workflows. See [Rollback Procedures](../04-rollback/04-rollback-procedures.md) and [Uninstall and Decommissioning](../05-uninstall/05-uninstall-decommissioning.md).

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

Verify clean logs inside the container:

```bash
kubectl logs <pod-name> -n ns-dpn-dp-01
```

---

## Step3: Create the First Data Product

Producer data products are created from the Self-Service UI, not from a workflow.

1. Open the UI at the address from [Step2e](#step2e-validate-data-pipeline-cd-workflow) and sign in with a user holding the `dpnadmin` role (only `dpnadmin` can create products).
2. Create a data product following the [DPN Data Pipeline UI Operations guide](../../../05-dpn-user-interfaces/11-dpn-data-pipeline-ui-operations.md): choose the `product_type`, the `file` or `topic` pathway and the schedule, then review and confirm the proposed names.
3. Verify that a Deployment named `dpn-producer-<pathway>-<product_type>` is running:

   ```bash
   kubectl get deployments -n ns-dpn-dp-01
   ```

4. Use **Run Now** and the logs view in the UI to confirm a first cycle completes. See the [DPN Data Pipeline UI Operations guide](../../../05-dpn-user-interfaces/11-dpn-data-pipeline-ui-operations.md) for the other actions.

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

- Confirm the image reference (`imageRegistry`/`imageName`/`imageTag`) matches an actual published tag — a typo here produces the same failure as a genuine access issue. The config JSON's `IMAGE_REGISTRY`, when set, overrides `imageRegistry` for all three releases; otherwise the value in each chart's values file is used.

- For products created from the UI, confirm the Self-Service values set the correct `env.DPN_IMAGE_REGISTRY`, `env.DPN_IMAGE_TAG` and `env.DPN_IMAGE_PULL_SECRET`, since the UI passes these to the producer pods it creates.

---

### Values File Not Found

`dpn-gha-self-service-cd.yaml` applies `values/aws/<environment>-<cluster>.yaml` only when it exists, and uses the chart defaults otherwise. For `service/charts`, AWS values are checked in for `dev-dpn01`, `dev-dpn02`, `test-dpn01` and `test-dpn02`; add one for any other environment/cluster, because the Self-Service AWS settings (IRSA role, registry, pull secret) live there.

`dpn-gha-data-pipelines-cd.yaml` always passes `-f <chart>/values/<cloud>/<environment>-<cluster>.yaml`, so `helm upgrade` fails if that file does not exist. The blueprint charts do not currently ship a `values/` folder; add the file for your environment/cluster before running that workflow.

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

HPA is disabled by default and should stay disabled while `SCHEDULER_BACKEND: interval` is in use (see the [Configuration Guide overview](../02-configuration/07-configure-dpn-data-pipelines.md#overview)).

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

The producer registry path comes from the Self-Service AWS values file (`env.DPN_IMAGE_REGISTRY`); the consumer and Self-Service paths come from the config JSON's `IMAGE_REGISTRY` (falling back to `imageRegistry` in the values file when it is not set).

Image access setup and the workflow trigger are covered in [Step2](#step2-install-dpn-data-pipeline) above — there is no separate GHCR-specific workflow to run, `dpn-gha-self-service-cd.yaml` already deploys from these GHCR images by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
