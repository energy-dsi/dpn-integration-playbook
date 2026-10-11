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
  - [STEP-02a: Execute Data Pipeline CI Workflow](#step-02a-execute-data-pipeline-ci-workflow)
  - [STEP-02b: Validate Data Pipeline CI Workflow](#step-02b-validate-data-pipeline-ci-workflow)
  - [STEP-02c: Execute Data Pipeline CD Workflow](#step-02c-execute-data-pipeline-cd-workflow)
  - [STEP-02d: Validate Data Pipeline CD Workflow](#step-02d-validate-data-pipeline-cd-workflow)
- [STEP-03: Create the First Data Product](#step-03-create-the-first-data-product)
- [STEP-04: Troubleshooting](#step-04-troubleshooting)
  - [CI Workflow Failure](#ci-workflow-failure)
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

- **Continuous Integration (CI)** — tests, builds and pushes **five container images** to the GitHub Container Registry (GHCR) under `ghcr.io/energy-dsi/dsi/`:

  | Image | Purpose |
  |-------|---------|
  | `dpn-producer-file-adaptor-generic` | Generic producer image for the file pathway |
  | `dpn-producer-topic-adaptor-generic` | Generic producer image for the topic pathway |
  | `dpn-consumer-file-extractor` | Consumer file extractor |
  | `dpn-consumer-topic-extractor` | Consumer topic extractor |
  | `dpn-self-service` | DPN Self-Service UI |

- **Continuous Deployment (CD)** — deploys into **Amazon Elastic Kubernetes Service (EKS)** using Helm:
  - the **Self-Service UI**, and
  - the two **consumer pipelines** (one file extractor, one topic extractor).

**Producer data products are not deployed by the workflows.** They are created at runtime from the Self-Service UI, which launches the generic producer image with that product's configuration (see [STEP-03](#step-03-create-the-first-data-product) and the [Configuration Guide](../02-configuration/07-configure-dpn-data-pipelines.md#step-01-set-up-a-new-data-product-self-service)). No per-product CI/CD run, folder copy or image build is required.

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

If the organisation runs the workflows from its own GitHub organisation, push the code to that repository.

```bash
git remote add org https://github.com/<org>/<repository>.git
git push -u org main
```

---

### STEP-01b: Prepare Infrastructure and Application Prerequisites

Ensure the following prerequisites are completed before deployment:

- EKS cluster provisioned and accessible, with the **metrics-server** add-on running
- GHCR access: a GitHub PAT with `read:packages` scope, used to create the `ghcr-pull-secret` image pull secret (not required if the images are mirrored to ECR and the EKS nodes can pull from it through their IAM role)
- An IAM role for the CD workflow's `roleToAssume` input, trusted through GitHub OIDC for the repository, with `eks:DescribeCluster` permission, mapped into the EKS cluster's Kubernetes authentication (`aws-auth` ConfigMap or EKS access entry) and bound to the namespace-scoped Role/RoleBinding in `dpn-self-service-eks-rbac.yaml`
- DPN Streaming Service (Kafka) deployed, with SASL/TLS authentication through DPN Authentication Service (Keycloak) — see [Configure Kafka Security](../02-configuration/07-configure-dpn-data-pipelines.md#step-08b-configure-kafka-security-sasltls). Topics do **not** need to be pre-created; the pipeline creates them (see [DPN Streaming Service (Kafka)](../02-configuration/07-configure-dpn-data-pipelines.md#step-09b-configure-streaming-service-kafka))
- DPN Health Monitoring Service deployed and the OTEL collector container in a running state
- AWS account and region available for the `file` integration pathway. S3 buckets are created by the pipeline — see [Storage Blob / S3 Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step-09a-storage-blob--s3-configuration)
- The following Kubernetes secrets created **in the data pipeline namespace** (`ns-dpn-dp-01` by default) before the CD workflow runs. The containers refuse to start without valid values:

  | Secret | Purpose |
  |--------|---------|
  | `dpn-tls` | Kafka truststore (`truststore.jks`), mounted into pods |
  | `tls-auth-secret` | `TRUSTSTORE_PASSWORD` and `KEYSTORE_PASSWORD` |
  | `dpn-keycloak-secrets` | Keycloak client secret (`KC_SERVICE_CLIENT_SECRET`) |
  | `dpn-health-ca` | CA bundle for the OTEL collector's TLS listener |
  | `aws-access-secret` | `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` used by the Self-Service UI, the file producers and the consumer file extractor |
  | `ghcr-pull-secret` | Pull secret for the private GHCR registry |

  See [Secrets Configuration](../02-configuration/07-configure-dpn-data-pipelines.md#step-08-configure-secrets) for the contents of each.
- Keycloak client `dpn-service-client` configured for the Self-Service UI login: **Standard flow** enabled, and the UI's `<externalUrl>/oauth2/callback` registered as a valid redirect URI. The realm roles `dpnadmin`, `dpnoperator` and `dpnreader` assigned to the people who will use the UI.
- Network and firewall rules applied as described in [Network and Ports Configuration](../02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration), including outbound access to `ghcr.io`
- Software prerequisites (GitHub Actions access)

[Refer to the **Prerequisites** and **Configuration** documentation for details](../01-prerequisites/01-dpn-prerequisites.md)

**Note:** Organisations must review the CI/CD workflow code for the following.

- If running your own CI, keep only the relevant test, build and image-push steps. DSI's own CI examples may include tools such as Checkmarx, SonarQube and JFrog X-Ray that your organisation does not need.
- The container registry (`IMAGE_REGISTRY`) points to `ghcr.io/energy-dsi`, or to the organisation's own registry if images are mirrored.
- There should not be any placeholder values (for example `AWS_ACCOUNT_ID`, `AWS_REGION`, `EKS_CLUSTER`, `NAMESPACE`) left in the per-environment configuration files under `.pipelines/github-actions-pipelines/aws-pipelines/config/` (for example `dev-dpn01.json`). The DSI package provides these to ensure configuration is modified by Organisations.
- The GitHub Environments used for approval exist (see [STEP-01d](#step-01d-configure-environment-approval-gates)).
- Required firewall rules are applied.
- Both CI and CD workflows are verified for the above before execution.

---

### STEP-01c: Identify Pipeline Repository Structure

The repository includes the necessary CI and CD workflows in the following folder structure for reference.

```text
Root-Repository/
└── .pipelines/
    └── github-actions-pipelines/
        └── aws-pipelines/
            ├── ci-pipelines/
            │     └── dpn-self-service-ci.yaml
            ├── cd-pipelines/
            │     ├── dpn-self-service-cd.yaml
            │     ├── dpn-self-service-rollback.yaml
            │     ├── dpn-self-service-uninstall-cd.yaml
            │     ├── dpn-self-service-eks-rbac.yaml
            │     └── dpn-self-service-eks-setup.md
            └── config/
                  └── <environment>-<cluster>.json
```

> **Note:** The AWS GitHub Actions workflows are currently not present on the `develop` branch of `dpn-data-pipelines`. If they are missing from the branch you cloned, restore them from the repository's git history (the commit before `Temporarily remove AWS GitHub Actions pipelines`). `dpn-self-service-eks-setup.md` contains the one-time EKS setup steps.

---

### STEP-01d: Configure Environment Approval Gates

There is no ADO-style approval-check concept for GitHub Actions workflows by default. The CD workflow has a single approval gate that uses a GitHub Environment named `dpn-self-service-<environment>` (for example `dpn-self-service-dev`). Before running the CD workflow, create each environment (Repository Settings → Environments) and configure the required reviewers for it. The same environments are used by the rollback and uninstall workflows.

---

## STEP-02: Install DPN Data Pipeline

The DPN Data Pipeline is deployed as a Self-Service UI plus two fixed consumer pipelines. Each pipeline stage runs in a single container; there are no separate adaptor and mapper components to deploy.

---

### STEP-02a: Execute Data Pipeline CI Workflow

Run the CI workflow `dpn-self-service-ci.yaml` (**DPN Self-Service — CI (Build, Test, Push)**) from the Actions tab. It builds all five images in one run and takes no inputs. The image tag is the run's own `github.run_number`, so dispatching the workflow never prompts for a tag.

The workflow stages are:

1. **Unit Tests** — pytest with coverage; test and coverage results are published as artifacts.
2. **Build, Push & Record Digests** — builds the five images, pushes them to GHCR under `ghcr.io/energy-dsi/dsi/<image>:<tag>` using the workflow's own `GITHUB_TOKEN`, and records each image digest as an artifact.

> **Note:** Record the **image tag** (the run number shown in the Actions run header). It is the `imageTag` input for the CD workflow.

---

### STEP-02b: Validate Data Pipeline CI Workflow

Verify that GHCR contains all five packages under `dsi/` with the expected image tag. In the GitHub organisation, open **Packages**, or use the API:

```bash
gh api /orgs/energy-dsi/packages/container/dsi%2Fdpn-producer-file-adaptor-generic/versions --jq '.[].metadata.container.tags'
```

---

### STEP-02c: Execute Data Pipeline CD Workflow

Run the CD workflow `dpn-self-service-cd.yaml` (**DPN Self-Service — Deploy (AWS EKS)**) with the following inputs.

| Input | Value |
|-------|-------|
| `environment` | `dev` / `devtest` |
| `cluster` | `dpn01` / `dpn02` |
| `roleToAssume` | ARN of the IAM role assumed through GitHub OIDC (needs only `eks:DescribeCluster`) |
| `imageTag` | The image tag produced by the CI run in [STEP-02a](#step-02a-execute-data-pipeline-ci-workflow) |
| `KUBECTL_VERSION` | Optional. kubectl version without the leading `v` |
| `HELM_VERSION` | Optional. Helm version with the leading `v` |

Approve the deployment when the GitHub Environment approval gate is raised.

> **Notes:**
> - The CD workflow only runs `helm upgrade --install`. It never builds or pushes images, so the CI workflow must have completed first for the same image tag.
> - It deploys three Helm releases into the data pipeline namespace (`ns-dpn-dp-01`): `dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor` and `dpn-self-service`. The namespace itself is not created by the workflow and must exist already.
> - The Self-Service UI is deployed with `env.DPN_CLOUD_PROVIDER=aws` and `loadBalancer.cloud=aws`, which renders the internal EKS load balancer annotation. Also set `platformStorageSecretName=aws-access-secret`: the chart default is the Azure `producer-file-dp-secret`, which holds no AWS keys.
> - Consumer scheduling defaults to `SCHEDULER_BACKEND: interval`. Confirm the value in the consumer charts' `values.yaml` before running (see [Configure Scheduling](../02-configuration/07-configure-dpn-data-pipelines.md#step-06-configure-scheduling)).
> - Set `awsEndpointUrl` to an empty string for the consumer file extractor and the Self-Service UI so that S3 is addressed through the regional AWS endpoint.
> - Self-Service UI login (oauth2-proxy with Keycloak) is off by default in the chart. To enable it, deploy once, read the address assigned to `dpn-self-service-external`, then redeploy with `oauth2Proxy.enabled=true` and `oauth2Proxy.externalUrl=<address>` set.

To roll back or remove the platform, use `dpn-self-service-rollback.yaml` and `dpn-self-service-uninstall-cd.yaml`. They operate on the three Helm releases only. Producer data products created from the UI are not Helm releases; stop or delete them from the UI.

---

### STEP-02d: Validate Data Pipeline CD Workflow

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

Producer data products are created from the Self-Service UI, not from a workflow.

1. Open the UI at the address reported in [STEP-02d](#step-02d-validate-data-pipeline-cd-workflow) and sign in with a user holding the `dpnadmin` or `dpnoperator` role.
2. Create a data product following [Set Up a New Data Product (Self-Service)](../02-configuration/07-configure-dpn-data-pipelines.md#step-01-set-up-a-new-data-product-self-service): choose the `product_type`, the `file` or `topic` pathway and the schedule, then review and confirm the proposed names.
3. Verify that a Deployment named `dpn-producer-<pathway>-<product_type>` is running:

   ```bash
   kubectl get deployments -n ns-dpn-dp-01
   ```

4. Use **Run Now** and the logs view in the UI to confirm a first cycle completes.

---

## STEP-04: Troubleshooting

### CI Workflow Failure

Possible causes:

- GHCR push failure — verify the workflow has `packages: write` permission and the repository/organisation allows the workflow to publish to `ghcr.io/energy-dsi`.
- A security or quality stage added by the organisation (for example Checkmarx, SonarQube or JFrog X-Ray) failing or not configured — remove or replace the stage as described in [STEP-01b](#step-01b-prepare-infrastructure-and-application-prerequisites).
- Unit test failure in the pytest stage — review the published test results artifact.

Verify workflow logs and ensure all credentials and inputs are correct.

---

### Container Image Not Found

Check that the CI workflow pushed all five images to GHCR under the tag supplied to the CD workflow.

If the expected package or tag is not listed, re-run the CI workflow and ensure it completes without errors before running the CD workflow.

---

### Image Pull Failures

If pods show `ImagePullBackOff` or `ErrImagePull`:

- Confirm the `ghcr-pull-secret` exists in the target namespace and holds a valid, non-expired GitHub PAT with `read:packages`.
- Confirm the EKS nodes can reach `ghcr.io` (outbound firewall/NAT). If the images are mirrored to ECR instead, confirm the node group's IAM role has pull access.
- Confirm the image reference (`imageRegistry`/`imageName`/`imageTag`) matches an actual published tag. A typo produces the same failure as a genuine access issue.
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

- Invalid or missing environment variables — the container validates its configuration at start-up and reports the missing value (look for `config.validation.failed`). Check the Helm values for typographical errors or missing entries.
- Missing or incorrect AWS credentials — verify `aws-access-secret` exists with the correct keys, and that the IAM identity has the S3 permissions listed in [Configure Storage Secrets](../02-configuration/07-configure-dpn-data-pipelines.md#step-08a-configure-storage-secrets).
- `awsEndpointUrl` set to a non-AWS endpoint — it must be an empty string on AWS.
- Missing Kafka truststore secret or wrong `TRUSTSTORE_PASSWORD` — a wrong password fails the container deliberately rather than falling back.
- The Self-Service UI's cloud provider is wrong (`DPN_CLOUD_PROVIDER` must be `aws` on EKS) — the UI's registry restore at start-up then uses the wrong storage API and the pod never becomes healthy.

---

### Self-Service UI Not Reachable or Login Fails

- Confirm `dpn-self-service-external` has an address assigned (`kubectl get svc dpn-self-service-external -n ns-dpn-dp-01`). The EKS load balancer is internal, so the address is reachable only from inside the VPC or over a connected network.
- Confirm the Keycloak client `dpn-service-client` has **Standard flow** enabled and `<externalUrl>/oauth2/callback` registered as a valid redirect URI, plus the post-logout redirect URI and web origin.
- Confirm the user holds one of the realm roles `dpnadmin`, `dpnoperator` or `dpnreader`.
- A `401` on every request usually means the request bypassed oauth2-proxy (for example a `kubectl port-forward` straight to the pod). Access the UI through its external address.
- A `403` on an action means the user's role is not allowed: only `dpnadmin` and `dpnoperator` can create, start, stop and run products, and only `dpnadmin` can delete.

---

### Data Product Cannot Be Created

- **Name already exists** — every confirmed S3 bucket and Kafka topic name must be new. The pre-check blocks creation if the name already exists in the AWS account or on the broker. Choose a different name.
- **Invalid `product_type`** — use lowercase letters, digits and hyphens only, and keep the name short enough that `dpn-producer-<pathway>-<product_type>` stays within 63 characters.
- **Invalid container name** — bucket names must be 3–63 characters of lowercase letters, digits and single hyphens, starting and ending with a letter or digit. S3 bucket names are globally unique, so a name used by another AWS account is also rejected.
- **Pre-check hangs or fails** — confirm the UI pod can reach S3 and the Kafka broker, and that `aws-access-secret` is valid and allows `s3:CreateBucket` and `s3:ListBucket`.

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
