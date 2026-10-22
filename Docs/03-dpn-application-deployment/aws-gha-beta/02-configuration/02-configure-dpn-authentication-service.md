# DPN Authentication Service (Keycloak) Configuration

This section describes how to configure and deploy the **DPN Authentication Service** — the platform's OAuth2/OIDC identity provider, **Keycloak** — into a single target environment and DPN cluster on Amazon Elastic Kubernetes Service (EKS).

> **Deploy this before components that authenticate against it.** The Federator Gateway's Kafka brokers (`kafka.authMode: sasl_ssl`) and the DPN observability UIs authenticate against this Keycloak realm. Deploy the Authentication Service, and create the realm/clients it expects, before enabling Keycloak-based auth on those components.

> **Single environment, single cluster:** These instructions target **one environment** (`<env>`) and **one DPN cluster** (`<cluster>`, e.g. `dpn01`). Substitute your own values throughout.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Meet the Prerequisites](#step1-meet-the-prerequisites)
- [Step2: Configure Secrets](#step2-configure-secrets)
  - [Option A — AWS Secrets Manager (`secretsManager.enabled: true`)](#option-a--aws-secrets-manager-secretsmanagerenabled-true)
  - [Create the IAM role `dpn-keycloak-secrets-role` (IRSA)](#create-the-iam-role-dpn-keycloak-secrets-role-irsa)
- [Step3: Configure TLS](#step3-configure-tls)
- [Step4: Environment Configuration](#step4-environment-configuration)
  - [Step4a: Horizontal Pod Autoscaling (optional)](#step4a-horizontal-pod-autoscaling-optional)
- [Step5: Configure Deployment Parameters](#step5-configure-deployment-parameters)
- [Review Notes](#review-notes)

---

## Overview

Keycloak is deployed into `ns-dpn-01` over **standard one-way HTTPS** (`KC_HTTPS_CLIENT_AUTH=none`, `KC_HTTP_ENABLED=false` — there is no plaintext listener), reachable in-cluster and through a `LoadBalancer` Service intended to be an internal AWS Network Load Balancer (NLB) — but see the Service caution below: the chart does not yet render the AWS internal-LB annotation. It runs as a **StatefulSet** (each replica gets its own PersistentVolumeClaim, see [Step4a](#step4a-horizontal-pod-autoscaling-optional)) and is bundled with its own PostgreSQL instance on a persistent volume.

| | |
|---|---|
| In-cluster URL | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443` |
| External access | `dpn-keycloak-service-lb` (`LoadBalancer` Service). **Not guaranteed internal on EKS** — the chart only renders the Azure internal-LB annotation (see the caution below) |
| Database | Bundled PostgreSQL (`dpn-keycloak-postgres`) — can be pointed at a managed database instead (see [Step4](#step4-environment-configuration)) |
| Secrets | **native AWS Secrets Manager** via the Secrets Store CSI driver (DB/admin passwords and the service-client secret), plus the shared `tls-auth-secret` Kubernetes secret (keystore/truststore passwords). Selected by `cloudProvider` in the values file; see [Step2](#step2-configure-secrets) |
| Cloud provider | `cloudProvider: aws` **must be set explicitly** in the environment values file (every provided `charts/keycloak/values/aws/*.yaml` file sets it) |

> **The secrets path is cloud-aware; the Service is not.** In the current `dpn-authentication-service` source, `templates/secretproviderclass.yaml` branches on `cloudProvider`: `aws` renders a `provider: aws` `SecretProviderClass` reading the Secrets Manager entries under `secretsManager.secretPrefix`; anything else (the chart default is `azure`) renders the Key Vault one. `templates/keycloak-service.yaml` does **not** read `cloudProvider`: while `service.loadBalancer.enabled` is `true` (the chart default, and set in the provided AWS values files) it always renders the Azure-only `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` annotation on `dpn-keycloak-service-lb`. AWS ignores that annotation, and no value lets you add AWS ones, so the load balancer may not be internal. Run `helm template` against your values file and check the rendered Service before the first EKS deploy. If it carries no AWS internal-LB annotation, either set `service.loadBalancer.enabled: false` (in-cluster consumers use the `ClusterIP` Service `dpn-keycloak`) or annotate the Service yourself — see [Internal Load Balancer Is Not Actually Internal](../03-installation/02-dpn-authentication-service-installation-process.md#internal-load-balancer-is-not-actually-internal).

Consuming components resolve tokens against a realm on this Keycloak instance, for example the Federator Gateway's Kafka brokers when `kafka.authMode: sasl_ssl` (see [Configure DPN Federator Gateway, Step3c](05-configure-dpn-federator-gateway.md#step3c-configure-kafka-security)).

---

## Step1: Meet the Prerequisites

| # | Prerequisite | Notes |
|---|--------------|-------|
| 1 | **EKS cluster** and an IRSA-annotated ServiceAccount for AWS Secrets Manager | Needed for the Secrets Store CSI driver to pull the secrets in [Step2](#step2-configure-secrets). The IAM role (`dpn-keycloak-secrets-role` in the provided values files) is **not** created by `dpn-gha-keycloak-cd.yaml` — it must already exist and be able to read the entries under `secretsManager.secretPrefix`. See [Create the IAM role `dpn-keycloak-secrets-role` (IRSA)](#create-the-iam-role-dpn-keycloak-secrets-role-irsa) for the permission and trust policies |
| 2 | **`dpn-tls` and `tls-auth-secret` Kubernetes secrets present in the namespace** | `dpn-tls` is an `Opaque` secret holding `ca.crt`/`keystore.jks`/`truststore.jks` (Java keystores, **not** a `kubernetes.io/tls` secret); `tls-auth-secret` holds the matching `KEYSTORE_PASSWORD`/`TRUSTSTORE_PASSWORD`. Both are created by the **DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1** workflow (`dpn-gha-tls-cd.yaml`, in `dpn-federator-certificate-manager`) before Keycloak is deployed. See [Step3: Configure TLS](#step3-configure-tls) |
| 3 | **Three secrets populated in AWS Secrets Manager** | See [Step2: Configure Secrets](#step2-configure-secrets) |
| 4 | **Container image available** | Stock upstream Keycloak/PostgreSQL pulled via GHCR (`ghcr.io/energy-dsi/keycloak`, `ghcr.io/energy-dsi/postgres`); repository pinned in the environment values file, tag defaulting to the chart's `values.yaml`. The CD workflow's optional `keycloakImageRepository`/`keycloakImageTag`/`postgresImageRepository`/`postgresImageTag` inputs override these per run |
| 5 | **Config JSON and values file populated for the `<environment>-<cluster>` combination, with `cloudProvider: aws` set** | See [Step4: Environment Configuration](#step4-environment-configuration) |

> **One-time setup:** create the target namespace (`kubectl create namespace <namespace>`) and complete [GitHub Actions Configuration](00-common-dpn-configuration.md#step2-github-actions-configuration) before running the CD workflow — it does not create the namespace for you.

---

## Step2: Configure Secrets

On `cloud: aws` the deploy workflow does **not** run a secrets preflight (its "Key Vault Secret Preflight" step is Azure-only) — a missing Secrets Manager entry surfaces as a pod CSI mount failure on `dpn-keycloak-kv-secrets`, or as an `aws secretsmanager get-secret-value` error in the realm-configuration step (see [Step5](#step5-configure-deployment-parameters)). Populate the **three** Secrets Manager entries below before the first deploy:

### Option A — AWS Secrets Manager (`secretsManager.enabled: true`)

Native AWS backend — no cross-cloud Key Vault dependency. Requires `serviceAccount.create: true` with a valid IRSA role ARN annotated on the ServiceAccount (`eks.amazonaws.com/role-arn`), and `automountServiceAccountToken: true`. Secrets must exist under `secretsManager.secretPrefix/<KEY_NAME>` in Secrets Manager, and are synced into the `dpn-keycloak-secrets` Kubernetes secret:

| Secrets Manager entry (under `secretPrefix/`) | Becomes | Used by |
|---|---|---|
| `KC_DB_PASSWORD` | `KC_DB_PASSWORD` | Keycloak, and PostgreSQL via `POSTGRES_PASSWORD_FILE` |
| `KEYCLOAK_ADMIN_PASSWORD` | `KEYCLOAK_ADMIN_PASSWORD` | Bootstrap admin account; also read by the workflow's realm-configuration step |
| `KC_SERVICE_CLIENT_SECRET` | `KC_SERVICE_CLIENT_SECRET` | `dpn-service-client`'s client secret — asserted onto that client by `configure-keycloak.sh` on every deploy, and copied by `dpn-health-monitoring-service`'s `dpn-gha-oauth2-proxy-cd.yaml` for the observability gateways, so it must match what consuming UIs already use |

Example `secretPrefix`: `dpn/<environment>-<cluster>/keycloak`. None of these three is created by a workflow — set them manually.

> **Keystore/truststore passwords no longer come from the SecretProviderClass.** `KC_HTTPS_KEY_STORE_PASSWORD`/`KC_HTTPS_TRUST_STORE_PASSWORD` are read from the shared `tls-auth-secret` Kubernetes secret (keys `KEYSTORE_PASSWORD`/`TRUSTSTORE_PASSWORD`) created by `dpn-gha-tls-cd.yaml`. That workflow also publishes `keycloak/KC_HTTPS_KEY_STORE_PASSWORD`, `keycloak/KC_HTTPS_TRUST_STORE_PASSWORD` and `keycloak/KC_SPI_TRUSTSTORE_FILE_PASSWORD` under `dpn/<environment>-<cluster>/` in Secrets Manager (when `storePasswordsInSecretsBackend: true`), but the Keycloak chart does not mount them.

> **PostgreSQL first-install ordering.** The superuser password is read from the CSI-mounted file (`POSTGRES_PASSWORD_FILE`) rather than the synced Kubernetes secret directly, because the CSI driver only creates that secret once a pod has actually mounted the `SecretProviderClass` — reading the file avoids a chicken-and-egg failure on the very first deploy. This applies to either secrets backend.

### Create the IAM role `dpn-keycloak-secrets-role` (IRSA)

The Keycloak pod reads the Secrets Manager entries above through the Secrets Store CSI driver, using an **IAM role for service accounts (IRSA)**. This role is created manually, once per AWS account/cluster — the CD workflow does not create it. Name it `dpn-keycloak-secrets-role` (the name used in the provided values files), and annotate the ServiceAccount with its ARN:

```yaml
serviceAccount:
  create: true
  automountServiceAccountToken: true   # required for IRSA
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::<account-id>:role/dpn-keycloak-secrets-role"
```

**1. Permissions policy** — read-only access to the Keycloak secrets under this environment's prefix, and nothing else:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:DescribeSecret"
            ],
            "Resource": "arn:aws:secretsmanager:<region>:<account-id>:secret:dpn/<environment>-<cluster>/keycloak/*"
        }
    ]
}
```

| Placeholder | Replace with |
|---|---|
| `<region>` | AWS region of the cluster, e.g. `eu-west-2` |
| `<account-id>` | The 12-digit AWS account ID hosting the EKS cluster |
| `<environment>-<cluster>` | The environment/cluster this role serves, e.g. `dev-dpn01` — must match `secretsManager.secretPrefix` in the values file |

**2. Trust policy** — allows only the Keycloak ServiceAccount in this cluster to assume the role through the cluster's OIDC provider:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::<account-id>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<oidc-id>"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "oidc.eks.<region>.amazonaws.com/id/<oidc-id>:aud": "sts.amazonaws.com",
                    "oidc.eks.<region>.amazonaws.com/id/<oidc-id>:sub": "system:serviceaccount:<namespace>:<service-account-name>"
                }
            }
        }
    ]
}
```

| Placeholder | Replace with |
|---|---|
| `<oidc-id>` | The cluster's OIDC provider ID: `aws eks describe-cluster --name <cluster-name> --query "cluster.identity.oidc.issuer" --output text` (the trailing path segment) |
| `<namespace>` | The Keycloak namespace, `ns-dpn-01` |
| `<service-account-name>` | The Keycloak ServiceAccount name. With `serviceAccount.name` left empty it defaults to the Helm release name, `dpn-keycloak` |

> **Keep the scope narrow.** The permissions policy grants access only to `…/keycloak/*` under one environment's prefix. Do not widen it to `dpn/*` or `*`: other components (Kafka, certificate-manager, federator) have their own roles and prefixes. Create the role once per account — `dev-dpn01`, `dev-dpn02`, `test-dpn01` and `test-dpn02` each live in their own account with their own prefix.

---

## Step3: Configure TLS

Keycloak reads its certificate from the pre-existing `dpn-tls` secret (mounted read-only at `/cert`) rather than from Vault or the Certificate Manager — this is a platform/ingress-style certificate, not the DPN's DSM-signed federation certificate.

1. Create `dpn-tls` (and `tls-auth-secret`) in the target namespace by running **Actions → DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1 → Run workflow** (`dpn-gha-tls-cd.yaml`) with `cloud: aws`, your `environment`/`cluster`, and `targetNamespace: ns-dpn-01`. It generates one DPN root CA and a common server certificate (`.github/config/scripts/create-dpn-tls.sh`) and creates `dpn-tls` as an `Opaque` secret with `ca.crt`, `keystore.jks` and `truststore.jks`. The keystore/truststore/client-p12 passwords come from the `DPN_TLS_KEYSTORE_PASSWORD`, `DPN_TLS_TRUSTSTORE_PASSWORD` and `DPN_TLS_CLIENT_P12_PASSWORD` GitHub secrets.
2. Find the alias of the server key inside `keystore.jks` (for a keystore generated by `dpn-gha-tls-cd.yaml` it is `dpn-server`):

   ```sh
   kubectl get secret dpn-tls -n <namespace> \
     -o jsonpath='{.data.keystore\.jks}' | base64 -d > keystore.jks

   keytool -list -keystore keystore.jks \
     -storepass "$(kubectl get secret tls-auth-secret -n <namespace> \
       -o jsonpath='{.data.KEYSTORE_PASSWORD}' | base64 -d)"
   ```

3. Set `config.KC_HTTPS_KEY_ALIAS` to that alias in the environment values file — Keycloak aborts at startup if the alias does not exist.
4. Set `config.KC_HOSTNAME` to a DNS name the certificate's SANs actually cover. The certificate generated by `dpn-gha-tls-cd.yaml` carries wildcard SANs `*.ns-dpn-01.svc.cluster.local`, `*.ns-dpn-health-01.svc.cluster.local` and `*.ns-dpn-dp-01.svc.cluster.local`, so the in-cluster Service name is covered. The chart default is `https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443`; the provided AWS values files pin `dpn-keycloak.<namespace>.svc.cluster.local`.

   > **Pin `KC_HOSTNAME` rather than leaving it empty when a browser-facing consumer is involved.** With `KC_HOSTNAME` left dynamic, Keycloak derives its OIDC issuer/redirect URLs from whichever `Host` header the request arrived on — including internal server-to-server calls, which arrive on the in-cluster `svc.cluster.local` name. That hostname can then leak into a browser-facing authorize redirect (seen as `DNS_PROBE_FINISHED_NXDOMAIN` for browser-facing consumers). The provided AWS values files pin `KC_HOSTNAME` to Keycloak's stable internal Service DNS name (`dpn-keycloak.<namespace>.svc.cluster.local`) rather than the raw NLB hostname, which changes on every redeploy, and keep `KC_HOSTNAME_STRICT: "false"` so in-cluster callers still work. Browsers must therefore be able to resolve `*.svc.cluster.local` from outside the cluster (Route 53 Resolver / VPC DNS forwarding).

---

## Step4: Environment Configuration

Set the parameters below in your environment/cluster's values file.


```text
root/
  └── charts/
        └── keycloak/
          └── values/
              └── aws/           
                └── <environment>-<cluster>.yaml <- Your environment + cluster overrides
```

| Parameter | Purpose | Example (placeholder) |
|-----------|---------|-----------------------|
| `cloudProvider` | **Set to `aws`.** Set in every provided AWS values file; the chart's base `values.yaml` defaults it to `azure`, so it must be overridden. `templates/secretproviderclass.yaml` reads it, `templates/keycloak-service.yaml` does not (see the note in [Overview](#overview)) | `aws` |
| `config.KC_HOSTNAME` | Hostname Keycloak advertises — must match the certificate SANs | `dpn-keycloak.<namespace>.svc.cluster.local` |
| `config.KC_HOSTNAME_STRICT` | Whether Keycloak rejects requests whose `Host` header doesn't match `KC_HOSTNAME` (chart default `"true"`). The provided AWS values files set `"false"` so in-cluster callers on other addresses still work | `"false"` |
| `config.KC_HTTPS_KEY_ALIAS` | Alias of the server key inside `keystore.jks` | *(from Step3)* |
| `service.loadBalancer.loadBalancerIP` | Static IP for Keycloak's LoadBalancer Service, rendered as the Azure `azure-load-balancer-ipv4` annotation plus `spec.loadBalancerIP`. The provided AWS values files leave it unset — leave it empty on EKS | `""` |
| `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | AKV name, identity client ID, tenant ID read by `templates/secretproviderclass.yaml`. Not set in the provided AWS values files | `kv-dpn-<env>-<region>-<seq>` / `<client-id>` / `<tenant-id>` |
| `secretsManager.secretPrefix` (and `secretsManager.enabled`) | Prefix of the Secrets Manager entries. The backend is chosen by `cloudProvider: aws`; the Keycloak templates read only `secretPrefix`, and the provided AWS values files also set `enabled: true` (see [Step2, Option A](#option-a--aws-secrets-manager-secretsmanagerenabled-true)) | `true` / `dpn/<env>-<cluster>/keycloak` |
| `serviceAccount.create` / `serviceAccount.automountServiceAccountToken` / `serviceAccount.annotations` | IRSA ServiceAccount — required for the Secrets Manager path (`cloudProvider: aws`). The role is described in [Create the IAM role `dpn-keycloak-secrets-role` (IRSA)](#create-the-iam-role-dpn-keycloak-secrets-role-irsa) | `true` / `true` / `eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/dpn-keycloak-secrets-role` |
| `imagePullSecret` | Name of the image pull secret (default empty = anonymous pulls) | `ghcr-pull-secret` |
| `image.repository` | GHCR path for the Keycloak image (tag defaults to the chart's `image.tag`, `26.3.2`) | `ghcr.io/energy-dsi/keycloak` |
| `postgres.image.repository` | GHCR path for the bundled PostgreSQL image (tag defaults to `postgres.image.tag`, `16-alpine`) | `ghcr.io/energy-dsi/postgres` |
| `postgres.persistence.storageClassName` / `persistence.storageClass` | Storage class for the PostgreSQL PVC and the Keycloak per-replica PVCs | `gp3` |

**Using a managed database instead of the bundled PostgreSQL:**

```yaml
postgres:
  enabled: false
config:
  KC_DB_URL: jdbc:postgresql://<rds-endpoint>.rds.amazonaws.com:5432/keycloak_db
  KC_DB_USERNAME: keycloak_db_user
```

**Environments provided:** `dev`/`test` (both `dpn01` and `dpn02`).

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

Deployed with the `dpn-gha-keycloak-cd.yaml` GitHub Actions workflow (display name **DPN CD - Keycloak**) in `dpn-authentication-service`:

```text
root/
└── .github/
    ├── workflows/
    │   └── dpn-gha-keycloak-cd.yaml
    ├── actions/
    │   └── cloud-login/
    │       └── action.yml
    └── config/
        └── aws/
            └── <environment>-<cluster>.json   <- AWS_REGION, AWS_ACCOUNT_ID, EKS_CLUSTER, NAMESPACE, ...
```

The workflow loads `.github/config/aws/<environment>-<cluster>.json` into the job environment, logs in through the `.github/actions/cloud-login` composite action (AWS OIDC + EKS kubeconfig), then runs `helm lint` + dry run, then `helm upgrade --install` (rolling out `dpn-keycloak-postgres` as a Deployment and `dpn-keycloak` itself as a StatefulSet — the rollout-status check uses the matching resource kind for each), then **automatically configures the realm** (see below), and records the deployed image digest as a workflow artifact. There is no ADO-style approval gate built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.

`workflow_dispatch` inputs:

| Input | Default | Notes |
|---|---|---|
| `environment` | `test` | `dev` / `test` |
| `cluster` | `dpn01` | `dpn01` / `dpn02` |
| `cloud` | `aws` | `azure` / `aws` / `gcp` — select `aws` |
| `keycloakImageRepository` | *(blank)* | Optional — path after `ghcr.io/energy-dsi/` (e.g. `keycloak`); blank uses the values file's `image.repository` |
| `keycloakImageTag` | *(blank)* | Optional — blank uses the configured `image.tag` |
| `postgresImageRepository` / `postgresImageTag` | *(blank)* | Same, for the bundled PostgreSQL image (`postgres.image.repository` / `postgres.image.tag`) |

The job runs under the GitHub Environment `<environment>-<cluster>`, uses Helm release name `dpn-keycloak` and deploys into the `NAMESPACE` from the config JSON.

> **Realm configuration is automatic, not manual.** After the Helm deploy, the workflow's "Configure Realm, Client, Roles and Audit Logging" step port-forwards to the internal Service and runs `charts/keycloak/scripts/configure-keycloak.sh`, which creates/updates the `dpn-realm` realm, the `DPN-Client` machine client, the shared `dpn-service-client` UI client (with every observability UI's redirect URI/web origin), realm roles (`dpnreader`, `dpnadmin`, and now **`dpnoperator`** — trigger/enable/disable DAGs and manage task state without edit/delete rights), matching groups, and session/audit settings — idempotently, on every deploy. When `cloud: aws`, `KC_ADMIN_PASSWORD` and `KC_SERVICE_CLIENT_SECRET` are read with `aws secretsmanager get-secret-value --secret-id dpn/<environment>-<cluster>/keycloak/KEYCLOAK_ADMIN_PASSWORD` and `.../keycloak/KC_SERVICE_CLIENT_SECRET`.
>
> **UI redirect hosts use stable internal hostnames.** The workflow no longer looks up each UI's LoadBalancer hostname — it leaves the `KC_UI_HOST_*` variables at `configure-keycloak.sh`'s own defaults, which point at each UI's stable internal Service DNS name (for example `KC_UI_HOST_PORTAL` defaults to `dpn-observability.ns-dpn-health-01.svc.cluster.local:8443`) rather than the raw AWS NLB hostname, which changes on every redeploy. Browsers must be able to resolve `*.svc.cluster.local` from outside the cluster (Route 53 Resolver / VPC DNS forwarding). The defaults also cover the Federator Gateway's Kafka UI (`KC_UI_HOST_KAFKA_UI_2`), its Job Runner dashboards (`KC_UI_HOST_FEDERATOR_CLIENT_1`/`KC_UI_HOST_FEDERATOR_CLIENT_2`) and the Self-Service UI (`KC_UI_HOST_DPN_PIPELINES_SELF_SERVICE`).
>
> **Branding.** The realm now sets a custom login theme (`KC_LOGIN_THEME`, default `dpn-portal`, packaged from `charts/keycloak/themes/dpn-portal` by `templates/theme-configmap.yaml`) and header markup (`KC_DISPLAY_NAME_HTML`). Override either as an environment variable on the `configure-keycloak.sh` step if you need different branding per environment.
>
> **No `--wait`/`--timeout` on `helm upgrade` for this path.** Long-lived watches against the EKS API from the self-hosted runner were unreliable and timed out even when the rollout had actually completed — the Helm Deploy step now fires the upgrade without waiting, then polls `kubectl rollout status` with a short per-attempt timeout and a few retries instead.

To roll back, use `dpn-gha-keycloak-rollback.yaml` (**DPN Rollback - Keycloak**) or `helm rollback dpn-keycloak <revision> -n <namespace>` (see [DPN Rollback and Recovery Process](../04-rollback/04-rollback-procedures.md#part-5a--dpn-authentication-service-rollback)); to remove it, use `dpn-gha-keycloak-uninstall.yaml` (**DPN Uninstall - Keycloak**) or `helm uninstall dpn-keycloak -n <namespace>` (see [DPN Uninstallation and Decommissioning Process](../05-uninstall/05-uninstall-decommissioning.md#part-5a--uninstall-dpn-authentication-service)). Note that the PostgreSQL PVC (`dpn-keycloak-postgres-data`) is a chart-managed resource with no `helm.sh/resource-policy: keep` annotation, so it is removed with the release — back up the database first if realm data must survive a reinstall. The Keycloak StatefulSet's per-replica PVCs (`keycloak-data-dpn-keycloak-<n>`) are not deleted by `helm uninstall`; remove them separately for a clean wipe.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V1.1.0 |
