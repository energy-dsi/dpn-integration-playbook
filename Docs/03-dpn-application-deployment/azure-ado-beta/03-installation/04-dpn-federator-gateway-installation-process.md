# DPN Federator Gateway Installation Process

This document covers the installation of the **DPN Federator Gateway** (Server, Client, and supporting Kafka/Zookeeper/Redis/Kafka UI services) into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Federator Gateway flow — overview, prerequisites, Key Vault and Kubernetes secrets, the values to populate, deployment, and verification — is documented in one place:

**[Configure DPN Federator Gateway](../02-configuration/04-configure-dpn-federator-gateway.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault and the Certificate Manager.** Complete [Vault installation](01-dpn-vault-installation-process.md) and [Certificate Manager installation](03-dpn-certificate-manager-installtion-process.md) first — the gateway reads the P12 passwords from Vault and the P12 files from the Certificate Manager's shared file share.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CI/CD Pipelines](#step2-execute-cicd-pipelines)
  - [Step2a. Execute CI Pipeline](#step2a-execute-ci-pipeline)
  - [Step2b. Verify CI Pipeline Execution](#step2b-verify-ci-pipeline-execution)
  - [Step2c. Execute CD Pipeline](#step2c-execute-cd-pipeline)
  - [Step2d. Verify CD Pipeline](#step2d-verify-cd-pipeline)
  - [Step2e. Setup Kafka Topics](#step2e-setup-kafka-topics)
  - [Step2f: Verify Job Runner Interface](#step2f-verify-job-runner-interface)
- [Step3: Troubleshooting](#step3-troubleshooting)
  - [Invalid Keystore/Trustore Password](#invalid-keystoretrustore-password)
  - [PKIX Certificate validation error](#pkix-certificate-validation-error)
  - [401 Unauthorised error from DSM Auth endpoint](#401-unauthorised-error-from-dsm-auth-endpoint)
  - [52x error Due to SSL handshake failure](#52x-error-due-to-ssl-handshake-failure)
  - [403 OCSP certificate check failure](#403-ocsp-certificate-check-failure)
  - [Resilience retry due from remote endpoint call.](#resilience-retry-due-from-remote-endpoint-call)
  - [File or Streaming Data Not Arriving](#file-or-streaming-data-not-arriving)
  - [Kafka Pod Failure](#kafka-pod-failure)
- [Step4: Containerized Deployment Using DSI Provided Container Images](#step4-containerized-deployment-using-dsi-provided-container-images)
  - [Step4a. Configure GHCR Image Access](#step4a-configure-ghcr-image-access)
  - [Step4b. Execute CD Pipeline](#step4b-execute-cd-pipeline)
  - [Step4c. Verify CD Pipeline](#step4c-verify-cd-pipeline)
- [Review Notes](#review-notes)

---

## Overview

The Federator Gateway is deployed as a **single Helm release (`dpn-platform`)** via one Azure DevOps CD pipeline run. The release includes the Federator Server and Client plus Zookeeper (source/target), Kafka (source/target), Kafka UI, and Redis.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── azure-dpn-cd.yaml
```

Key points, detailed in the configuration guide:
- The P12 **passwords are read from Vault**; only the storage connection strings are Key Vault secrets.
- The **Server and Client use separate storage accounts** — the **Client uses the File Scan Service source storage account**.
- The deployment targets a **single DPN cluster** (`dpn01` or `dpn02`).

---

## Step1: Verify Prerequisites

Confirm the prerequisites are met before starting the federator gateway installation. See [Configure DPN Federator Gateway → Prerequisites](../02-configuration/04-configure-dpn-federator-gateway.md#step1-meet-prerequisites). 

In summary: 

- Vault and Certificate Manager deployed and in running state
- Health monitoring service is running state and OTEL Collector healthy
- Shared file share PVC and `cert-manager-truststore` `certificate-manager-secrets` secrets present
- Storage Account connection string secrets are prepared using SAS token
- Server and File Scan source storage accounts provisioned
- Internal load Balancer IPs are determined
- IDP client ID is received from DSM
- Populated `config/<env>.json` and `values-<env>-<cluster>.yaml` for the deployment environment

---

## Step2: Execute CI/CD Pipelines

The following steps describe the process of running CI/CD pipelines for DPN Federator Gateway Service Components. 

### Step2a. Execute CI Pipeline

The Federator Gateway CI pipeline yaml file is placed in this location to set up the CI pipeline.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── ci-pipelines/
            └── federator-ci.yaml
```

The CI pipeline requires the following paramters to be passed.

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |

### Step2b. Verify CI Pipeline Execution

Once the CI pipeline executes successfully a new image is pushed in the image registry mentioned in the configuration file. 

The image tag is mentioned in the pipeline clean up stage with a random numeric value. The image registry to be checked if the following images are pushed. 

```text
dpn-federator-client:`<image tag>`
dpn-federator-server:`<image tag>`
```

### Step2c. Execute CD Pipeline

Create a CD pipeline from the following yaml file. 

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── azure-dpn-cd.yaml
```
The CD Pipeline would require the following run time parameters. 

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | `A given Service Connection able to deploy the services` |
| `environment` | `environment abbreviation` |
| `cluster` | `dpn01` (DSI provides two dpn configurations per environment. Organisations may keep only one such as dpn01 to run a single DPN cluser)` |
|`image tag` | A numeric random value created in the CI pipeline during pushing the image | 

On success the deployment stage ends with `DPN DEPLOYMENT COMPLETE`.

---

### Step2d. Verify CD Pipeline

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begins. 

```bash
kubectl get pods -n <namespace>
kubectl logs -f dpn-federator-server-1-XXXXXXXXX
kubectl logs -f dpn-federator-client-1-XXXXXXXXX
kubectl get svc  -n <namespace>   # confirm Server + Client internal LB IPs
```
The kubectl logs should not showcase any [error] message if the deployment is successful. 

### Step2e. Setup Kafka Topics

Once the Federator Gateway service is deployed, the Kafka-UI is acecssible using a private FQDN. To access kafka-ui , Organisation should check the load balancer IP of the kafka-ui service received from the following. 

```bash
kubectl get svc  -n <namespace>  
```
The kafka-ui is reachable using the following FQDN

```text
http://`<kafka-ui load balancer ip>`:8086
```

The login would require nginx proxy authentication credentials to be provided. 
Once the Kafka-UI is open, follow the required topic creation mentioned in `Configure Data Store` step in [Kafka Topic installation](../02-configuration/05-configure-dpn-data-pipelines.md)

For more details on kafka-ui interface refer to [Kafka UI Operations](../../../05-dpn-user-interfaces/04-kafka-ui-operations.md)


### Step2f: Verify Job Runner Interface

Once the Federator Gateway service is deployed, the federator client job runner interface is acecssible using a private FQDN. To access job runnner interface , Organisation should check the load balancer IP of the federator client service received from the following. 

```bash
kubectl get svc  -n <namespace>  
```
The job runner interface is reachable using the following FQDN

```text
http://`<dpn-federator-client-1 load balancer ip>`:8085
```

For more details on the job runner UI, refer to For more details on kafka-ui interface refer to [Job Runner Interface Operations](../../../05-dpn-user-interfaces/03-federator-client-job-runner-ui-operations.md)

---

## Step3: Troubleshooting

While working with Federator Gateway Service some known problem could arise. These are given below.

### Invalid Keystore/Trustore Password

This is a common known error occuring due to password mismatch. Please follow the Troubleshooting step for Certificate manager for the same issue.

### PKIX Certificate validation error

Sometimes there could be some sync issue between certificate, ca-chain and key-pair files in the hashicorp vault which can lead to the `PKIX certificate validation` error. Please follow the Troubleshooting step for Certificate manager for the same issue.

### 401 Unauthorised error from DSM Auth endpoint

Sometimes the certificate entries in the management-node could get out of sync with the certificates in vault leading to the 401 error from DSM IDP endpoint. Please follow the Troubleshooting step for Certificate manager for the same issue.

### 52x error Due to SSL handshake failure

Sometimes the certificates in keystore.p12 file could hit expiry or out of sync. This can trigger 52x errors from the DPN of other Organisation when the consumer job tries to connect a producer.

### 403 OCSP certificate check failure

When the Federator client connects to a server whose certificate has expired or revoked, it will hit this error from OCSP endpoint in management node, which will cause the transfer job to fail. In this case unsubscribe to the product from UI or ask the producer of the product to get a valid certificate.

### Resilience retry due from remote endpoint call.

This error most likely is caused due to invalid bearer token used or authentication issue at the IDP. In this most of the time the error should go after restarting both certificate manager and federator consecutively.

### File or Streaming Data Not Arriving

This error happens if kafka topic offset is out of sync for certain reasons. In this case it is advised to flush redis cache using the following command. 

```text
kubectl exec -n ns-dpn-01 <redis-pod-name> -- redis-cli FLUSHALL
```

### Kafka Pod Failure

In case Kafka is failing , please restart using rollout restart command in sequence 1. Kafka src 2. Kafka-target and then kafka-UI.

```text
kubectl rollout restart deployment/<deployment-name> -n <namespace>
```

---

## Step4: Containerized Deployment Using DSI Provided Container Images

This section covers deployment using **custom and 3rd party open source container images** published by DSI to `ghcr.io/energy-dsi` image repository. Organisations using this approach pull DSI-provided images directly rather than building container images via CI pipelines.

DPN Federator Gateway service cutsom images are found in GHCR with following names

| Image Name | GHCR Path | Tag |
|---|---|---|
| Federator Server | `ghcr.io/energy-dsi/dpn-federator-gateway/federator-server` | `e.g. 1.0.0` |
| Federator Client | `ghcr.io/energy-dsi/dpn-federator-gateway/federator-client` | `<version>` |

The Federator Gateway service 3rd party platform images are found in GHCR with following names

| Purpose | GHCR Path |
|---|---|
| Kafka | `ghcr.io/energy-dsi/dpn-kafka:<latest or DSI provided stable version>` |
| Zookeeper | `ghcr.io/energy-dsi/dpn-zookeeper:<latest or DSI provided stable version>` |
| Redis | `ghcr.io/energy-dsi/redis:<latest or DSI provided stable version>` |
| Kafka UI | `ghcr.io/energy-dsi/ui-kafka:<latest or DSI provided stable version>` |


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
            └── dpn-federator-gateway-pipeline-ghcr-cd.yaml
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
| 31-July-2026 | DSI Assurance    | Final  | V1.0.0 |
