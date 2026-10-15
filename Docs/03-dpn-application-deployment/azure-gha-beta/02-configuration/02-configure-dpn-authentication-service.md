Release : 2.1.0 - Oct 2026

# DPN Authentication Service (Keycloak) Configuration

This section describes how to configure and deploy the **DPN Authentication Service** — the platform's OAuth2/OIDC identity provider, **Keycloak** — into a single target environment and DPN cluster on Azure Kubernetes Service (AKS).

**Deploy this immediately after Vault service deployed.** Deploy the Authentication Service, and create the realm/clients it expects, before enabling Keycloak-based auth on those components.

> **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`, e.g. `dpn01`). Substitute your own values throughout.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
- [Step3: Configure TLS](#step3-configure-tls)
- [Step4: Environment Configuration](#step4-environment-configuration)
  - [Step4a: Horizontal Pod Autoscaling](#step4a-horizontal-pod-autoscaling)
- [Step5: Configure Deployment Parameters](#step5-configure-deployment-parameters)
- [Review Notes](#review-notes)

---

## Overview

Keycloak is deployed into `ns-dpn-01` over **standard one-way HTTPS** (`KC_HTTPS_CLIENT_AUTH=none`, `KC_HTTP_ENABLED=false`), reachable in-cluster and through an internal Azure Standard Load Balancer only. It runs as a **StatefulSet** (each replica gets its own PersistentVolumeClaim, see [Step4a](#step4a-horizontal-pod-autoscaling)) and is bundled with its own PostgreSQL instance on a persistent volume.

| | |
|---|---|
| In-cluster URL | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443` |
| External access | Internal Load Balancer (`dpn-keycloak-service-lb`), VNet only |
| Database | Bundled PostgreSQL (`dpn-keycloak-postgres`) — can be pointed at a managed database instead (see [Step4](#step4-environment-configuration)) |
| Secrets | Azure Key Vault via the Secrets Store CSI driver (DB/admin passwords and the service-client secret), plus the shared `tls-auth-secret` Kubernetes secret (keystore/truststore passwords). See [Step2](#step2-configure-secrets) |
| Cloud provider | No `cloudProvider` value is needed: the chart's `SecretProviderClass` is `provider: azure` and its LoadBalancer Service carries the Azure internal-LB annotation. The provided `charts/keycloak/values/azure/*.yaml` files do not set `cloudProvider`. See [Step4](#step4-environment-configuration) |

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **AKS cluster** with a user-assigned managed identity that can read the Key Vault | Needed for the Secrets Store CSI driver to pull the secrets in [Step2](#step2-configure-secrets). The chart's `SecretProviderClass` uses `useVMManagedIdentity: "true"` with `userAssignedIdentityID` set from `keyvault.clientID` |
| 2 | **`dpn-tls` and `tls-auth-secret` Kubernetes secrets present in the namespace** | `dpn-tls` is an `Opaque` secret holding `ca.crt`/`keystore.jks`/`truststore.jks` (Java keystores, **not** a `kubernetes.io/tls` secret); `tls-auth-secret` holds the matching `KEYSTORE_PASSWORD`/`TRUSTSTORE_PASSWORD`. Both must be created before Keycloak is deployed. See [Step3: Configure TLS](#step3-configure-tls) |
| 3 | **Three secrets populated in Azure Key Vault** | See [Step2: Configure Secrets](#step2-configure-secrets) |
| 4 | **Container image available** | Stock upstream Keycloak/PostgreSQL pulled via GHCR (`ghcr.io/energy-dsi/keycloak`, `ghcr.io/energy-dsi/postgres`); repository pinned in the environment values file, tag defaulting to the chart's `values.yaml`. The CD workflow's optional `keycloakImageRepository`/`keycloakImageTag`/`postgresImageRepository`/`postgresImageTag` inputs override these per run |
| 5 | **Config JSON and values file populated for the `<environment>-<cluster>` combination** | See [Step4: Environment Configuration](#step4-environment-configuration) |

> **One-time setup:** create the target namespace ns-dpn-01 and ns-dpn-health-01 (`kubectl create namespace <namespace>`) and complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) before running the CD workflow — it does not create the namespace for you.

---

## Step2: Configure Secrets


The deploy workflow's "Key Vault Secret Preflight" step reads the required secret names out of the rendered `SecretProviderClass` (plus an explicit check for `KC-SERVICE-CLIENT-SECRET`) and fails fast if any is missing from `KEY_VAULT_NAME`, rather than letting the pod fail with an opaque CSI mount error. All three secrets below — including `KC-SERVICE-CLIENT-SECRET` — are CSI-mounted into the pod the same way, and synced into the `dpn-keycloak-secrets` Kubernetes Secret. `KEYCLOAK-ADMIN-PASSWORD` and `KC-SERVICE-CLIENT-SECRET` are additionally fetched directly from Azure Key Vault by the CD workflow itself — since `configure-keycloak.sh` runs on the GitHub Actions runner via port-forward, not inside the pod, it needs its own copy rather than reading it out of the pod's env (see [Step5](#step5-configure-deployment-parameters)).

**Azure Key Vault**

The chart's `SecretProviderClass` (`dpn-keycloak-kv-secrets`) reads from the vault named in `keyvault.name` (tenant `keyvault.tenantId`) using the user-assigned managed identity in `keyvault.clientID` (`useVMManagedIdentity: "true"`). Secrets must exist in Key Vault under the names below (set by `keyvault.secrets.*` in the chart's `values.yaml`):

| Key Vault secret | Becomes (in `dpn-keycloak-secrets`) | Used by |
|---|---|---|
| `KC-DB-PASSWORD` | `KC_DB_PASSWORD` | Keycloak, and PostgreSQL via `POSTGRES_PASSWORD_FILE` |
| `KEYCLOAK-ADMIN-PASSWORD` | `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin account; also read by the workflow's realm-configuration step |
| `KC-SERVICE-CLIENT-SECRET` | `KC_SERVICE_CLIENT_SECRET` | `dpn-service-client`'s client secret — Keycloak pod (via `envFrom`) and `configure-keycloak.sh` (fetched separately by the CD workflow), so it must match what consuming UIs already use |

None of these three is created by a workflow — set them manually.

> **Keystore/truststore passwords no longer come from the SecretProviderClass.** `KC_HTTPS_KEY_STORE_PASSWORD`/`KC_HTTPS_TRUST_STORE_PASSWORD` are read from the shared `tls-auth-secret` Kubernetes secret (keys `KEYSTORE_PASSWORD`/`TRUSTSTORE_PASSWORD`) created by `dpn-gha-tls-cd.yml`.

> **Note — two different secret sources on this page.** Everything in the table above lives in **Azure Key Vault** and is synced into the cluster automatically via the CSI Secrets Store driver — nothing here needs a manual `kubectl create secret`. `dpn-tls` and `tls-auth-secret` (Step1 prerequisite #2, configured in [Step3](#step3-configure-tls)) are different, unrelated things: plain **Kubernetes** Secrets created ahead of time by the TLS prerequisite workflow, not part of this Azure Key Vault flow at all.


---

## Step3: Configure TLS

Keycloak reads its certificate from the pre-existing `dpn-tls` secret (mounted read-only at `/cert`) rather than from Vault or the Certificate Manager — this is a platform/ingress-style certificate, not the DPN's DSM-signed federation certificate.

1. Create `dpn-tls` (and `tls-auth-secret`) in the target namespace by running **Actions → DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1 → Run workflow** (`dpn-gha-tls-cd.yml`, in `dpn-federator-certificate-manager`) with `cloud: azure`, your `environment`/`cluster`, and `targetNamespace: ns-dpn-01`. It creates `dpn-tls` as an `Opaque` secret with `ca.crt`, `keystore.jks` and `truststore.jks`, and `tls-auth-secret` with the matching `KEYSTORE_PASSWORD`/`TRUSTSTORE_PASSWORD`.
2. Find the alias of the server key inside `keystore.jks` (for a keystore generated by `dpn-gha-tls-cd.yml` it is `dpn-server`):

   ```sh
   kubectl get secret dpn-tls -n <namespace> \
     -o jsonpath='{.data.keystore\.jks}' | base64 -d > keystore.jks

   keytool -list -keystore keystore.jks \
     -storepass "$(kubectl get secret tls-auth-secret -n <namespace> \
       -o jsonpath='{.data.KEYSTORE_PASSWORD}' | base64 -d)"
   ```

3. Set `config.KC_HTTPS_KEY_ALIAS` to that alias in the environment values file — Keycloak aborts at startup if the alias does not exist.

4. Set `config.KC_HOSTNAME` to a DNS name the certificate's SANs actually cover. The chart default is the in-cluster FQDN (`https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443`). The certificate generated by `dpn-gha-tls-cd.yml` carries wildcard SANs `*.ns-dpn-01.svc.cluster.local`, `*.ns-dpn-health-01.svc.cluster.local` and `*.ns-dpn-dp-01.svc.cluster.local`. The provided Azure values files set `KC_HOSTNAME: ""` with `KC_HOSTNAME_STRICT: "false"`, so Keycloak derives the hostname from each request (it is reached on the internal LB IP, via port-forward and on the in-cluster DNS name).

   > **Note — pin `KC_HOSTNAME` rather than leaving it empty when a browser-facing consumer is involved.** With `KC_HOSTNAME` left dynamic, Keycloak derives its OIDC issuer/redirect URLs from whichever `Host` header the request arrived on — including internal server-to-server calls, which arrive on the in-cluster `svc.cluster.local` name. That unresolvable hostname can then leak into a browser-facing authorize redirect (seen as `DNS_PROBE_FINISHED_NXDOMAIN` for browser-facing consumers using Keycloak SSO login). Pin `KC_HOSTNAME` to the externally-reachable Load Balancer Service name, for example `https://dpn-keycloak-service-lb.<namespace>.svc.cluster.local:8443` and keep `KC_HOSTNAME_STRICT: "false"` so in-cluster callers still work.

---

## Step4: Environment Configuration

Set the parameters below in your environment/cluster's values file.

```text
root/
  └── charts/
        └── keycloak/
          └── values/
              └── azure/           
                └── <environment>-<cluster>.yaml <- Your environment + cluster overrides
```

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `config.KC_HOSTNAME` | Hostname Keycloak advertises — must match the certificate SANs. The provided Azure values files leave it empty so it is derived from the request (chart default `https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443`) | `""` |
| `config.KC_HOSTNAME_STRICT` | Whether Keycloak rejects requests whose `Host` header doesn't match `KC_HOSTNAME` (chart default `"true"`). Leave `"false"` while `KC_HOSTNAME` itself is left empty | `"false"` |
| `config.KC_HTTPS_KEY_ALIAS` | Alias of the server key inside `keystore.jks` | *(from Step3)* |
| `service.loadBalancer.loadBalancerIP` | Static IP for Keycloak's internal LoadBalancer Service (rendered as the `azure-load-balancer-ipv4` annotation). Leave empty on first deploy — Azure auto-assigns one from the subnet — then pin the assigned IP here so it survives a Service recreation | `""`, then the assigned IP (e.g. `10.87.32.9`) |
| `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | Key Vault name, user-assigned managed identity client ID and tenant ID used by the `SecretProviderClass` (see [Step2](#step2-configure-secrets)) | `kv-dpn-azure-<env>-uks-<nnn>` / `<client-id>` / `<tenant-id>` |
| `keyvault.secrets.dbPassword` / `.adminPassword` / `.serviceClientSecret` | Key Vault secret names (chart defaults shown) | `KC-DB-PASSWORD` / `KEYCLOAK-ADMIN-PASSWORD` / `KC-SERVICE-CLIENT-SECRET` |
| `image.repository` | GHCR path for the Keycloak image (tag defaults to the chart's `image.tag`, `26.3.2`) | `ghcr.io/energy-dsi/keycloak` |
| `postgres.image.repository` | GHCR path for the bundled PostgreSQL image (tag defaults to `postgres.image.tag`, `16-alpine`) | `ghcr.io/energy-dsi/postgres` |

---

### Step4a: Horizontal Pod Autoscaling

Keycloak now runs as a **StatefulSet** rather than a Deployment, so scaling past a single replica is safe: `volumeClaimTemplates` gives every pod its own PersistentVolumeClaim, avoiding the `ReadWriteOnce` Multi-Attach failure a shared claim would hit. All of Keycloak's actual state (realms, clients, users, sessions) lives in the one shared Postgres every replica already points at — each pod's own PVC only holds its local JTA transaction-log recovery store.

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `hpa.enabled` | Turn on the `HorizontalPodAutoscaler` (chart default `false`; the provided Azure `test-dpn01`/`test-dpn02` values files set `true`) | `false` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.cpuUtilization` / `hpa.memoryUtilization` | Target average utilization (%) that triggers scaling | `80` / `80` |
| `hpa.scaleStep` | Pods added/removed per scaling step | `1` |

> **`persistence.existingClaim` only works at `replicaCount: 1`.** If set, every replica would otherwise mount the same named claim. Leave it unset to let the StatefulSet provision a claim per replica.

---

## Step5: Configure Deployment Parameters

Deployed with the `dpn-gha-keycloak-cd.yaml` GitHub Actions workflow (display name **DPN CD - Keycloak**) in `dpn-authentication-service`:

```text
root/
└── .github/
    ├── workflows/
    │   ├── dpn-gha-keycloak-cd.yaml
    │   ├── dpn-gha-keycloak-rollback.yaml    <- DPN Rollback - Keycloak
    │   └── dpn-gha-keycloak-uninstall.yaml   <- DPN Uninstall - Keycloak
    ├── actions/
    │   └── cloud-login/
    │       └── action.yml
    └── config/
        └── azure/
            └── <environment>-<cluster>.json   <- ARM_SUBSCRIPTION_ID, RESOURCE_GROUP, AKS_CLUSTER, KEY_VAULT_NAME, NAMESPACE, ...
```

The workflow loads `.github/config/azure/<environment>-<cluster>.json` into the job environment, logs in through the `.github/actions/cloud-login` composite action (Azure OIDC using the `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` secrets, then AKS credentials), runs the Key Vault secret preflight, then `helm lint` + dry run, then `helm upgrade --install` (rolling out `dpn-keycloak-postgres` as a Deployment and `dpn-keycloak` itself as a StatefulSet — the rollout-status check uses the matching resource kind for each), then **automatically configures the realm** (see below), and records the deployed image digest as a workflow artifact. There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.

`workflow_dispatch` inputs:

| Input | Default | Notes |
|---|---|---|
| `environment` | `test` | `dev` / `test` |
| `cluster` | `dpn01` | `dpn01` / `dpn02` |
| `cloud` | `aws` | `azure` / `aws` / `gcp` — select `azure` |
| `keycloakImageRepository` | *(blank)* | Optional — path after `ghcr.io/energy-dsi/` (e.g. `1.0.1/keycloak`); blank uses the values file's `image.repository` |
| `keycloakImageTag` | *(blank)* | Optional — blank uses the configured `image.tag` |
| `postgresImageRepository` / `postgresImageTag` | *(blank)* | Same, for the bundled PostgreSQL image (`postgres.image.repository` / `postgres.image.tag`) |

The job runs under the GitHub Environment `<environment>-<cluster>`, uses Helm release name `dpn-keycloak` and deploys into the `NAMESPACE` from the config JSON.

**Realm configuration is automatic, not manual.** 

After the Helm deploy, the workflow's "Configure Realm, Client, Roles and Audit Logging" step port-forwards to the internal Service and runs `charts/keycloak/scripts/configure-keycloak.sh`, which creates/updates the `dpn-realm` realm, the `DPN-Client` machine client, the shared `dpn-service-client` UI client (with every observability UI's redirect URI/web origin), realm roles (`dpnreader`, `dpnadmin`, and now **`dpnoperator`**), matching groups, and session/audit settings — idempotently, on every deploy. When `cloud: azure`, `KC_ADMIN_PASSWORD` and `KC_SERVICE_CLIENT_SECRET` are read with `az keyvault secret show --vault-name <KEY_VAULT_NAME> --name KEYCLOAK-ADMIN-PASSWORD` and `--name KC-SERVICE-CLIENT-SECRET`.

**UI redirect hosts use the script's internal-hostname defaults.** 

The workflow does not look up any UI's LoadBalancer hostname/IP — it leaves every `KC_UI_HOST_*` variable at `configure-keycloak.sh`'s own defaults, which point at each UI's in-cluster Service DNS name (for example `KC_UI_HOST_PORTAL` defaults to `dpn-observability.ns-dpn-health-01.svc.cluster.local:8443`). Browsers must therefore be able to resolve `*.svc.cluster.local`, or you must override the relevant `KC_UI_HOST_*` variables on the `configure-keycloak.sh` step. The defaults also cover the Federator Gateway's Kafka UI (`KC_UI_HOST_KAFKA_UI_2`), its Job Runner dashboards (`KC_UI_HOST_FEDERATOR_CLIENT_1`/`KC_UI_HOST_FEDERATOR_CLIENT_2`, which authenticate directly against `dpn-service-client` with no `oauth2-proxy` sidecar) and the Self-Service UI (`KC_UI_HOST_DPN_PIPELINES_SELF_SERVICE`).
>
> **Branding.** The realm now sets a custom login theme (`KC_LOGIN_THEME`, default `dpn-portal`, packaged from `charts/keycloak/themes/dpn-portal` by `templates/theme-configmap.yaml`) and header markup (`KC_DISPLAY_NAME_HTML`). Override either as an environment variable on the `configure-keycloak.sh` step if you need different branding per environment.
>

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 | 
