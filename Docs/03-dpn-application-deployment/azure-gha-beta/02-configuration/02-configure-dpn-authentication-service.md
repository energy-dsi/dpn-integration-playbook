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
| Secrets | Azure Key Vault see [Step2](#step2-configure-secrets) |
| Cloud provider | `cloudProvider: azure` must be set explicitly in the environment values file. See [Step4](#step4-environment-configuration) |

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **AKS cluster** with a Workload Identity-annotated ServiceAccount for Azure Key Vault | Needed for the Secrets Store CSI driver to pull the secrets in [Step2](#step2-configure-secrets) — pick one backend per `cloudProvider`/`secretsManager.enabled` |
| 2 | **`dpn-tls` Kubernetes secret present in the namespace** | An `Opaque` secret holding `keystore.jks`/`truststore.jks` and must be created before Keycloak is deployed. See [Step3: Configure TLS](#step3-configure-tls) |
| 3 | **Five secrets populated in the chosen backend** | See [Step2: Configure Secrets](#step2-configure-secrets) |
| 4 | **Container image tag available** | Keycloak pulled via GHCR; pinned in the environment values file — the CD workflow does not take an `imageTag` input for this component |
| 5 | **Config JSON and values file populated for the `<environment>-<cluster>` combination, with `cloudProvider: azure` set** | See [Step4: Environment Configuration](#step4-environment-configuration) |

> **One-time setup:** create the target namespace ns-dpn-01 and ns-dpn-health-01 (`kubectl create namespace <namespace>`) and complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) before running the CD workflow — it does not create the namespace for you.

---

## Step2: Configure Secrets


The deploy pipeline reads the required secret names out of the rendered `SecretProviderClass` and fails fast if any is missing, rather than letting the pod fail with an opaque CSI mount error. All five secrets below — including `KC_SERVICE_CLIENT_SECRET` — are CSI-mounted into the pod the same way, via the <release>-keycloak-secrets Kubernetes Secret. `KC_SERVICE_CLIENT_SECRET` is additionally re-fetched a second time, directly from Azure Key Vault, by the CD workflow itself — since `configure-keycloak.sh` runs on the GitHub Actions runner via port-forward, not inside the pod, it needs its own copy rather than reading it out of the pod's env (see [Step5] (#step5-configure-deployment-parameters)).

**Azure Key Vault**

Azure Key Vault is a cloud native Azure component that requires a service account with a valid Workload Identity federated credential annotated on the ServiceAccount (`azure.workload.identity/client-id`), and `automountServiceAccountToken: true`. Secrets must exist as `<KEY_VAULT_NAME>/keycloak-<KEY_NAME>` in Key Vault:

| Key Vault entry (under `keycloak-`) | Becomes | Used by |
|---|---|---|
| `KC_DB_PASSWORD` | `KC_DB_PASSWORD` | Keycloak, and PostgreSQL via `POSTGRES_PASSWORD_FILE` |
| `KEYCLOAK_ADMIN_PASSWORD` | `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin account |
| `KC_HTTPS_KEY_STORE_PASSWORD` | `KC_HTTPS_KEY_STORE_PASSWORD` | Opens `keystore.jks` |
| `KC_HTTPS_TRUST_STORE_PASSWORD` | `KC_HTTPS_TRUST_STORE_PASSWORD` | Opens `truststore.jks` |
| `KC_SERVICE_CLIENT_SECRET` | `KC_SERVICE_CLIENT_SECRET` | Keycloak pod (via `envFrom`) and `configure-keycloak.sh` (fetched separately by the CD workflow) 

Example Key Vault naming: `<KEY_VAULT_NAME>/keycloak-<KEY_NAME>`.

> **Note — two different secret sources on this page.** Everything in the table above lives in **Azure Key Vault** and is synced into the cluster automatically via the CSI Secrets Store driver — nothing here needs a manual `kubectl create secret`. `dpn-tls` (Step1 prerequisite #2, configured in [Step3](#step3-configure-tls)) is a different, unrelated thing: a plain **Kubernetes** `Opaque` Secret created ahead of time by a separate TLS bootstrap process, not part of this Azure Key Vault flow at all.


---

## Step3: Configure TLS

Keycloak reads its certificate from the pre-existing `dpn-tls` secret (mounted read-only at `/cert`) rather than from Vault or the Certificate Manager — this is a platform/ingress-style certificate, not the DPN's DSM-signed federation certificate.

1. Create `dpn-tls` in the target namespace as an `Opaque` secret with two keys, `keystore.jks` and `truststore.jks`.
2. Find the alias of the server key inside `keystore.jks`:

   ```sh
   kubectl get secret dpn-tls -n <namespace> \
     -o jsonpath='{.data.keystore\.jks}' | base64 -d > keystore.jks

   # Azure Key Vault backend:
   keytool -list -keystore keystore.jks \
     -storepass "$(az keyvault secret show \
       --vault-name <KEY_VAULT_NAME> --name keycloak-KC-HTTPS-KEY-STORE-PASSWORD \
       --query value --output tsv)"
   ```

3. Set `config.KC_HTTPS_KEY_ALIAS` to that alias in the environment values file — Keycloak aborts at startup if the alias does not exist.

4. Set `config.KC_HOSTNAME` to a DNS name the certificate's SANs actually cover. It defaults to the in-cluster FQDN (`https://dpn-keycloak.<namespace>.svc.cluster.local:8443`); a shared platform certificate often covers a public DNS name instead — the deploy workflow prints the certificate's SANs so you can check.

   > **Note** Update `KC_HOSTNAME` rather than leaving it empty when a browser-facing consumer is involved.** With `KC_HOSTNAME` left dynamic, Keycloak derives its OIDC issuer/redirect URLs from whichever `Host` header the request arrived on — including internal server-to-server calls, which arrive on the in-cluster `svc.cluster.local` name. That unresolvable hostname can then leak into a browser-facing authorize redirect (seen as `DNS_PROBE_FINISHED_NXDOMAIN` for consumers such as Airflow's Keycloak SSO login). Pin `KC_HOSTNAME` to the externally-reachable Load Balancer hostname i.e.`https://dpn-keycloak-service-lb.<namespace>.svc.cluster.local:8443` and keep `KC_HOSTNAME_STRICT: "false"` so in-cluster callers still work.

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
| `cloudProvider` | **Set to `azure`.** Selects the Azure Key Vault/Workload Identity path and the internal Azure Load Balancer Service annotations below; this is also the chart's own default | `azure` |
| `config.KC_HOSTNAME` | Hostname Keycloak advertises — must match the certificate SANs | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443` |
| `config.KC_HOSTNAME_STRICT` | Whether Keycloak rejects requests whose `Host` header doesn't match `KC_HOSTNAME`. Leave `"false"` while `KC_HOSTNAME` itself is left empty | `"false"` |
| `config.KC_HTTPS_KEY_ALIAS` | Alias of the server key inside `keystore.jks` | *(from Step3)* |
| `service.loadBalancer.loadBalancerIP` | Static IP for Keycloak's LoadBalancer Service. Leave empty on first deploy — Azure auto-assigns one — then pin the assigned IP here so it survives a Service recreation | `""`, then the assigned IP after first deploy |
| `secretsManager.enabled` / `secretsManager.secretPrefix` | Use Azure Key Vault | `true` / `keycloak` (prefix under `<KEY_VAULT_NAME>`) |
| `serviceAccount.create` / `serviceAccount.automountServiceAccountToken` / `serviceAccount.annotations` | Workload Identity ServiceAccount — required when `secretsManager.enabled: true` | `true` / `true` / `azure.workload.identity/client-id: <AZURE_CLIENT_ID>` |
| `image.repository` | GHCR path for the Keycloak image | `ghcr.io/energy-dsi/keycloak` |

---

### Step4a: Horizontal Pod Autoscaling

Keycloak now runs as a **StatefulSet** rather than a Deployment, so scaling past a single replica is safe: `volumeClaimTemplates` gives every pod its own PersistentVolumeClaim, avoiding the `ReadWriteOnce` Multi-Attach failure a shared claim would hit. All of Keycloak's actual state (realms, clients, users, sessions) lives in the one shared Postgres every replica already points at — each pod's own PVC only holds its local JTA transaction-log recovery store.

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `hpa.enabled` | Turn on the `HorizontalPodAutoscaler` | `true` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.cpuUtilization` / `hpa.memoryUtilization` | Target average utilization (%) that triggers scaling | `80` / `80` |
| `hpa.scaleStep` | Pods added/removed per scaling step | `1` |

> **`persistence.existingClaim` only works at `replicaCount: 1`.** If set, every replica would otherwise mount the same named claim. Leave it unset to let the StatefulSet provision a claim per replica.

---

## Step5: Configure Deployment Parameters

Deployed with the `dpn-keycloak-cd.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`:

```text
root/
└── .pipelines/
    └── github-actions-pipelines/
      └── workflows/
          └── dpn-gha-keycloak-cd.yml
```

The workflow runs `helm lint` + dry run, then `helm upgrade --install` (rolling out `dpn-keycloak-postgres` as a Deployment and `dpn-keycloak` itself as a StatefulSet — the rollout-status check uses the matching resource kind for each), then **automatically configures the realm** (see below), and records the deployed image digest as a workflow artifact. There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.

`workflow_dispatch` inputs: `environment`, `cluster`, `cloud` — there is no `imageTag` input for this component; pin the image tag in the environment values file instead (see [Step4](#step4-environment-configuration)).

**Realm configuration is automatic, not manual.** 

After the Helm deploy, the workflow's "Configure Realm, Client, Roles and Audit Logging" step port-forwards to the internal Service and runs `charts/keycloak/scripts/configure-keycloak.sh`, which creates/updates the `dpn-realm` realm, the `DPN-Client` machine client, the shared `dpn-service-client` UI client (with every observability UI's redirect URI/web origin), realm roles (`dpnreader`, `dpnadmin`, and now **`dpnoperator`** — trigger/enable/disable DAGs and manage task state without edit/delete rights), matching groups, and session/audit settings — idempotently, on every deploy. `KC_ADMIN_PASSWORD` and `KC_SERVICE_CLIENT_SECRET` are read from the secrets backend selected in [Step2](#step2-configure-secrets) (`az keyvault secret show --vault-name <KEY_VAULT_NAME> --name keycloak-...` when `cloud: azure`).

**UI redirect hosts are resolved dynamically on Azure.** 

Rather than relying solely on `configure-keycloak.sh`'s own placeholder defaults (`dpn-observability.ns-dpn-health-01.svc.cluster.local:<port>` — unreachable from a browser), the Azure path looks up each UI's real LoadBalancer hostname/IP (`kubectl get svc ... -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`) for Airflow, Jaeger, OpenSearch Dashboards, Perses, Portal and the Kafka UI, and passes it to the script via `KC_UI_HOST_*` environment variables. A UI not yet deployed is simply left at the script's own default rather than failing the step. Two additional UI hosts are now registered unconditionally: `KC_UI_HOST_FEDERATOR_CLIENT_1`/`KC_UI_HOST_FEDERATOR_CLIENT_2` — the Federator Gateway's Job Runner dashboards, which authenticate directly against `dpn-service-client` (no `oauth2-proxy` sidecar).
>
> **Branding.** The realm now sets a custom login theme (`KC_LOGIN_THEME`, default `dpn-portal`, packaged from `charts/keycloak/themes/dpn-portal` by `templates/theme-configmap.yaml`) and header markup (`KC_DISPLAY_NAME_HTML`). Override either as an environment variable on the `configure-keycloak.sh` step if you need different branding per environment.
>

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Oct-2026 | DSI Assurance   | Final  | V1.0.0 | 
