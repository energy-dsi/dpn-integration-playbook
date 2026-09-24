# DPN Authentication Service (Keycloak) Configuration

This section describes how to configure and deploy the **DPN Authentication Service** — the platform's OAuth2/OIDC identity provider, **Keycloak** — into a single target environment and DPN cluster on Amazon Elastic Kubernetes Service (EKS).

**Deploy this immediately after Vault service deployed.** Deploy the Authentication Service, and create the realm/clients it expects, before enabling Keycloak-based auth on those components.

> **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`, e.g. `dpn01`). Substitute your own values throughout.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
  - [Option A — Azure Key Vault (`secretsManager.enabled: false`)](#option-a--azure-key-vault-secretsmanagerenabled-false)
  - [Option B — AWS Secrets Manager (`secretsManager.enabled: true`)](#option-b--aws-secrets-manager-secretsmanagerenabled-true)
- [Step3: Configure TLS](#step3-configure-tls)
- [Step4: Environment Configuration](#step4-environment-configuration)
  - [Step4a: Horizontal Pod Autoscaling (optional)](#step4a-horizontal-pod-autoscaling-optional)
- [Step5: Configure Deployment Parameters](#step5-configure-deployment-parameters)
- [Review Notes](#review-notes)

---

## Overview

Keycloak is deployed into `ns-dpn-01` over **standard one-way HTTPS** (`KC_HTTPS_CLIENT_AUTH=none`, `KC_HTTP_ENABLED=false`), reachable in-cluster and through an internal AWS Network Load Balancer (NLB) only. It runs as a **StatefulSet** (each replica gets its own PersistentVolumeClaim, see [Step4a](#step4a-horizontal-pod-autoscaling-optional)) and is bundled with its own PostgreSQL instance on a persistent volume.

| | |
|---|---|
| In-cluster URL | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443` |
| External access | Internal NLB (`dpn-keycloak-service-lb`), VPC only |
| Database | Bundled PostgreSQL (`dpn-keycloak-postgres`) — can be pointed at a managed database instead (see [Step4](#step4-environment-configuration)) |
| Secrets | **Native AWS Secrets Manager** see [Step2](#step2-configure-secrets) |
| Cloud provider | `cloudProvider: aws` must be set explicitly in the environment values file. See [Step4](#step4-environment-configuration) |

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **EKS cluster** with an IRSA-annotated ServiceAccount for AWS Secrets Manager | Needed for the Secrets Store CSI driver to pull the secrets in [Step2](#step2-configure-secrets) — pick one backend per `cloudProvider`/`secretsManager.enabled` |
| 2 | **`dpn-tls` Kubernetes secret present in the namespace** | An `Opaque` secret holding `keystore.jks`/`truststore.jks` and must be created before Keycloak is deployed. See [Step3: Configure TLS](#step3-configure-tls) |
| 3 | **Five secrets populated in the chosen backend** | See [Step2: Configure Secrets](#step2-configure-secrets) |
| 4 | **Container image tag available** | Keycloak pulled via GHCR; pinned in the environment values file — the CD workflow does not take an `imageTag` input for this component |
| 5 | **Config JSON and values file populated for the `<environment>-<cluster>` combination, with `cloudProvider: aws` set** | See [Step4: Environment Configuration](#step4-environment-configuration) |

> **One-time setup:** create the target namespace (`kubectl create namespace <namespace>`) and complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) before running the CD workflow — it does not create the namespace for you.

---

## Step2: Configure Secrets

The deploy pipeline reads the required secret names out of the rendered `SecretProviderClass` and fails fast if any is missing, rather than letting the pod fail with an opaque CSI mount error (the `KC-SERVICE-CLIENT-SECRET`/`KC_SERVICE_CLIENT_SECRET` value is checked the same way even though it isn't CSI-mounted — it's fetched separately and handed to `configure-keycloak.sh`, see [Step5](#step5-configure-deployment-parameters)). Populate **five** secrets before the first deploy, in whichever backend `secretsManager.enabled` selects:

### Option A — Azure Key Vault (`secretsManager.enabled: false`)

The default backend — still the org's central secrets store, usable cross-cloud.

| Key Vault secret | Becomes | Used by |
|-------------------|---------|---------|
| `KC-DB-PASSWORD` | `KC_DB_PASSWORD` | Keycloak, and PostgreSQL via `POSTGRES_PASSWORD_FILE` |
| `KEYCLOAK-ADMIN-PASSWORD` | `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin account |
| `KEYSTORE-PASSWORD` | `KC_HTTPS_KEY_STORE_PASSWORD` | Opens `keystore.jks` — **universal DPN platform keystore password**, the same secret name other components in this namespace also read |
| `TRUSTSTORE-PASSWORD` | `KC_HTTPS_TRUST_STORE_PASSWORD` | Opens `truststore.jks` — universal DPN platform truststore password |
| `KC-SERVICE-CLIENT-SECRET` | `KC_SERVICE_CLIENT_SECRET` | `dpn-service-client`'s client secret. Asserted onto that client by `configure-keycloak.sh` on every deploy, and separately republished into the `dpn-keycloak-secrets` Kubernetes secret so Kafka/federator-client/federator-server/Airflow in this namespace can reference it directly instead of each pulling their own copy from the vault |

> **Renamed from earlier releases.** The keystore/truststore secrets were previously named `KC-HTTPS-KEY-STORE-PASSWORD`/`KC-HTTPS-TRUST-STORE-PASSWORD`. They are now `KEYSTORE-PASSWORD`/`TRUSTSTORE-PASSWORD` — a single pair of platform-wide secrets shared with other DPN components in the namespace (e.g. the Certificate Manager's OTEL truststore, see [Configure DPN Certificate Manager](04-configure-dpn-certificate-manager.md)) — rename or recreate them in Key Vault before deploying this chart version.

### Option B — AWS Secrets Manager (`secretsManager.enabled: true`)

Native AWS backend — no cross-cloud Key Vault dependency. Requires `serviceAccount.create: true` with a valid IRSA role ARN annotated on the ServiceAccount (`eks.amazonaws.com/role-arn`), and `automountServiceAccountToken: true`. Secrets must exist under `secretsManager.secretPrefix/<KEY_NAME>` in Secrets Manager:

| Secrets Manager entry (under `secretPrefix/`) | Becomes | Used by |
|---|---|---|
| `KC_DB_PASSWORD` | `KC_DB_PASSWORD` | Keycloak, and PostgreSQL via `POSTGRES_PASSWORD_FILE` |
| `KEYCLOAK_ADMIN_PASSWORD` | `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin account |
| `KC_HTTPS_KEY_STORE_PASSWORD` | `KC_HTTPS_KEY_STORE_PASSWORD` | Opens `keystore.jks` |
| `KC_HTTPS_TRUST_STORE_PASSWORD` | `KC_HTTPS_TRUST_STORE_PASSWORD` | Opens `truststore.jks` |
| `KC_SERVICE_CLIENT_SECRET` | `KC_SERVICE_CLIENT_SECRET` | Same purpose as the Key Vault entry above |

Example `secretPrefix`: `dpn/<environment>-<cluster>/keycloak`.

> **PostgreSQL first-install ordering.** The superuser password is read from the CSI-mounted file (`POSTGRES_PASSWORD_FILE`) rather than the synced Kubernetes secret directly, because the CSI driver only creates that secret once a pod has actually mounted the `SecretProviderClass` — reading the file avoids a chicken-and-egg failure on the very first deploy. This applies to either secrets backend.

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
     -storepass "$(az keyvault secret show --vault-name <KEY_VAULT_NAME> \
       --name KEYSTORE-PASSWORD --query value -o tsv)"

   # AWS Secrets Manager backend:
   keytool -list -keystore keystore.jks \
     -storepass "$(aws secretsmanager get-secret-value \
       --secret-id <secretPrefix>/KC_HTTPS_KEY_STORE_PASSWORD \
       --query SecretString --output text)"
   ```

3. Set `config.KC_HTTPS_KEY_ALIAS` to that alias in the environment values file — Keycloak aborts at startup if the alias does not exist.
4. Set `config.KC_HOSTNAME` to a DNS name the certificate's SANs actually cover. It defaults to the in-cluster FQDN (`https://dpn-keycloak.<namespace>.svc.cluster.local:8443`); a shared platform certificate often covers a public DNS name instead — the deploy workflow prints the certificate's SANs so you can check.

   > **Pin `KC_HOSTNAME` rather than leaving it empty when a browser-facing consumer is involved.** With `KC_HOSTNAME` left dynamic, Keycloak derives its OIDC issuer/redirect URLs from whichever `Host` header the request arrived on — including internal server-to-server calls, which arrive on the in-cluster `svc.cluster.local` name. That unresolvable hostname can then leak into a browser-facing authorize redirect (seen as `DNS_PROBE_FINISHED_NXDOMAIN` for consumers such as Airflow's Keycloak SSO login). Pin `KC_HOSTNAME` to the externally-reachable NLB hostname once it's known, and keep `KC_HOSTNAME_STRICT: "false"` so in-cluster callers still work.

---

## Step4: Environment Configuration

Set the parameters below in your environment/cluster's values file.

```text
dpn-authentication-service/
  └── charts/
        └── keycloak/
              ├── values.yaml                              <- Reference file; do not edit directly
              └── values/aws/<environment>-<cluster>.yaml <- Your environment + cluster overrides
```

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cloudProvider` | **Set to `aws`.** Selects the AWS Secrets Manager/IRSA path and the `aws-load-balancer-internal`/`nlb` Service annotations below; the chart's own default is `azure` | `aws` |
| `config.KC_HOSTNAME` | Hostname Keycloak advertises — must match the certificate SANs | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443` |
| `config.KC_HOSTNAME_STRICT` | Whether Keycloak rejects requests whose `Host` header doesn't match `KC_HOSTNAME`. Leave `"false"` while `KC_HOSTNAME` itself is left empty | `"false"` |
| `config.KC_HTTPS_KEY_ALIAS` | Alias of the server key inside `keystore.jks` | *(from Step3)* |
| `service.loadBalancer.loadBalancerIP` | Static IP for Keycloak's LoadBalancer Service. Leave empty on first deploy — AWS auto-assigns one — then pin the assigned IP here so it survives a Service recreation. Ignored when `cloudProvider: aws` (the NLB annotation path does not support pinning a frontend IP the way Azure's does) | `""`, then the assigned IP after first deploy |
| `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | AKV name, identity client ID, tenant ID — only used when `secretsManager.enabled: false` | `kv-dpn-<env>-<region>-<seq>` / `<client-id>` / `<tenant-id>` |
| `secretsManager.enabled` / `secretsManager.secretPrefix` | Use AWS Secrets Manager instead of AKV (see [Step2, Option B](#option-b--aws-secrets-manager-secretsmanagerenabled-true)) | `true` / `dpn/<env>-<cluster>/keycloak` |
| `serviceAccount.create` / `serviceAccount.automountServiceAccountToken` / `serviceAccount.annotations` | IRSA ServiceAccount — required when `secretsManager.enabled: true` | `true` / `true` / `eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/dpn-keycloak-secrets-role` |
| `image.repository` | GHCR path for the Keycloak image | `ghcr.io/energy-dsi/keycloak` |

**Using a managed database instead of the bundled PostgreSQL:**

```yaml
postgres:
  enabled: false
config:
  KC_DB_URL: jdbc:postgresql://<rds-endpoint>.rds.amazonaws.com:5432/keycloak_db
  KC_DB_USERNAME: keycloak_db_user
```

**Environments provided:** `dev`/`devtest`/`test` (both `dpn01` and `dpn02`).

---

### Step4a: Horizontal Pod Autoscaling (optional)

Keycloak now runs as a **StatefulSet** rather than a Deployment, so scaling past a single replica is safe: `volumeClaimTemplates` gives every pod its own PersistentVolumeClaim, avoiding the `ReadWriteOnce` Multi-Attach failure a shared claim would hit. All of Keycloak's actual state (realms, clients, users, sessions) lives in the one shared Postgres every replica already points at — each pod's own PVC only holds its local JTA transaction-log recovery store.

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `hpa.enabled` | Turn on the `HorizontalPodAutoscaler` | `false` |
| `hpa.minReplicas` / `hpa.maxReplicas` | Scaling bounds | `1` / `3` |
| `hpa.cpuUtilization` / `hpa.memoryUtilization` | Target average utilization (%) that triggers scaling | `80` / `80` |
| `hpa.scaleStep` | Pods added/removed per scaling step | `1` |

> **`persistence.existingClaim` only works at `replicaCount: 1`.** If set, every replica would otherwise mount the same named claim — the exact Multi-Attach problem `volumeClaimTemplates` exists to avoid. Leave it unset to let the StatefulSet provision a claim per replica.

---

## Step5: Configure Deployment Parameters

Deployed with the `dpn-keycloak-cd.yml` GitHub Actions workflow in `dpn-containerised-deployment-service`:

```text
dpn-containerised-deployment-service/
└── .github/
    └── workflows/
        └── dpn-keycloak-cd.yml
```

The workflow runs `helm lint` + dry run, then `helm upgrade --install` (rolling out `dpn-keycloak-postgres` as a Deployment and `dpn-keycloak` itself as a StatefulSet — the rollout-status check uses the matching resource kind for each), then **automatically configures the realm** (see below), and records the deployed image digest as a workflow artifact. There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.

`workflow_dispatch` inputs: `environment`, `cluster`, `cloud` — there is no `imageTag` input for this component; pin the image tag in the environment values file instead (see [Step4](#step4-environment-configuration)).

> **Realm configuration is automatic, not manual.** After the Helm deploy, the workflow's "Configure Realm, Client, Roles and Audit Logging" step port-forwards to the internal Service and runs `charts/keycloak/scripts/configure-keycloak.sh`, which creates/updates the `dpn-realm` realm, the `DPN-Client` machine client, the shared `dpn-service-client` UI client (with every observability UI's redirect URI/web origin), realm roles (`dpnreader`, `dpnadmin`, and now **`dpnoperator`** — trigger/enable/disable DAGs and manage task state without edit/delete rights), matching groups, and session/audit settings — idempotently, on every deploy. `KC_ADMIN_PASSWORD` and `KC_SERVICE_CLIENT_SECRET` are read from the secrets backend selected in [Step2](#step2-configure-secrets) (`aws secretsmanager get-secret-value --secret-id <secretPrefix>/keycloak/...` when `cloud: aws`).
>
> **UI redirect hosts are resolved dynamically on AWS.** Rather than relying solely on `configure-keycloak.sh`'s own placeholder defaults (`dpn-observability.ns-dpn-health-01.svc.cluster.local:<port>` — unreachable from a browser), the AWS path looks up each UI's real LoadBalancer hostname (`kubectl get svc ... -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`) for Airflow, Jaeger, OpenSearch Dashboards, Perses, Portal and the Kafka UI, and passes it to the script via `KC_UI_HOST_*` environment variables. A UI not yet deployed is simply left at the script's own default rather than failing the step. Two additional UI hosts are now registered unconditionally: `KC_UI_HOST_FEDERATOR_CLIENT_1`/`KC_UI_HOST_FEDERATOR_CLIENT_2` — the Federator Gateway's Job Runner dashboards, which authenticate directly against `dpn-service-client` (no `oauth2-proxy` sidecar).
>
> **Branding.** The realm now sets a custom login theme (`KC_LOGIN_THEME`, default `dpn-portal`, packaged from `charts/keycloak/themes/dpn-portal` by `templates/theme-configmap.yaml`) and header markup (`KC_DISPLAY_NAME_HTML`). Override either as an environment variable on the `configure-keycloak.sh` step if you need different branding per environment.
>
> **No `--wait`/`--timeout` on `helm upgrade` for this path.** Long-lived watches against the EKS API from the self-hosted runner were unreliable and timed out even when the rollout had actually completed — the Helm Deploy step now fires the upgrade without waiting, then polls `kubectl rollout status` with a short per-attempt timeout and a few retries instead.

There is no dedicated uninstall workflow for this component yet — to remove it, run `helm uninstall dpn-keycloak -n <namespace>` directly (this retains the PostgreSQL PVC by default, so realm data survives a reinstall; delete the PVC separately if you want a clean wipe).

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| — | — | Draft — pending DSI Assurance review | V0.1.0 |
