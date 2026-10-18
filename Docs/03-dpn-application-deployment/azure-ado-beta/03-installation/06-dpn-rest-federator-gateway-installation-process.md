# DPN REST Federator Gateway Installation Process

This document covers the installation of the **DPN REST Federator Gateway** — a synchronous, HTTPS-based alternative to the gRPC Federator Gateway — into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end flow — overview, endpoint behaviour and release scope, prerequisites, secrets, the values to populate, deployment, and verification — is documented in one place:

**[Configure DPN REST Federator Gateway](../02-configuration/06-configure-dpn-rest-federator-gateway.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault and the Certificate Manager.** Complete [Vault installation](01-dpn-vault-installation-process.md) and [Certificate Manager installation](04-dpn-certificate-manager-installation-process.md) first — this gateway reads its certificate material directly from Vault (no shared file share), the same way the gRPC Federator Gateway does. It is independent of the gRPC Federator Gateway itself — the two can be installed in either order, or one without the other.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CI/CD Pipelines](#step2-execute-cicd-pipelines)
  - [Step2a. Execute CI Pipeline](#step2a-execute-ci-pipeline)
  - [Step2b. Verify CI Pipeline Execution](#step2b-verify-ci-pipeline-execution)
  - [Step2c. Execute CD Pipeline](#step2c-execute-cd-pipeline)
  - [Step2d. Verify CD Pipeline](#step2d-verify-cd-pipeline)
- [Step3: Reference Implementation - Demo Runner Server and Client](#step3-reference-implementation---demo-runner-server-and-client)
  - [Step3a. Prerequisites](#step3a-prerequisites)
  - [Step3b. Execute CI Pipeline](#step3b-execute-ci-pipeline)
  - [Step3c. Execute CD Pipeline](#step3c-execute-cd-pipeline)
  - [Step3d. Verify Deployment](#step3d-verify-deployment)
- [Step4: Containerized Deployment Using DSI Provided Container Images](#step4-containerized-deployment-using-dsi-provided-container-images)
  - [Step4a. Configure GHCR Image Access](#step4a-configure-ghcr-image-access)
  - [Step4b. Execute CD Pipeline](#step4b-execute-cd-pipeline)
  - [Step4c. Verify CD Pipeline](#step4c-verify-cd-pipeline)
- [Step5: Troubleshooting](#step5-troubleshooting)
  - [403 from a consumer that should be authorised](#403-from-a-consumer-that-should-be-authorised)
  - [502/504 from the backend proxy](#502504-from-the-backend-proxy)
  - [403 OCSP certificate check failure](#403-ocsp-certificate-check-failure)
  - [Invalid Keystore/Truststore Password](#invalid-keystoretruststore-password)
- [Review Notes](#review-notes)

---

## Overview

The REST Federator Gateway is deployed from the following location on the repository.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── rest-federator-cd.yml
```

Key points, detailed in the configuration guide:
- The gateway builds its mTLS keystore/truststore **in memory from Vault** with same mechanism as the gRPC Federator and Certificate Manager.
- Vault authentication uses **AppRole** in this chart (`vault.authMethod: approle`).
- The repository also ships a self-contained reference implementation — the Demo Runner Server and Client — used to exercise the gateway end-to-end (see Step3).

---

## Step1: Verify Prerequisites

Confirm the prerequisites are met before starting — see [Configure DPN REST Federator Gateway → Step1: Meet the Prerequisites](../02-configuration/06-configure-dpn-rest-federator-gateway.md#step1-meet-the-prerequisites).

In summary:

- Vault and Certificate Manager deployed and in running state
- Certificate Manager's certificate SANs include this gateway's endpoint (e.g. `producer-rest01.<dpn>...`)
- `cert-manager-truststore` secret present; Vault AppRole identity provisioned for this component (recommended) or the root token
- A backend service to proxy to, and its API key created (`dpn-backend-api-key`, or via Key Vault)
- IDP client ID and Management Node URL received from DSM
- Populated `values-<env>-<cluster>.yaml`

**Note:** Organisations must review the CI/CD Pipeline codes for the following, as with every other DPN component:

- The agent pool name has been modified to Organisation required agent pool name
- There should not be any `<<Your specific value>>` in the parameters
- The environment parameters are pointing to correct deployment environment
- The DSM/Management Node endpoints are correctly pointing to respective pdev, ptest or puat environments

---

## Step2: Execute CI/CD Pipelines

### Step2a. Execute CI Pipeline

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── rest-federator-ci.yaml
```

The CI pipeline builds and scans the server image. It then pushes it to the configured registry.

### Step2b. Verify CI Pipeline Execution

Confirm the image was pushed with the expected build tag:

```text
dpn-rest-federator-server:`<image tag>`
```

### Step2c. Execute CD Pipeline

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── rest-federator-cd.yml
```

The pipeline runs two stages, each with its own approval gate and each independently rollback-able: **Deploy_Redis** → **Deploy_RestFederator**.

| Parameter | Description |
|-----------|-------------|
| `ServiceConnection` | Azure service connection for your environment |
| `environment` | Your target environment |
| `cluster` | The target DPN cluster — `dpn01` or `dpn02` |
| `imageTag` | Tag of the REST Federator Server image to deploy (the CI run's build ID) |

### Step2d. Verify CD Pipeline

```bash
kubectl get pods -n <namespace>   # check for dpn-rest-federator-server-1-XXXXXX and the dpn-redis pod
kubectl logs -f dpn-rest-federator-server-1-XXXXXXXXX
kubectl get svc -n <namespace>    # confirm the gateway's ClusterIP/LB and port (8080 by default)
```

The kubectl logs should not show any Vault authentication or keystore-build errors on start-up.

---

## Step3: Reference Implementation - Demo Runner Server and Client

The repository ships a self-contained example integration under `demo/demo-runner-server` and `demo/demo-runner-client`, used to exercise the REST Federator Gateway end-to-end without needing a participant's own backend or consumer application. The sequence follows the asset registration specification, with paths prefixed `/api/v1/fmar` for consistency with the gateway's other routes.

**Demo Runner Server** is a minimal Spring Boot backend that sits behind the gateway as the example "producer's backend" (`restFederatorServer.backend.baseUrl`). It terminates its own HTTPS using the shared `dpn-tls` keystore and does not talk to Vault directly. The gateway-to-backend hop is authenticated with a shared API key header (`X-Backend-Api-Key`), sourced from the same `dpn-backend-api-key` Secret the gateway itself is configured with. It exposes an in-memory FMAR asset registration API, Swagger UI (`/swagger-ui.html`), and standard Kubernetes health probes.

**Demo Runner Client** is a one-shot Kubernetes Job that imports the `rest-federator-client` library exactly as a real consumer integration would, and drives a six-step demo sequence against a producer's FMAR endpoints through the gateway:

1. Query the asset before registration (expect not found)
2. Register the asset (`POST`)
3. Query the asset after registration (expect found)
4. Register the same MPAN again (expect conflict)
5. Call a path outside the product's allowed-path configuration (expect rejection — demonstrates the gateway's own enforcement, not just the client library's)
6. Register with a payload missing a required field (expect rejection)

By default the client targets every organisation/product it is subscribed to (set specific values in the chart's `values-<env>-<cluster>.yaml` to narrow this). The `mpan`, `postcode`, `assetId`, and `fspId` run parameters below control the registration payload; the client runs as a new Kubernetes Job object each time it is triggered (a Job's pod spec is immutable), and completed Jobs are kept for one hour so their logs remain inspectable.

### Step3a. Prerequisites

- The REST Federator Gateway (`dpn-rest-federator`) already deployed and healthy — the demo client calls through it.
- `dpn-backend-api-key` Secret created with the same value the gateway sends as `X-Backend-Api-Key`, so the Demo Runner Server accepts the gateway's requests.
- Vault AppRole/token access provisioned for the Demo Runner Client the same way as the gateway — it builds its own mTLS material from Vault at start-up.
- At least one organisation/product already registered as a subscription on the Management Node, so the client's registry bootstrap has a target to run against.

### Step3b. Execute CI Pipeline

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── demo-runner-ci.yml
```

Builds and scans both the Demo Runner Server and Demo Runner Client images (Checkmarx, FOSSA, unit tests with JaCoCo coverage, SonarQube), then packages, signs, and pushes both images to the configured registry.

### Step3c. Execute CD Pipeline

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── demo-runner-cd.yml
```

Two independently-toggleable stages, each gated by its own environment approval: **Deploy_DemoRunnerServer** → **Run_DemoRunnerClient**.

| Parameter | Description |
|-----------|-------------|
| `ServiceConnection` | Azure service connection for your environment |
| `environment` | Your target environment |
| `cluster` | The target DPN cluster — `dpn01` or `dpn02` |
| `imageTag` | Tag of the Demo Runner images to deploy (the CI run's `Build.BuildId`) |
| `deployServer` | Deploy the Demo Runner Server (default `true`) |
| `runClient` | Run the Demo Runner Client Job (default `true`) |
| `mpan` | Import MPAN, 13 digits (default `1000000000001`) |
| `postcode` | Postcode (default `SW1A 1AA`) |
| `assetId` | Asset id — a UUID, or `none` to omit it |
| `fspId` | FSP id — a UUID, or `none` for a randomly generated one |

### Step3d. Verify Deployment

```bash
kubectl get pods -n <namespace>          # dpn-demo-runner-server-XXXXXX, plus a completed dpn-demo-runner-client-<buildId> Job
kubectl logs job/dpn-demo-runner-client-<buildId> -n <namespace>
```

Expect the six-step FMAR sequence to print through to completion. Each step's outcome (not found / conflict / rejection / bad request) is expected demo behaviour, not a failure — only an unexpected exception or a step succeeding when it should have been rejected indicates a real problem.

---

## Step4: Containerized Deployment Using DSI Provided Container Images

This section covers deployment using **custom and 3rd party open source container images** published by DSI to `ghcr.io/energy-dsi` image repository. Organisations using this approach pull DSI-provided images directly rather than building container images via CI pipelines.

| Image Name | GHCR Path | Tag |
|---|---|---|
| dpn-rest-federator-server | `ghcr.io/energy-dsi/dpn-rest-federator-server` | `e.g. 1.0.0` |
| dpn-demo-runner-server | `ghcr.io/energy-dsi/dpn-demo-runner-server` | `e.g. 1.0.0` |
| dpn-demo-runner-client | `ghcr.io/energy-dsi/dpn-demo-runner-client` | `e.g. 1.0.0` |

### Step4a. Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`.

Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably. Unauthenticated pulls are subject to strict rate limits and may fail in automated environments.

Create a GitHub Personal Access Token with `read:packages` scope. Once the token is available, create a kubernetes secret from the same. This secret will be used during the image pull.

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

### Step4b. Execute CD Pipeline

Reuse existing `rest-federator-cd.yml` (for the gateway) and `demo-runner-cd.yml` (for the demo apps) pipelines that use image repository from `CONTAINER_REGISTRY_URL` in the environment's config file. Point the value at `ghcr.io/energy-dsi` for the target environment before running the pipeline, so the deployed `image.repository` resolves against GHCR.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── rest-federator-cd.yml   (gateway)
            └── demo-runner-cd.yml      (demo apps, optional)
```

The CD Pipeline would require the following run time parameters.

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |
| `imageTag` | Provides the release version or image tag to be pulled from GHCR |

Execute the pipeline(s) to perform deployment.

---

### Step4c. Verify CD Pipeline

Follow the same verification steps mentioned in Step2d (and Step3d if the demo apps were also deployed).

---

## Step5: Troubleshooting

### 403 from a consumer that should be authorised

The gateway denies by default. A `403` means one of: the caller is not in the product's consumer list (fetched from the Management Node), the caller's certificate failed the OCSP check, or the request's method/path does not match the product's allowed-path configuration. Confirm the product's configuration on the Management Node side first — this is not a gateway-side value to edit.

### 502/504 from the backend proxy

The gateway forwards authorised requests verbatim to `restFederatorServer.backend.baseUrl`. A `502`/`504` means the configured backend is unreachable from inside the cluster, or is rejecting the shared API key (`X-Backend-Api-Key`, from `dpn-backend-api-key`) — confirm the backend is up and the secret's value matches what the backend expects.

### 403 OCSP certificate check failure

Same cause and remedy as the gRPC Federator — see [Federator Gateway Installation → PKIX/OCSP troubleshooting](05-dpn-federator-gateway-installation-process.md#403-ocsp-certificate-check-failure).

### Invalid Keystore/Truststore Password

Same cause and remedy as the Certificate Manager — see [Certificate Manager Installation → Invalid Keystore/Truststore Password](04-dpn-certificate-manager-installation-process.md#invalid-keystoretruststore-password). There are no P12 files on disk for this gateway either — the keystore/truststore are built in memory from the same Vault material.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 | 
| Oct-2026 | DSI Assurance   | Final  | V1.1.0 | 

