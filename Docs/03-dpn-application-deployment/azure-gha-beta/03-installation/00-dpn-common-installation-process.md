Release : 2.1.0 - Oct 2026

# DPN Installation Process

---

## Table of Contents

- [Overview](#overview)
- [DPN Deployment Architecture](#dpn-deployment-architecture)
- [Installation Prerequisites](#installation-prerequisites)
  - [1. Clone and Prepare Source Repositories](#1-clone-and-prepare-source-repositories)
  - [2. Prepare Infrastructure and Application Prerequisites](#2-prepare-infrastructure-and-application-prerequisites)
  - [3. Certificate Preparation and CSR Generation](#3-certificate-preparation-and-csr-generation)
  - [4. Identify Pipeline Repository Structure](#4-identify-pipeline-repository-structure)
- [Component Installation Guides](#component-installation-guides)
- [Common Troubleshooting Guidance](#common-troubleshooting-guidance)
  - [CI Pipeline Failure](#ci-pipeline-failure)
  - [Container Image Not Found](#container-image-not-found)
  - [Pods Not Starting](#pods-not-starting)
  - [Container CrashLoopBackOff](#container-crashloopbackoff)
  - [Kafka Topic Issues](#kafka-topic-issues)
  - [Certificate Renewal Job Failing](#certificate-renewal-job-failing)
  - [Emergency Certificate Rotation Process](#emergency-certificate-rotation-process)
  - [Certificate Sync Job Failing](#certificate-sync-job-failing)
  - [Federator Connection Failing](#federator-connection-failing)
- [Review Notes](#review-notes)

---

## Overview

This document is the starting point for installing and deploying **DPN components into an Azure environment** using the **GitHub Actions pipelines in each component's own ADO repository**, run with `cloud: azure`. It covers what's common to every component; component-specific steps (which workflow to run, which inputs to set, how to verify that specific deployment) live in each component's own installation guide — see [Component Installation Guides](#component-installation-guides).

The deployment uses the following repositories:

- https://github.com/energy-dsi/dpn-federator.git
- https://github.com/energy-dsi/dpn-federator-certificate-manager.git
- https://github.com/energy-dsi/dpn-data-pipelines.git
- https://github.com/energy-dsi/dpn-file-scan-service.git
- https://github.com/energy-dsi/dpn-health-monitoring-service.git

The deployment process consists of:

- **Continuous Integration (CI)** — builds container images
- **Continuous Deployment (CD)** — deploys images into **Azure Kubernetes Service (AKS)**

---

## DPN Deployment Architecture

The following diagram illustrates the reference DPN deployment architecture for the **DPN Data Exchange platform**. It consists of the following containerised components:

![DPN Architecture Blocks](../../../04-dpn-architecture/images/dpn_deployment_architecture.png)

**DPN Federator Gateway**
This component is responsible for file transmission over a gRPC connection, communication with the DSM Keycloak service, and management node services.

**DPN Federator Gateway — Server Mode**
- Receives Federator Client requests
- Authenticates with the DSM service
- Receives producer and consumer configuration from the management node
- Connects to the Kafka topic based on the client request for a data product
- Initiates a gRPC-based file streaming service with the Federator Client

**DPN Federator Gateway — Client Mode**
- Initiates a Federator Server request based on a scheduled job
- Authenticates with the DSM service
- Receives producer and consumer configuration from the management node
- Initiates a gRPC-based file streaming service with the Federator Server
- Places the file in the storage container

**DPN Certificate Manager**
This component is responsible to maintain and recycle DPN certificates from DSM at regular interval. It renews certificates with the management node and persists them in Vault. The Federator Server and Client read that same Vault material directly and build their mTLS keystore/truststore in memory — there is no shared file share.

**DPN Authentication Service**
Deploys Keycloak, the platform's shared OAuth2/OIDC Identity Provider. Kafka brokers authenticate against it by default (`SASL_SSL`/`OAUTHBEARER`), and it also backs Keycloak SSO on the DPN observability UIs via the DPN Portal.

**DPN Data Pipeline Producer**
- Files are extracted from the organisation's source storage location automatically on a scheduled basis
- Processed by the adaptor component
- Published to Kafka topics with the final file location
- Published to the target storage location

**DPN Data Pipeline Consumer**
- Federator Client receives the file in a consumer-specific storage account or bucket
- Checksum and hash validation are performed on the received file(s)
- The file is processed by the extractor service, which performs schema validation based on the schema type specified in the file name, and placed into another target container
- The processed file is stored in the consumer target storage container or bucket
- A Kafka-based streaming message is sent to a destination Kafka topic to mark the end of the data pipeline process

**DPN File Scanning Service**
- Sits between the Federator Client's landing zone and the Data Pipeline Consumer
- Cloud-native malware scanning of inbound files before they reach the existing consumer container
- Only verified-clean files are made available to the DPN Data Pipeline Consumer

**DPN Health Monitoring Service**
- Hosts the shared OTEL Collector every other DPN component sends traces, metrics, and logs
- Routes each signal type through Kafka to a dedicated storage/dashboard stack: Prometheus + Thanos + Perses (metrics), OpenSearch + Data Prepper (logs), Jaeger (traces). 
- Fronts all dashboards with a single authenticated reverse proxy
**Note** - Opensearch is recommended to be used for log monitoring at this moment, prometheus and Jaeger dashboard UI improvements under process for future release.

**DPN Streaming Service — Kafka**
This component is responsible for event emission and storing the locations of data product files produced by the Data Pipeline Producer. It also signals events occurring between the adaptor and extractor processes. The Kafka service additionally provides a UI to monitor topics and messages. This component is packaged with the Federator component.

**DPN Caching Service**
This component uses Redis caching to store Kafka offsets for various topics and to cache tokens as necessary for the Federator Server and Clients. It is also bundled with the Federator Gateway package.

**DPN Vault Service**
This component uses HashiCorp Vault for storing secrets used by the individual DPN components. It is also packaged with the Federator Gateway package.

---

## Installation Prerequisites

The following prerequisites must be completed before beginning the installation process.

### 1. Clone and Prepare Source Repositories

Clone the official repositories from GitHub main branch

```bash
git clone https://github.com/energy-dsi/dpn-authentication-service
git clone https://github.com/energy-dsi/dpn-rest-federator-gateway
git clone https://github.com/energy-dsi/dpn-federator.git
git clone https://github.com/energy-dsi/dpn-federator-certificate-manager.git
git clone https://github.com/energy-dsi/dpn-data-pipelines.git
git clone https://github.com/energy-dsi/dpn-file-scan-service.git
git clone https://github.com/energy-dsi/dpn-health-monitoring-service.git

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

### 2. Prepare Infrastructure and Application Prerequisites

Ensure the following prerequisites are completed before deployment:

- Infrastructure prerequisites
- Software prerequisites
- Network prerequisites
- Security prerequisites
- Certificate prerequisites

[Refer to the **Prerequisites** and **Configuration** documentation for details](../01-prerequisites/01-dpn-prerequisites.md)

---

### 3. Certificate Preparation and CSR Generation

Refer to [DPN Vault Service Configuration](../02-configuration/01-configure-dpn-vault-service.md) for certificate set up and csr generation

---

### 4. Identify Pipeline Repository Structure

All CD workflows and their configuration live in the following location

```
root/
├── .pipelines/
  ├── github-actions-pipelines/
│   ├── workflows/          # one workflow per DPN component (e.g. dpn-gha-vault-https-cd.yml)
│   ├── actions/
│   │   └── cloud-login/    # shared composite action: azure / aws / gcp OIDC login
│   └── config/
│       ├── azure/<environment>-<cluster>.json
│       ├── aws/<environment>-<cluster>.json
│       └── gcp/<environment>-<cluster>.json      # not yet supported
└── /charts/<components>/values/azure/<environment>-<cluster>.yaml
```

---

## Component Installation Guides

The DPN currently comprises the following components. Complete the prerequisites above once, then follow the linked guide for each component you're installing:

| Component | Installation Guide | Notes |
|-----------|---------------------|-------|
| DPN Vault and Shared File Service | *01-dpn-vault-installation-process.md* | Must be installed and configured (initialised, unsealed, certificate bundle loaded) before the Certificate Manager |
| DPN Authentication Service | *02-dpn-authentication-service-installation-process.md* | Must be installed and configured before the Health Moniotoring service|
| DPN Health Monitoring Service | *03-dpn-health-monitoring-service-installation-process.md* | ** see that guide for the environment-specific setup |
| DPN Federator Certificate Manager | *04-dpn-certificate-manager-installation-process.md* | Depends on Vault |
| DPN Federator Gateway | *05-dpn-federator-gateway-installation-process.md* | Depends on Vault and Certificate Manager being installed and configured first |
| DPN REST Federator Gateway | *06-dpn-rest-federator-gateway-installation-process.md* | Optional. Depends on Vault and Certificate Manager, same as the gRPC Federator Gateway; independent of it otherwise |
| DPN Data Pipeline | *07-dpn-data-pipeline-installation-process.md* | Independent of Vault/Certificate Manager/Federator Gateway |
| DPN File Scanning Service | *08-dpn-file-scan-service-installation-process.md* | Native deployment for Azure Cloud only |

---

## Common Troubleshooting Guidance

### CD Pipeline Failure

Possible causes:

- Incorrect GitHub PAT token or missing `read:packages` scope
- Maven repository authentication failure — verify the `GITHUB_MAVEN_USERNAME`/`GITHUB_MAVEN_TOKEN` GitHub Actions secrets on the component's own source repository
- Docker login failure — verify the `DOCKERHUB_USERNAME`/`DOCKERHUB_PASSWORD` GitHub Actions secrets
- Registry login failure — verify the CI workflow's credentials have push access to whichever registry (GHCR, or your own ECR/ACR) the image is pushed to

Verify the GitHub Actions run logs and ensure all secrets are correct.

---

### Container Image Not Found

Check whether the CI pipeline pushed images to the registry and check whether the same image tag is used as the CD workflow's `imageTag` input.

Compare the digest generated between CI and the CD workflow's "Capture Deployed Image Digest" artifact.

```bash
# GHCR (default registry):
gh api /orgs/energy-dsi/packages?package_type=container

# Or, if pushing to your own ACR:
az acr repository show --name <ACR_NAME> --repository <repository>
```

If the expected repository is not listed, re-run the relevant CI pipeline and ensure it completes without errors before triggering the CD workflow.

---

### Pods Not Starting

Check pod events to identify scheduling or image pull issues:

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Review the `Events` section at the bottom of the output. Common causes include insufficient node resources, missing Persistent Volume Claims, or image pull errors due to an incorrect/expired `ghcr-pull-secret`.

---

### Container CrashLoopBackOff

A `CrashLoopBackOff` status means the container starts, crashes, and Kubernetes repeatedly attempts to restart it. Check the logs to identify the root cause:

```bash
kubectl logs <pod-name> -n <namespace>
```

Common causes:

- Invalid or missing environment variables — check the Helm values file for typographical errors or missing entries
- Missing secrets or incorrect credentials — verify all required secrets exist in Azure Key Vault (mounted via the Secrets Store CSI driver) with the correct names and values
- Kafka topic is not pre-populated — run the Kafka Topic Creator job or manually create topics via the Kafka UI

---

### Kafka Topic Issues

Verify Kafka topics using the Kafka UI:

```
http://kafka-ui:8086
```

Check that:

- The topic exists in both the source and destination Kafka clusters
- The topic name in the Federator configuration matches exactly (topic names are case-sensitive)
- There are no consumer group errors shown in the Kafka UI for the Federator consumer group

---

### Certificate Renewal Job Failing

When the CD pipeline is run and pods are started for the first time, the log verification step described in [Certificate Manager, Step2c: Verify CD Workflow](04-dpn-certificate-manager-installation-process.md#step2c-verify-cd-workflow) may show Vault access errors. This occurs because the Vault configuration has not yet been completed at this stage.

Ensure that both the Vault and certificate manager pods are restarted after configuring the Vault as described in [HashiCorp Vault Configuration](../02-configuration/01-configure-dpn-vault-service.md#automated-vault-configuration).

To restart a pod:

```bash
kubectl -n <namespace> delete po/<pod_id>
```

> **Note:** If the renewal job fails after the pods have been stopped for a period exceeding the renewal frequency (`cert.renewalRateMs`), the organisation's DPN administrator must raise a request with a new CSR to the DSM to obtain a new certificate bundle. Load the new bundle into the DPN Vault using the steps described in [Certificate Load Steps in Vault](../02-configuration/01-configure-dpn-vault-service.md#step-3c-configure-certificate-bundle-vault-load-bundle-cd).

---

### Emergency Certificate Rotation Process

In case we need to rotate/renew the certificate adhoc forcefully using new certificate bundle received from DSI DSM, we need to perform the cleanup and rollback process listed [here](../04-rollback/04-rollback-procedures.md#disaster-recovery-considerations) using the new certificate bundle. 

---

### Certificate Sync Job Failing

If the sync job fails with the following error:

```text
INFO  u.g.d.n.f.c.m.s.KeyStoreSyncServiceImpl [] - Synchronizing keystores to filesystem...
ERROR u.g.d.n.f.c.m.job.CertificateSyncJob [] - Error during certificate synchronization job execution: Failed to create keystore
uk.gov.dbt.ndtp.federator.certificate.manager.exception.KeyStoreCreationException: Failed to create keystore
        at uk.gov.dbt.ndtp.federator.certificate.manager.service.pki.KeyStoreService.createKeyStore(KeyStoreService.java:62)
Caused by: java.security.KeyStoreException: Certificate chain is not valid
```

Verify that the CA chain, intermediate CA, certificate, and key pair files stored in the Vault are in sync — that is, all are linked to the same CSR and root CA. If they are not, raise a new certificate bundle request using a new CSR.

---

### Federator Connection Failing

If the following log entries are observed and the connection does not proceed:

```
u.g.d.n.f.c.s.i.IdpTokenServiceMtlsImpl - No cached token in Redis for default management node, fetching from IDP
15:15:34.346 [main] DEBUG u.g.d.n.f.c.s.i.IdpTokenServiceMtlsImpl - attempting to fetch token for management node
```

Verify that the mutual TLS certificates are correctly loaded in Vault and that the Vault and certificate manager pods are in a healthy running state — the keystore/truststore are built in memory from that Vault material, so there is no on-disk path to inspect.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 |
