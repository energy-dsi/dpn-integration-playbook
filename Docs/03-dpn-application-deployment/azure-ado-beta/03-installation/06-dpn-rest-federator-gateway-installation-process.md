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
- [Step3: Troubleshooting](#step3-troubleshooting)
  - [403 from a consumer that should be authorised](#403-from-a-consumer-that-should-be-authorised)
  - [502/504 from the backend proxy](#502504-from-the-backend-proxy)
  - [403 OCSP certificate check failure](#403-ocsp-certificate-check-failure)
  - [Invalid Keystore/Truststore Password](#invalid-keystoretruststore-password)
- [Review Notes](#review-notes)

---

## Overview

The REST Federator Gateway is deployed from the `dpn-rest-federator-gateway` repository as **two independent Helm releases**, each its own CD stage: `dpn-redis` (the cache this chart owns) and `dpn-rest-federator` (the gateway itself). Unlike the gRPC Federator's single combined `dpn-platform` release, these can be rolled back independently of each other.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── rest-federator-cd.yml
```

Key points, detailed in the configuration guide:
- The gateway builds its mTLS keystore/truststore **in memory from Vault** — no shared file share is used, the same mechanism as the gRPC Federator and Certificate Manager.
- Vault authentication defaults to **AppRole** in this chart (`vault.authMethod: approle`), not just token.
- There is no dedicated GHCR-based containerized deployment pipeline for this repository today — only the standard CI/CD pipelines below.

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

- DSI Package contains certain tool usage recommendations to run CI pipeline (Checkmarx, FOSSA, SonarQube, JFrog X-Ray). These steps should be carefully reviewed by Organisations and kept only where relevant
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

The CI pipeline builds and scans the server image (Checkmarx, FOSSA, SonarQube, JaCoCo, cosign image signing, JFrog X-Ray) and pushes it to the configured registry.

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

## Step3: Troubleshooting

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

| Review Date | Last Reviewed By | Status | Version |
|-------------|-------------------|--------|---------|
| — | — | Draft — pending DSI Assurance review | V0.1.0 |
