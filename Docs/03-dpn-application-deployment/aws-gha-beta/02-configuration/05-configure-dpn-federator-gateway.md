Release : 2.1.0 - Oct 2026

# DPN Federator Gateway Configuration

This section describes how to configure and deploy the **DPN Federator Gateway** (Server and Client, plus their supporting services) into a single target environment and a single DPN cluster on Amazon Elastic Kubernetes Service (EKS). The Federator Gateway handles all secure communication between DPN node and other DPN nodes or the DSI DSM — sending and receiving data only to and from trusted parties over mutual TLS (mTLS).

> **Depends on Vault and the Certificate Manager.** The Federator Gateway cannot start correctly until:
> - the **DPN Vault** is deployed, initialised, and loaded (it supplies the certificate, key pair, CA chain, and keystore/truststore **passwords** under `node-net/client/*`), and
> - the **Certificate Manager** has renewed the certificate into that same Vault path.
>
> The gateway reads this material directly from Vault and builds its mTLS keystore/truststore **in memory** at start-up (`vaultConfig.tlsEnabled: true`) — there is no shared file share to provision (`vaultConfig.mountCertFileShare: false`).
>
> Complete [Configure DPN Vault Service](01-configure-dpn-vault-service.md) and [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md) first.

> **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`, e.g. `dpn01`). Substitute your own values for `<env>` and `<cluster>` throughout. The Federator Client is deployed for a **single cluster only** — deploy one cluster at a time.

> **This scope spans two GitHub Actions workflows, not one.** `dpn-gha-federator-gateway-cd.yaml` (in the `dpn-federator-gateway` repository) deploys Kafka src/target, Zookeeper src/target, Kafka UI, Redis, and the generic Federator Server/Client (this document's scope, below). The per-product producer/consumer adaptor/extractor pods are a **separate** workflow, `dpn-gha-data-pipelines-cd.yaml` in the `dpn-data-pipelines` repository, documented in [Configure DPN Data Pipelines](07-configure-dpn-data-pipelines.md) — not here.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet Prerequisites](#step1-meet-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
  - [Option A - Use Kubernetes Secrets](#option-a---use-kubernetes-secrets)
- [Step3: Configure Environment](#step3-configure-environment)
  - [Step3a: Configure Federator Server](#step3a-configure-federator-server)
  - [Step3b: Configure Federator Client](#step3b-configure-federator-client)
  - [Step3c: Configure Kafka Security](#step3c-configure-kafka-security)
  - [Step3e: Configure AWS ServiceAccount (IRSA)](#step3e-configure-aws-serviceaccount-irsa)
- [Step4: Configure Deployment Parameters](#step4-configure-deployment-parameters)
- [Review Notes](#review-notes)

---

## Overview

The Federator Gateway is deployed as a **single Helm release (`dpn-platform`)** that includes Federator gRPC Server, Federator gRPC Client, and other supporting services — all into the same namespace and cluster. Refer to the following:

| Component | Purpose |
|-----------|---------|
| Zookeeper Source / Target | Coordination for the Source / Target Kafka clusters (must start before Kafka) |
| Kafka Source | Stages the DPN's outgoing data; the Federator **Server** reads from here to send data out |
| Kafka Target | Receives incoming data from other DPNs; the Federator **Client** writes received data here |
| Kafka UI | Web dashboard to monitor topics/messages in both Kafka clusters (testing) |
| Redis | In-memory cache for offsets and tokens, used by both Server and Client |
| **Federator Server** | Receives inbound connections from other DPNs' clients; reads from Kafka Source and streams data out over gRPC/mTLS |
| **Federator Client** | Connects outward to a remote Federator Server; writes received data into Kafka Target and its storage |

> **Kafka broker security.** Both Kafka Source and Kafka Target run with `SASL_SSL` on every listener by default (`kafka.authMode: sasl_ssl` — the production default; `ssl`/`plaintext` remain available for dev/test). The SASL mechanism is `OAUTHBEARER`: brokers and clients obtain and validate tokens from the DPN **Keycloak** realm (`kafkaSrc.oauth.tokenEndpointUrl` / `kafkaTarget.oauth.tokenEndpointUrl`), so both inter-broker and client Kafka traffic is authenticated against Keycloak, not static credentials. This client secret (`KC_SERVICE_CLIENT_SECRET`) is read directly from the `dpn-keycloak-secrets` Kubernetes secret created by the **DPN Authentication Service** deployment — Kafka Source/Target, Kafka UI, and the Federator Server/Client no longer pull an independent `KAFKA-OAUTH-CLIENT-SECRET` entry of their own, so there is one fewer secret to provision per environment.

> **`cloudProvider: aws`.** The `dpn-platform` chart's templates branch on this value to select AWS-native behaviour (Network Load Balancers, the AWS Secrets Store CSI provider for Kafka's own credentials, S3 storage config, and the IRSA `ServiceAccount` below) instead of the Azure equivalents. Every populated `values/aws/<environment>-<cluster>.yaml` file must set `cloudProvider: aws` — it is **not** the chart's own default (`values.yaml` defaults it to `azure`).

**certificates and passwords flow (MUST READ):**

- The gateway builds its mTLS keystore/truststore **in memory** directly from certificate material in Vault (`vaultConfig.tlsEnabled: true`, `vaultConfig.tlsBasePath: node-net/client`) — no shared file share is used (`vaultConfig.mountCertFileShare: false`).
- The keystore/truststore **passwords are read from Vault** at start-up (`vaultConfig.keystorePasswordPath` / `truststorePasswordPath`) — they are **not** stored as Federator Key Vault secrets.
- The gateway can authenticate to Vault either via the Vault root token (`vaultConfig.authMethod: token`) or, on this AWS path, by **sharing the Certificate Manager's own AppRole identity** (`vaultConfig.authMethod: approle`, `vaultConfig.appRole.roleId` set to the Certificate Manager's `role_id`) — this is the pattern the checked-in AWS values files use today (`authMethod: approle`, `appRole.useSecretIdRef: true`, with the `secret-id` read from `certificate-manager-secrets` / `VAULT_APPROLE_SECRET_ID`). The `dpn-federator-gateway` repository now also ships its own AppRole-provisioning workflow, `dpn-gha-certificate-manager-role-id-creation.yaml` (**DPN CD - Certificate Manager Role ID Creation (Vault AppRole Setup)**, `component: federator-gateway`), which creates a dedicated `federator` AppRole and stores its `secret-id` and `role_id` in Secrets Manager at `dpn/<environment>-<cluster>/federator/VAULT_APPROLE_SECRET_ID` and `dpn/<environment>-<cluster>/federator/VAULT_APPROLE_ROLE_ID`. `dpn-gha-federator-gateway-cd.yaml` does not yet read these values, so the shared Certificate Manager identity remains the working pattern. See [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-dpn-gha-certificate-manager-role-id-creationyaml).
- The only Federator secrets in Key Vault are the **S3 access credentials** (one for the Server, a separate one for the Client) and, if using AppRole, the Vault `secret-id`.

> **Storage separation for Server and Client (MUST READ)**

Federator Server and Client use **separate S3 buckets**. The Federator Client uses the **File Scan Service *source* bucket** (where scanned inbound files are deposited). Configure the Client's storage endpoint/credentials to point at the File Scan Service source bucket — not the Server's bucket.

The Server's bucket is used to keep the data product files created by the organisation per data product pipeline.

---

## Step1: Meet Prerequisites

Ensure the following are in place **before** deploying the Federator Gateway:

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **DPN Vault deployed, initialised, and loaded** | Supplies the certificate material and keystore/truststore passwords under `pki-client/node-net/client/*`. See [Configure DPN Vault Service](01-configure-dpn-vault-service.md) |
| 2 | **Certificate Manager deployed** | Renews the certificate into Vault, and creates the `certificate-manager-secrets` Kubernetes secret used for the Vault AppRole `secret-id` (or root token) |
| 3 | **`cert-manager-truststore` Kubernetes secret present** | Created by the `dpn-gha-vault-tls-bootstrap-cd.yaml` workflow (in the `dpn-federator-certificate-manager` repository); mounted at `/vault/truststore` so the gateway trusts Vault's HTTPS endpoint |
| 4 | **Vault authentication configured** | Set `vaultConfig.authMethod: token`, or `approle` reusing the Certificate Manager's already-provisioned `role_id`/`secret_id` (the pattern the checked-in AWS values files use). See [Configure DPN Vault Service, Step 3E](01-configure-dpn-vault-service.md#step-3e-configure-approle-authentication-dpn-gha-certificate-manager-role-id-creationyaml) |
| 5 | **EKS cluster** | Needed if using Key Vault-sourced secrets; see [Step2](#step2-configure-secrets) |
| 6 | **S3 bucket credentials created** | The two IAM credentials/roles — see [Step2: Configure Secrets](#step2-configure-secrets) |
| 7 | **S3 buckets provisioned** | The **Server's** bucket, and the **File Scan Service source** bucket used by the **Client** |
| 8 | **Network Load Balancers (NLBs) reserved** | One for the Server service — commonly **internet-facing** with a pinned Elastic IP per AZ, since other DPN nodes must reach it externally — and one **internal** NLB for the Client service. See [Step3a](#step3a-configure-federator-server) |
| 9 | **OAuth2 client ID + Management Node URL + IDP URLs** | Received from DSM during onboarding |
| 10 | **Keycloak realm reachable** | Required when `kafka.authMode: sasl_ssl` (the production default) — the brokers and Kafka UI resolve tokens against `kafkaSrc.oauth.tokenEndpointUrl` / `kafkaTarget.oauth.tokenEndpointUrl` |
| 11 | **Container image tag available** | Built by the DSI CI process or prebuilt DSI image; supplied to the CD workflow as `imageTag` |
| 12 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step3: Configure Environment](#step3-configure-environment) |
| 13 | **IAM role for the platform's `ServiceAccount` (IRSA)** | Required when `serviceAccount.create: true` (the AWS default) — see [Step3e](#step3e-configure-aws-serviceaccount-irsa) |

> **Kafka's Keycloak secrets come from a Kubernetes Secret, not AWS Secrets Manager.** On every cloud — not only AWS — Kafka Source/Target, Kafka UI, and the Federator Server/Client read the Keycloak admin password (`KEYCLOAK_ADMIN_PASSWORD`) and the OAuth client secret directly from the **`dpn-keycloak-secrets`** Kubernetes secret created by the **DPN Authentication Service** deployment (see the [Overview](#overview) note above) — no template in the `dpn-platform` chart currently reads `secretsManager.secretPrefix` for these values, so populating that prefix alone will not provision them. This is separate from the Server/Client storage credentials in [Step2](#step2-configure-secrets).

> **No shared file share — but check `mountCertFileShare` when provisioning a new environment.** The gateway reads its certificate material from Vault directly (see the certificates-and-passwords note in [Overview](#overview)) when `vaultConfig.mountCertFileShare: false` is set. The chart's own reference `values.yaml` still defaults this to `true` for backward compatibility — confirm your environment's values file explicitly sets it to `false` rather than relying on the reference default, or the deprecated file share is mounted again.

> **One-time setup:** Before running the CD workflow, complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) — the workflow **does not create the namespace** (create it first with `kubectl create namespace <NAMESPACE>`). The workflow reads `AWS_REGION`, `AWS_ACCOUNT_ID`, `EKS_CLUSTER` and `NAMESPACE` (e.g. `ns-dpn-01`) from `dpn-federator-gateway/.github/config/aws/<environment>-<cluster>.json` — the release is deployed into `NAMESPACE`.

---

## Step2: Configure Secrets 

Secrets can be configured in two different approaches. 

### Option A - Use Kubernetes Secrets

The following Kubernetes secrets must be present in the namespace when the gateway pods start. Two are created automatically by the CSI driver from Key Vault; two are provided by earlier components.

| Kubernetes Secret | Provided by | Used for |
|-------------------|-------------|----------|
| `federator-server-secrets` | CSI driver from AKV Server S3 credentials | Server S3 access |
| `federator-client-secrets` | CSI driver from AKV Client S3 credentials | Client S3 access |
| `certificate-manager-secrets` | Created by the **Certificate Manager** deployment | Provides the credential the gateway uses to authenticate to Vault and read the certificate material/passwords — either the root token (`VAULT_TOKEN`, `authMethod: token`) or, by pointing `vaultConfig.appRole.roleId` at the Certificate Manager's own `role_id`, its shared AppRole `secret-id` |
| `cert-manager-truststore` | Created by the **`dpn-gha-vault-tls-bootstrap-cd.yaml`** workflow (`dpn-federator-certificate-manager` repository) | `truststore.jks` mounted at `/vault/truststore` to trust the Vault HTTPS endpoint |
| `tls-auth-secret` | Created once by **`dpn-gha-tls-cd.yaml`** (`dpn-federator-certificate-manager` repository) — the same platform-wide secret the Certificate Manager reads (see [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md#step2-configure-vault-authentication)) | `TRUSTSTORE_PASSWORD`/`KEYSTORE_PASSWORD` keys, injected as `VAULT_TRUSTSTORE_PASSWORD` and (when `kafka.authMode: sasl_ssl`) `KAFKA_SSL_TRUSTSTORE_PASSWORD`/`KAFKA_SSL_KEYSTORE_PASSWORD` |

---

## Step3: Configure Environment

The gateway chart is `charts/dpn-platform` in the `dpn-federator-gateway` repository (the workflow's `HELM_DIR`; the workflow checks out this same repository, so there is no other repository to check out). Set the parameters below in your environment/cluster's values file. The CD workflow resolves the values file from the `cloud`, `environment` and `cluster` inputs you select at runtime.

```text
dpn-federator-gateway/
└── charts/
      └── dpn-platform/
            ├── values.yaml                              <- Default settings for all components; do not edit directly
            └── values/aws/<environment>-<cluster>.yaml <- Your environment + cluster overrides
```

> All component images (`redis`, `zookeeperSrc/Target`, `kafkaSrc/Target`, `kafkaUI`, `federatorServer`, `federatorClient`) point at the container registry via `image.repository`. Set these to your registry, e.g. `ghcr.io/energy-dsi/<image>` (the path used by the checked-in AWS values files). Only the parameters most likely to change per deployment are listed below.

### Step3a: Configure Federator Server

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorServer.config.management_node_base_url` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` |
| `federatorServer.idp.clientId` | Client ID received from DSM for this DPN node | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `federatorServer.idp.jwksUrl` | JWKS endpoint for verifying identity tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/certs` |
| `federatorServer.idp.tokenUrl` | Token endpoint for access tokens | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| `federatorServer.service.internalLoadBalancer` | Whether the Server's NLB is internal-only. The Server's is commonly set to `"false"` (**internet-facing**) so external DPN nodes can reach it — unlike the Client, which stays internal | `"false"` |
| `federatorServer.service.eipAllocationId` | Elastic IP allocation(s) to pin to the Server's external NLB, **comma-separated** — an NLB takes one EIP per subnet/AZ, not one shared EIP, so a two-AZ deployment needs two allocation IDs here | `eipalloc-xxxxxxxx,eipalloc-yyyyyyyy` (leave unset for dynamically-assigned addresses) |

> **The Server has no storage configuration of its own.** Unlike the Client below, `federatorServer.storage.*` does not exist in this chart — the Server resolves the source type and target bucket per-request from the `FileTransferRequest` supplied by the Management Node API, not from a static bucket/region setting. Do not look for a Server-side S3 bucket parameter; there isn't one.

### Step3b: Configure Federator Client

> **Single cluster:** the Client (and this whole release) targets one DPN cluster. Its connection configuration points at a single remote Federator Server.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorClient.config.management_node_base_url` | DSI DSM Management Node URL | `https://management.dsm01.dsiXXX.neso.energy` |
| `federatorClient.config.targetTopic` | Target topic for received data | `dp-consumer-topic-stage` |
| `federatorClient.idp.clientId` | Client ID received from DSM | `xxxxxxxx-xxxx-xxxx-xxxx-000000000000` |
| `federatorClient.idp.jwksUrl` / `tokenUrl` | IDP endpoints and grant mode (as Server) | `https://auth-mtls.dsm01.dsiXXX.neso.energy/...` / |
| `federatorClient.storage.provider` | `S3` on this path | `S3` — important to set based on cloud provider; this parameter decides which storage provider is invoked |
| `federatorClient.storage.aws.bucket` | **The File Scan Service source bucket**, if available, else a separate bucket (not the Server's) — note the key is `storage.aws.bucket`, **not** `storage.s3.bucket` | `dp-consumer-raw` |
| `federatorClient.storage.aws.region` | Region of the Client's S3 bucket | `<AWS_REGION>` |

**JobRunr dashboard authentication** (optional — off by default; see [Federator Client — JobRunr Dashboard User Guide](../../../05-dpn-user-interfaces/03-federator-client-job-runner-ui-operations.md) for the end-user access flow)

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `federatorClient.auth.enabled` | Front the JobRunr dashboard with a built-in Keycloak-authenticating gateway instead of leaving it open on the internal network | `true` |
| `federatorClient.auth.issuerUrl` / `.audience` | Keycloak realm issuer and OIDC client ID (reuses the same client Kafka's OAuth already uses) | as received from DSM |
| `federatorClient.auth.adminRole` / `.readerRole` | Keycloak roles gating full vs. view-only dashboard access — leave both blank to allow any authenticated user full access | `dpnadmin` / `dpnreader` |
| `federatorClient.service.jobRunnerAuthPort` | The gateway's own bind port — must differ from `jobRunnerPort`, and is the **only** port exposed via the `-external` NLB Service | `8086` |
| `federatorClient.tls.gatewaySecretName` | Optional Kubernetes `Secret` mounted at `/tls-gateway` for a browser-facing TLS identity in front of the Job Runner dashboard. Empty by default (no mount) — set once the DPN universal TLS prerequisite pipeline has issued a certificate for this hostname | `fed-gateway-tls` |

> **Keycloak redirect URI must use the `-external` hostname.** The gateway runs its own OIDC authorization-code login. Register `https://<federatorClient.name>-external.<namespace>.svc.cluster.local:<jobRunnerAuthPort>/oauth2/callback` as the redirect URI on the Keycloak client — pointing it at the plain in-cluster hostname instead breaks the login callback (state-cookie mismatch), since Keycloak always redirects back to whichever hostname is configured here regardless of which one the browser actually started the login from.

### Step3c: Configure Kafka Security

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `kafka.authMode` | Security protocol for **every** Kafka listener (Source and Target) — `sasl_ssl` (production default), `ssl` (TLS only), or `plaintext` (dev/test only) | `sasl_ssl` |
| `kafkaSrc.oauth.tokenEndpointUrl` / `kafkaTarget.oauth.tokenEndpointUrl` | Keycloak token endpoint used for `OAUTHBEARER` login/validation when `authMode: sasl_ssl` | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| `kafkaUI.oauth.clientId` | OIDC client ID Kafka UI itself authenticates with (separate from `kafkaUI.oidcRbac`, below) | as received from DSM/Keycloak |
| `kafkaUI.tls.enabled` | Terminate HTTPS on Kafka UI's own listener, reusing the same `dpn-tls` keystore Kafka brokers and Redis already use. **Off by default** — only enable it in an environment where nothing else (e.g. an `oauth2-proxy`) depends on this listener staying plain HTTP, since Kafka UI drops its HTTP listener entirely once TLS is on | `false` |

> Switching `kafka.authMode` is a single value that reconfigures all broker listeners simultaneously — there is no need to change Kafka Source and Kafka Target separately. See [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md) to deploy the Keycloak instance and realm this depends on.

> **OpenTelemetry export.** `otel.tls.enabled` (default `true`) drives both the Federator Server/Client's OTLP exporter endpoint scheme and whether the OTel Collector truststore env vars are set at all — see [Configure DPN Health Monitoring Service](03-configure-dpn-health-monitoring-service.md) if your Collector's OTLP receiver terminates TLS (the default). `otel.collector.host` / `otel.collector.port` point at the Collector Service.

### Step3e: Configure AWS ServiceAccount (IRSA)

A single `ServiceAccount`, shared by Kafka Source/Target, Zookeeper Source/Target, the Federator Server, and the Federator Client, provides IAM Roles for Service Accounts (IRSA) credentials to the AWS Secrets Store CSI driver.

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `serviceAccount.create` | Render the `ServiceAccount` and attach it to every pod in this release | `true` |
| `serviceAccount.name` | Name of the `ServiceAccount` | `dpn-federator-gateway` |
| `serviceAccount.irsaRoleArn` | ARN of the IAM role the `ServiceAccount` assumes | `arn:aws:iam::<account-id>:role/dpn-federator-gateway-secrets-role` |
| `secretsManager.secretPrefix` | Reserved AWS Secrets Manager path prefix for this `ServiceAccount`'s IRSA role — **not currently read by any template in this chart** (Kafka's Keycloak admin password and OAuth client secret come from the `dpn-keycloak-secrets` Kubernetes secret instead; see the note above [Step1](#step1-meet-prerequisites)) | `dpn/<environment>-<cluster>/federator-gateway` |

The IAM role's trust policy must scope `sts:AssumeRoleWithWebIdentity` to `system:serviceaccount:<namespace>:<serviceAccount.name>`, and its permissions policy must grant S3 read/write on `federatorClient.storage.aws.bucket` — the Server has no static bucket parameter of its own (see [Step3a](#step3a-configure-federator-server)) — plus `secretsmanager:GetSecretValue` on `secretsManager.secretPrefix/*` for when that path is wired into a future chart update.

#### IAM role `dpn-federator-gateway-secrets-role`

Create this role manually, once per account/cluster. Reference policy files are kept in the `dpn-iam` export under `template/roles/dpn-federator-gateway-secrets-role/`.

1. Trust policy (`trust-policy.json`):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::<account-id>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<oidc-provider-id>"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "oidc.eks.<region>.amazonaws.com/id/<oidc-provider-id>:aud": "sts.amazonaws.com",
             "oidc.eks.<region>.amazonaws.com/id/<oidc-provider-id>:sub": "system:serviceaccount:ns-dpn-01:dpn-federator-gateway"
           }
         }
       }
     ]
   }
   ```

2. Permission policy (`dpn-federator-gateway-secrets-policy.json`):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "SecretsManagerRead",
         "Effect": "Allow",
         "Action": "secretsmanager:GetSecretValue",
         "Resource": "arn:aws:secretsmanager:<region>:<account-id>:secret:dpn/<environment>-<cluster>/federator-gateway/*"
       },
       {
         "Sid": "S3ServerBucket",
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
         "Resource": [
           "arn:aws:s3:::<application-bucket>",
           "arn:aws:s3:::<application-bucket>/*"
         ]
       },
       {
         "Sid": "S3ClientBucket",
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
         "Resource": [
           "arn:aws:s3:::<data-bucket>",
           "arn:aws:s3:::<data-bucket>/*"
         ]
       },
       {
         "Sid": "S3ClientChosenDataProductBuckets",
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
         "Resource": "arn:aws:s3:::*"
       }
     ]
   }
   ```

   `<application-bucket>` is the Server's bucket and `<data-bucket>` is `federatorClient.storage.aws.bucket`. The final `arn:aws:s3:::*` statement lets the Client write to whichever data-product buckets the consumer chooses; narrow it to the specific bucket ARNs if your organisation's policy requires.

3. Create the role and attach the policy, then set the role ARN as `serviceAccount.irsaRoleArn`:

   ```bash
   aws iam create-role \
     --role-name dpn-federator-gateway-secrets-role \
     --assume-role-policy-document file://trust-policy.json

   aws iam put-role-policy \
     --role-name dpn-federator-gateway-secrets-role \
     --policy-name dpn-federator-gateway-secrets-policy \
     --policy-document file://dpn-federator-gateway-secrets-policy.json
   ```

> **Kafka pods on AWS disable Python auto-instrumentation.** Kafka Source/Target and Zookeeper Source/Target pods carry `instrumentation.opentelemetry.io/inject-python: "false"` when `cloudProvider: aws` — the cluster's OTel auto-instrumentation webhook otherwise injects a `urllib3` build incompatible with these images' Python 3.9 startup tooling and crashes the pod on start. No action needed; this is set automatically.

---

## Step4: Configure Deployment Parameters

The Federator Gateway is deployed with a **single run** of the `dpn-gha-federator-gateway-cd.yaml` GitHub Actions workflow in the `dpn-federator-gateway` repository. One run applies the environment/cluster values file on top of `values.yaml` and deploys all components in the single Helm release `dpn-platform`.

```text
dpn-federator-gateway/
├── .github/
│   ├── workflows/
│   │   └── dpn-gha-federator-gateway-cd.yaml
│   ├── config/
│   │   └── aws/<environment>-<cluster>.json
│   └── actions/
│       └── cloud-login/action.yml
└── charts/
    └── dpn-platform/
        └── values/aws/<environment>-<cluster>.yaml
```

The workflow sets `PARAMETERS_FILE=.github/config/aws/<environment>-<cluster>.json`, `HELM_DIR=charts/dpn-platform`, `RELEASE_NAME=dpn-platform` and `VALUES_FILE=charts/dpn-platform/values/aws/<environment>-<cluster>.yaml` (the `aws` segment comes from the `cloud` input), and its job runs on a `[self-hosted, vmss]` runner bound to the GitHub Environment `<environment>-<cluster>`.

`workflow_dispatch` inputs:

| Input | Description |
|-----------|-------------|
| `environment` | `dev` / `test` (default `test`) |
| `cluster` | The **single** target DPN cluster — `dpn01` or `dpn02` (default `dpn01`). Deploy one cluster at a time; the Client is configured for this one cluster |
| `cloud` | `azure` / `aws` / `gcp` (default `aws`) — select `aws` on this path |
| `imageTag` | **Required**, no default — tag of the Federator images to deploy (from the CI build or prebuilt DSI image); applied to both `federatorServer.image.tag` and `federatorClient.image.tag` |
| `serverImageRepository` | Optional — overrides the Server image path after `ghcr.io/energy-dsi/` for this run only (e.g. `dpn-federator-server`), passed as `federatorServer.image.repository`. Leave blank to use the values file's repository |
| `clientImageRepository` | Optional — same override for the Client image path (e.g. `dpn-federator-client`), passed as `federatorClient.image.repository`. Leave blank to use the values file's repository |

> When `serverImageRepository` / `clientImageRepository` are left blank, the image repositories come from `federatorServer.image.repository` / `federatorClient.image.repository` in the values file (e.g. `ghcr.io/energy-dsi/dpn-federator-server` / `ghcr.io/energy-dsi/dpn-federator-client`). The workflow rejects any of the three image inputs that has leading or trailing whitespace.

To run it: **Actions → DPN CD - Federator Gateway → Run workflow**, fill in the inputs, then **Run workflow**. On success, the deployed image digests are captured as the `deployed-image-digest` workflow artifact.

Once this is deployed, provision the per-product producer/consumer pods and the S3 bucket/Kafka-topic prerequisites they need — see [Configure DPN Data Pipelines](07-configure-dpn-data-pipelines.md) and the [installation guide](../03-installation/05-dpn-federator-gateway-installation-process.md).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V2.0.0 |
