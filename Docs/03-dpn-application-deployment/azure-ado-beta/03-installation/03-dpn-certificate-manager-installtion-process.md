# DPN Certificate Manager Installation Process

This document covers the installation of the **DPN Federator Certificate Manager (CLM)** into a single target environment on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Certificate Manager flow — overview, prerequisites, the values/secrets to populate, deployment, and post-deployment verification — is documented in one place:

**[Configure DPN Certificate Manager](../02-configuration/03-configure-dpn-certificate-manager.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault.** The Certificate Manager cannot run until the DPN HashiCorp Vault service is deployed, initialised, and loaded with the certificate bundle. Complete [Vault installation](01-dpn-vault-installation-process.md) first.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Sequence](#installation-sequence)
- [Verification](#verification)
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

Confirm the prerequisites before starting — see [Configure DPN Certificate Manager → Prerequisites](../02-configuration/03-configure-dpn-certificate-manager.md#prerequisites). 

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
`<<Anuran>>`

## Step4: Containerized Deployment Using DSI Provided Container Images
`<<Tamanna to update>>`


## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| 31-Jul-2026 | DSI Assurance    | Final  | V1.0.0 |
