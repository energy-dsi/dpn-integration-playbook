# DPN Federator Gateway Installation Process

This document covers the installation of the **DPN Federator Gateway** (Server, Client, and supporting Kafka/Zookeeper/Redis/Kafka UI services) into a single target environment and a single DPN cluster on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Federator Gateway flow — overview, prerequisites, Key Vault and Kubernetes secrets, the values to populate, deployment, and verification — is documented in one place:

**[Configure DPN Federator Gateway](../02-configuration/05-configure-dpn-federator-gateway.md)**

This installation page is a quick-reference summary that points to that guide.

**Depends on Vault and the Certificate Manager.** Complete [Vault installation](01-dpn-vault-installation-process.md) and [Certificate Manager installation](04-dpn-certificate-manager-installation-process.md) first — the gateway reads its certificate material and the keystore/truststore passwords directly from Vault (no shared file share is used).

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CD](#step2-execute-cd)
  - [Step2a. Configure GHCR Image Access](#step2a-configure-ghcr-image-access)
  - [Step2b. Execute CD Workflow](#step2b-execute-cd-workflow)
  - [Step2c. Verify CD Workflow](#step2c-verify-cd-workflow)
  - [Step2d. Setup Kafka Topics](#step2d-setup-kafka-topics)
  - [Step2e: Verify Job Runner Interface](#step2e-verify-job-runner-interface)
- [Step3: Troubleshooting](#step3-troubleshooting)
  - [Invalid Keystore/Trustore Password](#invalid-keystoretrustore-password)
  - [PKIX Certificate validation error](#pkix-certificate-validation-error)
  - [401 Unauthorised error from DSM Auth endpoint](#401-unauthorised-error-from-dsm-auth-endpoint)
  - [52x error Due to SSL handshake failure](#52x-error-due-to-ssl-handshake-failure)
  - [403 OCSP certificate check failure](#403-ocsp-certificate-check-failure)
  - [Resilience retry due from remote endpoint call.](#resilience-retry-due-from-remote-endpoint-call)
  - [File or Streaming Data Not Arriving](#file-or-streaming-data-not-arriving)
  - [Kafka Pod Failure](#kafka-pod-failure)
- [Reference: Container Images Used](#reference-container-images-used)
- [Review Notes](#review-notes)

---

## Overview

The Federator Gateway is deployed as a **single Helm release (`dpn-platform`)** via one GitHub Actions CD workflow run. The release includes the Federator Server and Client plus Zookeeper (source/target), Kafka (source/target), Kafka UI, and Redis.

```text
root/
└── .pipelines/
  └── github-actions-pipelines/
      └── workflows/
          └── dpn-gha-federator-gateway-cd.yml
```

Key points, detailed in the configuration guide:
- The gateway builds its mTLS keystore/truststore **in memory from Vault** — no shared file share is used; only the Blob Storage access credentials (and the Vault root token, via `certificate-manager-secrets`) are Key Vault secrets. The truststore password itself is also fetched from Key Vault (`VAULT-TRUSTSTORE-PASSWORD`) and passed into the Helm release at deploy time.
- The **Server and Client use separate Blob Storage containers** — the **Client uses the File Scan Service source container**.
- The deployment targets a **single DPN cluster** (`dpn01` or `dpn02`).
- Kafka brokers run `SASL_SSL`/`OAUTHBEARER` against Keycloak by default (`kafka.authMode: sasl_ssl`).

---

## Step1: Verify Prerequisites

Confirm the prerequisites are met before starting the federator gateway installation. See [Configure DPN Federator Gateway → Prerequisites](../02-configuration/05-configure-dpn-federator-gateway.md#step1-meet-prerequisites). 

In summary: 

- Vault and Certificate Manager deployed and in running state
- Health monitoring service is running state and OTEL Collector healthy
- `cert-manager-truststore`, `certificate-manager-secrets`, and `tls-auth-secret` secrets present; Vault authentication configured (root token today — see [Configure DPN Vault Service, Step 3E](../02-configuration/01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication) for the AppRole caveat)
- Blob Storage access credential secrets are prepared
- Server and File Scan source Blob Storage containers provisioned
- Internal load Balancer IPs are determined
- IDP client ID is received from DSM
- Populated config JSON and values file for the `<environment>-<cluster>` combination
- Workload Identity federated credential for the platform's `ServiceAccount` created, and its Key Vault name set as `KEY_VAULT_NAME` — see [Configure DPN Federator Gateway, Step3e](../02-configuration/05-configure-dpn-federator-gateway.md#step3e-configure-aws-serviceaccount-irsa)
- `dpn-keycloak-secrets` Kubernetes secret present in the namespace (created by the **DPN Authentication Service** deployment) — Kafka Source/Target, Kafka UI, and the Federator Server/Client read the Keycloak admin password and OAuth client secret from it directly; `secretsManager.secretPrefix` is not currently read by any template in this chart

**Note:** Organisations must review workflow code for the following. 

- If running your own CI, keep only the relevant build, unit test, and image-push steps — DSI's own CI examples include tool usage such as CheckMarx, SonarQube, and JFrog Xray that your organisation may not need
- The container image is appropriate and referred from GHCR repository unless Organisation plans to use a separate image repository on their own
- The config JSON's environment parameters are pointing to correct deployment environment
- The DSM endpoints are correctly pointing to the respective environment
- Required Firewall rules are applied
- CD pipeline is verified for the above prerequisites before execution

---

## Step2: Execute CD

### Step2a. Configure GHCR Image Access

All custom and third-party images are pulled from `ghcr.io/energy-dsi`. Even though the `energy-dsi` GHCR packages are **public**, GitHub Container Registry still requires authentication (a GitHub username and Personal Access Token) to pull images reliably.

Create a GitHub Personal Access Token with `read:packages` scope, then create a Kubernetes secret from it:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
     --docker-server=ghcr.io \
     --docker-username=<github-username-or-bot-account> \
     --docker-password=<GitHub PAT with read:packages scope> \
     -n <namespace>
```

### Step2b. Execute CD Workflow

Go to **Actions → DPN CD - Federator Gateway → Run workflow** in `dpn-containerised-deployment-service`, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `azure` |
| `imageTag` | The image tag pushed in Step2a |

On success, the deployed image digests are captured as a workflow artifact.

> **Key Vault fetch before deploy (Azure only).** The workflow fetches `VAULT-TRUSTSTORE-PASSWORD` from the environment's Key Vault (`KEY_VAULT_NAME`) and passes it in as `vaultConfig.truststorePassword` on the `helm upgrade`. In practice this value is cosmetic: the container's actual `-Dvault.truststore.password` JVM flag is sourced directly from the `certificate-manager-secrets` Kubernetes Secret, so the Key Vault copy only ever reaches the rendered properties ConfigMap and is never read by the running app — but the fetch step still has to succeed for the deploy to proceed.

---

### Step2c. Verify CD Workflow

After deployment, confirm the following components are running and validate end-to-end connectivity using the container logs. Alternatively, check the logs from DPN health monitoring dashboard. The dashboard starts filling after some time once the heartbit signal flow begins. 

```bash
kubectl get pods -n <namespace>
kubectl logs -f dpn-federator-server-1-XXXXXXXXX
kubectl logs -f dpn-federator-client-1-XXXXXXXXX
kubectl get svc  -n <namespace>   # confirm Server + Client internal LB IPs
```
The kubectl logs should not showcase any [error] message if the deployment is successful. 

### Step2d. Setup Kafka Topics

Once the Federator Gateway service is deployed, the Kafka-UI is acecssible using a private FQDN. To access kafka-ui , Organisation should check the load balancer IP of the kafka-ui service received from the following. 

```bash
kubectl get svc  -n <namespace>  
```
The kafka-ui is reachable using the following FQDN

```text
http://`<kafka-ui load balancer ip>`:8086
```

The login would require nginx proxy authentication credentials to be provided. 
Once the Kafka-UI is open, follow the required topic creation mentioned in `Configure Data Store` step in [Kafka Topic installation](../02-configuration/07-configure-dpn-data-pipelines.md)

For more details on kafka-ui interface refer to [Kafka UI Operations](../../../05-dpn-user-interfaces/04-kafka-ui-operations.md)


### Step2e: Verify Job Runner Interface

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

If Kafka Source/Target or Zookeeper Source/Target crash-loop immediately on start with a Python `urllib3` import error, check that the pod's `instrumentation.opentelemetry.io/inject-python` annotation is `"false"` — the cluster's OTel Python auto-instrumentation webhook injects a `urllib3` build incompatible with these images' Python 3.9 startup tooling otherwise. This is set automatically on AWS (`cloudProvider: aws`); on Azure, confirm the chart's equivalent `cloudProvider: azure` annotation override is actually applied — if it is missing, re-deploy so the annotation is applied — a live `kubectl patch` alone is reverted by the next `helm upgrade`.

---

## Reference: Container Images Used

DPN Federator Gateway service custom images are found in GHCR with following names

| Image Name | GHCR Path | Tag |
|---|---|---|
| Federator Server | `ghcr.io/energy-dsi/dpn-federator-gateway/federator-server` | `e.g. 2.0.0` |
| Federator Client | `ghcr.io/energy-dsi/dpn-federator-gateway/federator-client` | `<version>` |

The Federator Gateway service 3rd party platform images are found in GHCR with following names

| Purpose | GHCR Path |
|---|---|
| Kafka | `ghcr.io/energy-dsi/dpn-kafka:<latest or DSI provided stable version>` |
| Zookeeper | `ghcr.io/energy-dsi/dpn-zookeeper:<latest or DSI provided stable version>` |
| Redis | `ghcr.io/energy-dsi/redis:<latest or DSI provided stable version>` |
| Kafka UI | `ghcr.io/energy-dsi/ui-kafka:<latest or DSI provided stable version>` |

There is no separate GHCR-specific workflow to run — [Step2b](#step2b-execute-cd-workflow) above already deploys from these images by default.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|------------------|--------|---------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
