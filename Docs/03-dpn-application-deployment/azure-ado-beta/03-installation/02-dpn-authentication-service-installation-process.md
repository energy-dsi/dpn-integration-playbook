# DPN Authentication Service Installation Process

This document covers the installation of the **DPN Authentication Service** — the platform's OAuth2/OIDC identity provider, **Keycloak** — into a single target environment and DPN cluster on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Authentication Service flow — overview, prerequisites, the secrets/TLS/values to populate, deployment, realm configuration and post-deployment verification — is documented in one place:

**[Configure DPN Authentication Service](../02-configuration/07-configure-dpn-authentication-service.md)**

This installation page is a quick-reference summary that points to that guide.

**Deploy this before components that authenticate against it.** The Federator Gateway's Kafka brokers (`kafka.authMode: sasl_ssl`) and the DPN observability UIs (kafka-ui, Airflow, OpenSearch Dashboards, Jaeger, Perses, Portal) authenticate against the realm this service creates. Deploy the Authentication Service first.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CD Pipeline](#step2-execute-cd-pipeline)
  - [Step2a. Configure Authentication Service CD Pipeline](#step2a-configure-authentication-service-cd-pipeline)
  - [Step2b. Execute Authentication Service CD Pipeline](#step2b-execute-authentication-service-cd-pipeline)
  - [Step2c. Verify Authentication Service CD Pipeline](#step2c-verify-authentication-service-cd-pipeline)
- [Step3: Post-Deployment Realm and Client Configuration](#step3-post-deployment-realm-and-client-configuration)
- [Step4: Uninstalling the Authentication Service](#step4-uninstalling-the-authentication-service)
- [Step5: Troubleshooting](#step5-troubleshooting)
  - [Key Vault Secret Preflight Failure](#key-vault-secret-preflight-failure)
  - [KC_HTTPS_KEY_ALIAS Not Found](#kc_https_key_alias-not-found)
  - [Certificate SAN Does Not Cover KC_HOSTNAME](#certificate-san-does-not-cover-kc_hostname)
  - [Internal Load Balancer Has No Assigned IP](#internal-load-balancer-has-no-assigned-ip)
  - [Downstream Login/Logout Failures After Deploy](#downstream-loginlogout-failures-after-deploy)
  - [Realm Import Job Fails on First Deploy](#realm-import-job-fails-on-first-deploy)
- [Review Notes](#review-notes)

---

## Overview

Keycloak is deployed into `ns-dpn-01` over **standard one-way HTTPS** (`KC_HTTPS_CLIENT_AUTH=none`, `KC_HTTP_ENABLED=false`), reachable in-cluster and through an internal Azure Load Balancer only. It is bundled with its own PostgreSQL instance on a persistent volume.

Unlike the other DPN repositories, this service does **not** build a custom image via a CI pipeline. The CD pipeline mirrors the stock upstream images (`quay.io/keycloak/keycloak` and `docker.io/library/postgres`) into the environment's own ACR at deploy time (`az acr import`), so there is no separate CI stage or GHCR-hosted image to configure.

```text
Root-Repository/
└── charts/
    └── keycloak/                                Keycloak + PostgreSQL Helm chart
        ├── Chart.yaml
        ├── values.yaml                          base values — reference only
        ├── values-<env>-<cluster>.yaml           9 environment overlays
        ├── dpn-realm.json                        realm/client/roles imported on every deploy
        └── templates/

.pipelines/
└── azure-pipelines/
    ├── cd-pipelines/
    │   ├── dpn-keycloak-cd.yaml                  deploy pipeline
    │   └── dpn-keycloak-uninstall-cd.yaml        uninstall pipeline
    └── config/
        └── <env>-<cluster>.json                  subscription / RG / AKS / Key Vault per environment
```

---

## Step1: Verify Prerequisites

Confirm the prerequisites before starting — see [Configure DPN Authentication Service → Step1: Meet the Prerequisites](../02-configuration/07-configure-dpn-authentication-service.md#step1-meet-the-prerequisites).

In summary the following must be in place:

- AKS cluster, a user-assigned managed identity, and the Secrets Store CSI driver
- `dpn-tls` Kubernetes secret present in the target namespace (Java `keystore.jks`/`truststore.jks`, **not** a `kubernetes.io/tls` secret)
- Five Key Vault secrets populated: `KC-DB-PASSWORD`, `KEYCLOAK-ADMIN-PASSWORD`, `KC-HTTPS-KEY-STORE-PASSWORD`, `KC-HTTPS-TRUST-STORE-PASSWORD`, `KC-SERVICE-CLIENT-SECRET`
- `.pipelines/azure-pipelines/config/<env>-<cluster>.json` and `charts/keycloak/values-<env>-<cluster>.yaml` populated
- Target namespace and Azure DevOps service connection created (the pipeline does not create either)

**Note:** Organisations must review the CD pipeline code for the following.

- The agent pool name has been modified to the Organisation's required agent pool name
- There should not be any `<<Your specific value>>` placeholders left in the parameters
- `KC-SERVICE-CLIENT-SECRET` matches whatever secret value is already configured on the consuming services' side (`dpn-health-monitoring-service`'s oauth2-proxy/kafka-ui/airflow) — a mismatch does not fail the pipeline, it fails login for every dependent UI
- The environment parameters point to the correct deployment environment
- Required firewall rules are applied (outbound access to the container registry, and inbound from consuming namespaces to the internal load balancer)
- The CD pipeline is verified against the above prerequisites before execution

---

## Step2: Execute CD Pipeline

### Step2a. Configure Authentication Service CD Pipeline

Create a new Azure DevOps Pipeline from the CD pipeline YAML file located at the following path:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-keycloak-cd.yaml
```

---

### Step2b. Execute Authentication Service CD Pipeline

The CD pipeline requires the following runtime parameters:

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | Azure service connection for the target environment (e.g. `sc-dpn-dev-001`) |
| `environment` | Target environment — `dev`, `devtest`, `test`, `pdev`, `ptest`, `puat` |
| `dpnCluster` | `dpn01` or `dpn02` (`pdev`/`ptest`/`puat` are single-DPN — `dpn02` is blocked for those environments) |

The pipeline runs three stages:

1. **Validate** — confirms the required Key Vault secrets exist (including `KC-SERVICE-CLIENT-SECRET`), verifies the TLS keystore/alias/SAN against the target cluster's `dpn-tls` secret, then runs `helm lint` and a `helm upgrade --dry-run`.
2. **Deploy** (gated behind the environment's approval group — `dsi-dev`, `dsi-devtest` or `dsi-ppd`) — mirrors the upstream Keycloak/PostgreSQL images into ACR, runs `helm upgrade --install`, waits for both deployments to roll out, records the deployed image digest as a build artifact, then configures the realm, service client, roles and audit logging via `charts/keycloak/scripts/configure-keycloak.sh`.
3. **Verify** — confirms pods and the load balancer are healthy, asserts the load balancer is genuinely internal, checks the HTTPS endpoint from inside the cluster, and confirms plaintext HTTP (port 8080) is refused.

On success the Deploy stage's realm-import step completes with `Keycloak configuration complete: realm <realm>, client <client>.`

---

### Step2c. Verify Authentication Service CD Pipeline

```bash
kubectl get pods -n <namespace> -l app=dpn-keycloak
kubectl get pods -n <namespace> -l app=dpn-keycloak-postgres
kubectl get svc  -n <namespace> dpn-keycloak-service-lb
```

Confirm the internal load balancer has an assigned IP and is annotated internal:

```bash
kubectl get svc dpn-keycloak-service-lb -n <namespace> \
  -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-internal}'
```

Tail the logs and confirm there are no startup or realm-import errors:

```bash
kubectl logs -n <namespace> -l app=dpn-keycloak --tail=100
```

---

## Step3: Post-Deployment Realm and Client Configuration

Unlike a plain Helm-only deployment, the Deploy stage of `dpn-keycloak-cd.yaml` also creates/updates the following automatically on every run — no manual admin-console step is required for these:

| Object | Created by | Purpose |
|---|---|---|
| `<realmName>` realm (default `dpn-realm`) | Helm post-install/upgrade hook (`templates/realm-import-job.yaml`), importing `dpn-realm.json` | Realm roles (`dpnadmin`, `dpnreader`), groups, and the shared browser client |
| `dpn-service-client` | Same hook | Shared OIDC client used by every DPN UI (kafka-ui, Airflow directly; OpenSearch Dashboards/Jaeger/Perses/Portal via their `oauth2-proxy` sidecars) |
| Realm session/audit settings (`ssoSessionIdleTimeout`, `ssoSessionMaxLifespan`, event retention) | Same hook, via `kcadm update realms/` and `kcadm update events/config` (fields Keycloak's `partialImport` endpoint silently drops) | Session ceilings and audit log retention |
| `DPN-Client` (machine-to-machine) | `configure-keycloak.sh`, run as a separate pipeline step after Helm completes | Client-credentials-only client for service-to-service calls; realm roles mapped onto its service account |

Two things to confirm after every deploy:

- The redirect URIs / web origins on `dpn-service-client` (`charts/keycloak/values-<env>-<cluster>.yaml` → `uiHosts.*`) cover every UI that needs to authenticate in this environment. Add a new UI's hostname here before it can complete login.
- `KC-SERVICE-CLIENT-SECRET` in this environment's Key Vault matches the secret value already configured on the consuming services' side — this is a manual, hand-kept-in-sync value, not sourced from a shared location.

---

## Step4: Uninstalling the Authentication Service

Uninstall via the second pipeline in this repository:

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── dpn-keycloak-uninstall-cd.yaml
```

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | Azure service connection for the target environment |
| `environment` | Target environment |
| `dpnCluster` | `dpn01` or `dpn02` |
| `deletePvc` | `false` (default) retains the PostgreSQL PVC so realm data survives a reinstall; `true` **permanently destroys all realms, users and clients** |

The pipeline runs **Guard** (blocks `dpn02` for single-DPN environments) → **Approval** → **Uninstall** (`helm uninstall`, then conditionally deletes the PostgreSQL PVC).

---

## Step5: Troubleshooting

### Key Vault Secret Preflight Failure

The Validate stage fails with `[MISSING] <secret> not found in <vault>` if any of the four CSI-mounted secrets, or `KC-SERVICE-CLIENT-SECRET`, is absent from the environment's Key Vault. Create the missing secret and re-run.

---

### KC_HTTPS_KEY_ALIAS Not Found

Keycloak aborts at startup if `config.KC_HTTPS_KEY_ALIAS` does not match a real alias inside `dpn-tls`'s `keystore.jks`. Find the correct alias:

```bash
kubectl get secret dpn-tls -n <namespace> \
  -o jsonpath='{.data.keystore\.jks}' | base64 -d > keystore.jks

keytool -list -keystore keystore.jks -storepass <keystore-password>
```

Set `config.KC_HTTPS_KEY_ALIAS` in `values-<env>-<cluster>.yaml` to the alias listed, then re-run the CD pipeline.

---

### Certificate SAN Does Not Cover KC_HOSTNAME

The Validate stage prints a warning (not a hard failure) if the certificate behind `KC_HTTPS_KEY_ALIAS` does not carry `config.KC_HOSTNAME` as a SAN. Keycloak will still start, but every issuer URL and redirect URI it advertises will use the mismatched hostname, which browsers/consumers will reject. Set `KC_HOSTNAME` to a name the certificate actually carries, or leave it empty with `KC_HOSTNAME_STRICT: "false"` to derive the hostname from the incoming request instead.

---

### Internal Load Balancer Has No Assigned IP

The Verify stage fails with `Internal load balancer has no assigned IP yet` if Azure has not finished provisioning the LB frontend. Check the Service:

```bash
kubectl describe svc dpn-keycloak-service-lb -n <namespace>
```

Common causes: the subnet has no free IPs, or `service.loadBalancer.loadBalancerIP` in the values file pins an address already in use. Leave it empty on first deploy and pin the auto-assigned address afterwards.

---

### Downstream Login/Logout Failures After Deploy

If a specific UI cannot complete login, or logout leaves the SSO session alive with an "Invalid redirect uri" error, check:

- The UI's hostname is present in `uiHosts.*` in `values-<env>-<cluster>.yaml` for this environment/cluster.
- For UIs behind `oauth2-proxy` (OpenSearch Dashboards, Jaeger, Perses, Portal), the bare root hostname (no path) matches the `post.logout.redirect.uris` entry and the `post_logout_redirect_uri` the proxy actually sends.
- `KC-SERVICE-CLIENT-SECRET` in Key Vault matches the secret configured on the consuming service's side.

---

### Realm Import Job Fails on First Deploy

The `<release>-realm-import` Job can fail if it reaches Keycloak before the Service's endpoint has finished propagating. It polls the HTTPS port for up to 60 seconds before running `kcadm`; if it still fails, check the Job's logs directly:

```bash
kubectl logs -n <namespace> job/dpn-keycloak-realm-import
```

Re-running the CD pipeline re-runs this Job (`helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded` allows it to run again on every upgrade).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-------------------|--------|---------|
| — | — | Draft — pending DSI Assurance review | V0.1.0 |
