# DPN Authentication Service Installation Process

This document covers the installation of the **DPN Authentication Service** — the platform's OAuth2/OIDC identity provider, **Keycloak** — into a single target environment and DPN cluster on Azure Kubernetes Service (AKS).

**Full instructions live in the configuration guide.** The end-to-end Authentication Service flow — overview, prerequisites, the secrets/TLS/values to populate, deployment, realm configuration and post-deployment verification — is documented in one place:

**[Configure DPN Authentication Service](../02-configuration/02-configure-dpn-authentication-service.md)**

This installation page is a quick-reference summary that points to that guide.

**Deploy this before components that authenticate against it.** The DPN components authenticate against the realm this service creates. Deploy the Authentication Service immediately after Vault service is deployed

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
  - [Configure Realm, Client, Roles and Audit Logging Step Fails on First Deploy](#configure-realm-client-roles-and-audit-logging-step-fails-on-first-deploy)
- [Review Notes](#review-notes)

---

## Overview

Keycloak is deployed into `ns-dpn-01` over **standard HTTPS/TLS 1.2+**. It is reachable only inside DPN cluster and through an internal Azure Load Balancer. It is bundled with its own PostgreSQL instance on a persistent volume.

Unlike the other DPN repositories, this service does **not** build a custom image via a CI pipeline. The CD pipeline mirrors the stock upstream images (`quay.io/keycloak/keycloak` and `docker.io/library/postgres`) into the environment's own ACR at deploy time (`az acr import`), so there is no separate CI stage or GHCR-hosted image to configure.

```text
Root-Repository/
└── charts/
    └── keycloak/                                Keycloak + PostgreSQL Helm chart
        ├── Chart.yaml
        ├── values.yaml                          base values — reference only
        ├── values-<env>-<cluster>.yaml           9 environment overlays
        ├── scripts/
        │   └── configure-keycloak.sh              realm/clients/roles/groups/audit config, run as a pipeline step
        ├── themes/
        │   └── dpn-portal/
        │       └── login/                          custom "dpn-portal" login theme (theme.properties + CSS)
        └── templates/
            └── theme-configmap.yaml                 packages themes/dpn-portal into a ConfigMap, mounted into the pod

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

Confirm the prerequisites before starting — see [Configure DPN Authentication Service → Step1: Meet the Prerequisites](../02-configuration/02-configure-dpn-authentication-service.md#step1-meet-the-prerequisites).

In summary the following must be in place:

- AKS cluster, a user-assigned managed identity, and the Secrets Store CSI driver
- `dpn-tls` Kubernetes secret present in the target namespace (Java `keystore.jks`/`truststore.jks`, **not** a `kubernetes.io/tls` secret)
- Five Key Vault secrets populated: `KC-DB-PASSWORD`, `KEYCLOAK-ADMIN-PASSWORD`, `KC-HTTPS-KEY-STORE-PASSWORD`, `KC-HTTPS-TRUST-STORE-PASSWORD`, `KC-SERVICE-CLIENT-SECRET`
- `.pipelines/azure-pipelines/config/<env>-<cluster>.json` and `charts/keycloak/values-<env>-<cluster>.yaml` populated
- Target namespace and Azure DevOps service connection created (the pipeline does not create either)

**Note:** Organisations must review the CD pipeline code for the following.

- The agent pool name has been modified to the Organisation's required agent pool name
- There should not be any `<<Your specific value>>` placeholders left in the parameters
- `KC-SERVICE-CLIENT-SECRET` matches whatever secret value is already configured on the consuming services' side — the `dpn-health-monitoring-service` oauth2-proxy releases (OpenSearch Dashboards, Jaeger, Perses, Portal) and Kafka UI's own `SecretProviderClass` — a mismatch does not fail the pipeline, it fails login for every dependent UI
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

On success the Deploy stage's realm-configuration step completes with `Keycloak configuration complete: realm <realm>, clients <machine-client> + <ui-client>.`

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

Tail the logs and confirm there are no startup errors:

```bash
kubectl logs -n <namespace> -l app=dpn-keycloak --tail=100
```

---

## Step3: Post-Deployment Realm and Client Configuration

Unlike a plain Helm-only deployment, the Deploy stage of `dpn-keycloak-cd.yaml` runs an additional step — **"Configure Realm, Client, Roles and Audit Logging"** — after `helm upgrade --install` completes. This step port-forwards to the freshly deployed Keycloak Service and runs `charts/keycloak/scripts/configure-keycloak.sh`, which authenticates to the `master` realm as the bootstrap admin and then makes plain `curl`/`jq` calls against the Keycloak Admin REST API (idempotent — create on first run, update on later ones). There is no Helm hook, no Kubernetes Job, no `kcadm`, and no realm-JSON file import involved — everything below is created/updated by this one script, as one pipeline step:

| Object | Purpose |
|---|---|
| `<realmName>` realm (default `dpn-realm`) | Realm-level settings: `ssoSessionIdleTimeout`, `ssoSessionMaxLifespan`, `rememberMe`, login theme, and event/audit toggles |
| `DPN-Client` (machine-to-machine) | Client-credentials-only client for service-to-service calls; realm roles (`dpnreader`, `dpnadmin`, `dpnoperator`) mapped onto its service account |
| Audit logging | `PUT /admin/realms/<realm>/events/config` — enables every event type reported by `/admin/serverinfo`, with configurable retention |
| `dpn-service-client` (UI client) | Shared OIDC client used by every DPN UI behind `oauth2-proxy` (OpenSearch Dashboards, Jaeger, Perses, Portal) plus the native-OIDC Kafka UI; carries the audience/realm-roles/groups protocol mappers |
| Groups (`dpn-admins`, `dpn-readers`, `dpn-operators`) | Each group carries one realm role, so access can be managed by group membership |

Two things to confirm after every deploy:

- The redirect URIs / web origins registered on `dpn-service-client` cover every UI that needs to authenticate in this environment. These come from the `KC_UI_HOST_*` environment variables read by `configure-keycloak.sh` (e.g. `KC_UI_HOST_KAFKA_UI`, `KC_UI_HOST_AIRFLOW`, `KC_UI_HOST_PORTAL`) — each has a hardcoded default baked into the script itself, and the CD pipeline does not currently override any of them per environment. Adding or changing a UI's hostname requires editing the pipeline step (to export the relevant `KC_UI_HOST_*` variable) or the script's own default.
- `KC-SERVICE-CLIENT-SECRET` in this environment's Key Vault matches the secret value already configured on the consuming services' side — this is a manual, hand-kept-in-sync value, not sourced from a shared location.

**Login theme.** The realm's login screen uses a custom theme, not stock Keycloak. The theme files live under `charts/keycloak/themes/dpn-portal/login/` (`theme.properties` and a CSS resource), get packaged into a ConfigMap by `templates/theme-configmap.yaml`, and are mounted into the Keycloak pod at `/opt/keycloak/themes/dpn-portal`. `configure-keycloak.sh` applies it to the realm via two more `KC_*` environment variables — same pattern as `KC_UI_HOST_*` above, each with a hardcoded script default and no per-environment override in the CD pipeline today:

| Variable | Default | Purpose |
|---|---|---|
| `KC_LOGIN_THEME` | `dpn-portal` | Login theme applied realm-wide (every UI's login screen) |
| `KC_DISPLAY_NAME_HTML` | `<span class="dpn-kc-brand"><strong>DSI DPN Platform</strong></span>` | Realm header markup shown above the login form |

Changing the branding therefore means either editing the theme files/CSS directly, or exporting a different `KC_LOGIN_THEME`/`KC_DISPLAY_NAME_HTML` value in the pipeline step.

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

- The UI's hostname matches the corresponding `KC_UI_HOST_*` value that `configure-keycloak.sh` was run with (its hardcoded default, unless the pipeline step has been edited to override it) for this environment/cluster.
- For UIs behind `oauth2-proxy` (OpenSearch Dashboards, Jaeger, Perses, Portal), the bare root hostname (no path) matches the `post.logout.redirect.uris` entry and the `post_logout_redirect_uri` the proxy actually sends.
- `KC-SERVICE-CLIENT-SECRET` in Key Vault matches the secret configured on the consuming service's side.

---

### Configure Realm, Client, Roles and Audit Logging Step Fails on First Deploy

This pipeline step can fail if it reaches Keycloak before the Service's endpoint has finished propagating. `configure-keycloak.sh` port-forwards to the Keycloak Service and polls `${KC_BASE_URL}/realms/master` for up to 60 seconds before authenticating; if it still fails, check the step's own pipeline logs, or re-run the CD pipeline — the script is idempotent, so re-running it is safe.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 | 