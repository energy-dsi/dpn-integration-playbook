# DPN Certificate Manager Installation Process

This document covers the installation of the **DPN Federator Certificate Manager (CLM)** into a single target environment on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Certificate Manager flow — overview, prerequisites, the values/secrets to populate, deployment, and post-deployment verification — is documented in one place:

**[Configure DPN Certificate Manager](../02-configuration/03-configure-dpn-certificate-manager.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault.** The Certificate Manager cannot run until the DPN HashiCorp Vault service is deployed, initialised, and loaded with the certificate bundle. Complete [Vault installation](01-dpn-vault-installation-process.md) first.

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
  - [Invalid Keystore/Trustore Password](#invalid-keystoretrustore-password)
  - [PKIX Certificate validation error](#pkix-certificate-validation-error)
  - [401 Unauthorised error from DSM Auth endpoint](#401-unauthorised-error-from-dsm-auth-endpoint)
- [Step4: Containerized Deployment Using DSI Provided Container Images](#step4-containerized-deployment-using-dsi-provided-container-images)
  - [Step4a. Configure GHCR Image Access](#step4a-configure-ghcr-image-access)
  - [Step4b. Execute CD Pipeline](#step4b-execute-cd-pipeline)
  - [Step4c. Verify CD Pipeline](#step4c-verify-cd-pipeline)
- [Review Notes](#review-notes)

---

## Overview

The Certificate Manager is deployed with a single Azure DevOps CD pipeline from the `dpn-federator-certificate-manager` repository. It is a headless Spring Boot service that renews the DSM-signed certificate and writes the keystore/truststore P12 files (and their passwords) to the shared file share for the Federator Gateway to consume.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── certificate-manager-cd.yaml
```
---

## Step1: Verify Prerequisites

Confirm the prerequisites before starting — see [Configure DPN Certificate Manager → Prerequisites](../02-configuration/03-configure-dpn-certificate-manager.md#step1-meet-the-prerequisites). 

In summary the following prerequisites must be met.

- Vault deployed/initialised/loaded with bootstrap certificate
- `cert-manager-truststore` secret present
- `VAULT-TOKEN`/`VAULT-TRUSTSTORE-PASSWORD` secrets are ready
- Health monitoring service is running state and OTEL Collector healthy
- Provisioned Azure File Share
- `azure-fileshare-secret` secret is created
- IDP client ID received from DSM
- Populated `config/<env>.json` and `values-<env>.yaml`

---

## Step2: Execute CI/CD Pipelines

The following steps describe the process of running CI/CD pipelines for DPN Federator Certificate Manager Service Components. 

### Step2a. Execute CI Pipeline

The Federator Certificate Manager CI pipeline yaml file is placed in this location to set up the CI pipeline.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── azure-pipelines-certificate-manager-ci.yaml
```

The CI pipeline requires the following paramters to be passed.

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |

### Step2b. Verify CI Pipeline Execution

Once the CI pipeline executes successfully a new image with image tag is pushed in the image registry mentioned in the configuration file. The image tag is mentioned in the pipeline clean up stage with build number numeric value. The image registry to be checked if the following image is pushed. 

```text
dpn-federator-certificate-manager:`<image tag>`
```

### Step2c. Execute CD Pipeline

Create a CD pipeline from the following yaml file. 

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── certificate-manager-cd.yaml
```

The CD Pipeline would require the following run time parameters. 

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |
|`image tag` | The same image tag number with build ID value created in the CI pipeline during pushing the image | 

On success the deployment stage ends with `DPN DEPLOYMENT COMPLETE`.

---

### Step2d. Verify CD Pipeline

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begin. 

```bash
kubectl get pods -n <namespace> # check for dpn-certificate-manager-XXXXXX
kubectl logs -f dpn-certificate-manager-XXXXXXXXX
```
The kubectl logs should not showcase any [error] message if the deployment is successful. 

---

**P12 files generated on the shared file share** — confirm both are present:

```bash
kubectl -n <namespace> exec <pod-name> -- ls -l /tls
# expect: keystore.p12  truststore.p12
```

**First-run note (Vault):** On the very first start, the log-verification step may show Vault access errors if Vault configuration has not fully completed. Ensure Vault is initialised and the bundle is loaded, then restart the Certificate Manager pod:

```bash
kubectl rollout status deployment/dpn-certificate-manager -n <namespace> --timeout=300s
kubectl get pods -n <namespace> -l app=dpn-certificate-manager -o wide
kubectl get pvc  -n <namespace>
```

---

## Step3: Troubleshooting

While working with the Federator Certificate Manager some common problem may arise. These are given below.

### Invalid Keystore/Trustore Password

This is a common known error occuring due to password mismatch. Confirm that `/tls/keystore.p12` and `/tls/truststore.p12` files in the dpn-certificate-manager kubernettes container are in sync with the loaded certificates in Hashicorp vault by checking their timestamps. If not delete the files from inside the container.

### PKIX Certificate validation error

Sometimes there could be some sync issue between certificate, ca-chain and key-pair files in the hashicorp vault which can lead to the `PKIX certificate validation` error. In that case please refresh/resync the certificates in vault by downloading a bootstrap bundle from DSM and uploading it again to vault. Also make sure to delete existing contents from vault before uploading the bootstrap certificates.

### 401 Unauthorised error from DSM Auth endpoint

Sometimes the certificate entries in the management-node could get out of sync with the certificates in vault leading to the 401 error from IDP endpoint. In that case please refresh/resync the certificates in vault by downloading a bootstrap bundle from DSM and uploading it again to vault. Also make sure to delete existing contents from vault before uploading the bootstrap certificates.

---

## Step4: Containerized Deployment Using DSI Provided Container Images

This section covers deployment using **custom and 3rd party open source container images** published by DSI to `ghcr.io/energy-dsi` image repository. Organisations using this approach pull DSI-provided images directly rather than building container images via CI pipelines.

Federator Certificate Manager custom image is found in GHCR with following name

| Image Name | GHCR Path | Tag |
|---|---|---|
| dpn-certificate-manager-service | `ghcr.io/energy-dsi/dpn-certificate-manager` | `e.g. 1.0.0` |


### Step4a. Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`.

Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably. Unauthenticated pulls are subject to strict rate limits and may fail in automated environments.

Create a GitHub Personal Access Token with `read:packages` scope. Once the token is available, create a kubernetes secret from the same.This secret will be used during the image pull.

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

### Step4b. Execute CD Pipeline

Create a CD pipeline from the following yaml file. The CD Pipeline is already pointing to GHCR repository. This CD pipeline fetches the latest image. In case Organisation need to use a specific version then it should be modified inside the CD pipeline.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── certificate-manager-ghcr-cd.yaml
```
The CD Pipeline would require the following run time parameters. 

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |
| `releaseTag` | Provides the release version or image tag to be pulled from GHCR |

Execute this CD Pipeline to perform deployment.

---

### Step4c. Verify CD Pipeline

Follow the same verification steps mentioned in step2c and step2d as above.

---


## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 31-Jul-2026 | DSI Assurance    | Final  | V1.0.0 |
