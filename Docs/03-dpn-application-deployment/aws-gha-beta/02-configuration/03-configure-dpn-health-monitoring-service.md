Release : 2.1.0 - Oct 2026

# DPN Health Monitoring Service Configuration Guide

---

## Table of Contents

- [Overview](#overview)
- [Continuous Deployment (CD)](#continuous-deployment-cd)
- [Step 1: Prepare Environment Configuration File](#step-1-prepare-environment-configuration-file)
- [Step 2: Prepare Secrets Configuration](#step-2-prepare-secrets-configuration)
- [Review Notes](#review-notes)

---

## Overview

The DPN Health Monitoring Service hosts the observability platform for DPN — Kafka, OpenSearch, an OpenTelemetry Collector, Prometheus+Thanos, Data Prepper, Jaeger, Perses, and the **DPN Portal** tile landing page. It is deployed in a separate namespace, `ns-dpn-health-01`, on Amazon EKS.

> **The Nginx observability proxy has been retired.** `dpn-nginx-observability` (basic-auth reverse proxy in front of OpenSearch/Jaeger/Perses/Kafka UI/Thanos) and its chart/CD workflow have been removed. Its role is now split between the **DPN Portal** (tile landing page, `charts/dpn-portal`) and one **`oauth2-proxy`** Keycloak-gateway release per UI — see [Step 2](#step-2-prepare-secrets-configuration) below.

---

## Continuous Deployment (CD)

Deployment is orchestrated by the `dpn-gha-health-monitoring-cd-install.yaml` GitHub Actions workflow (display name **DPN Health Monitoring**), which chains each sub-component's own CD workflow as a dependent job in this order: **Validate Required Secrets** (`dpn-gha-validate-required-secrets.yaml`, fails fast before Kafka if a required secret is missing) → Kafka → OpenSearch → Prometheus → Thanos (with Data Prepper and Jaeger branching off Kafka+OpenSearch, Perses off Prometheus+Thanos) → OTel Collector → **DPN Portal** → **OAuth2 Proxy** (OpenSearch → Jaeger → Perses → Portal, chained sequentially) → Validate.

```text
root/
├── .github/
│   ├── actions/
│   │   └── cloud-login/action.yml                      # OIDC login + EKS kubeconfig, used by every component workflow
│   ├── config/
│   │   └── aws/<environment>-<cluster>.json
│   └── workflows/
│       ├── dpn-gha-health-monitoring-cd-install.yaml   # orchestrator — trigger this one
│       ├── dpn-gha-{kafka,opensearch,prometheus,thanos,data-prepper,jaeger,perses,otel,portal,oauth2-proxy}-cd.yaml
│       ├── dpn-gha-validate-required-secrets.yaml      # pre-flight secret check, runs before Kafka
│       ├── dpn-gha-validate.yaml
│       ├── dpn-gha-rollback-health-monitoring.yaml
│       └── dpn-gha-uninstall-health-monitoring.yaml
└── charts/
    ├── {kafka-stack,opensearch,prometheus,thanos,data-prepper,jaeger,perses,otel-collector,dpn-portal,oauth2-proxy}/
    │   └── values/aws/<environment>-<cluster>.yaml
    └── oauth2-proxy-redis/                             # values.yaml only, no per-cluster file
```

The Helm charts live under `charts/<chart>`. Each component workflow deploys `charts/<chart>` with the per-cluster values file `charts/<chart>/values/aws/<environment>-<cluster>.yaml`. On AWS, the OpenSearch and Prometheus per-cluster files are complete, self-contained values files (the shared `*-community-values.yaml` files are used only on Azure); Thanos layers its per-cluster file over the chart's own `values.yaml`; and `oauth2-proxy` layers it over the per-UI `values-<component>.yaml`.

> **Prometheus is a vendored chart.** `charts/prometheus` is a vendored copy of the upstream `kube-prometheus-stack` Helm chart (chart version 87.21.0, appVersion v0.92.1, with its `crds`, `grafana` and other subcharts under `charts/prometheus/charts/`), deployed straight from the repository — the workflow makes no call to an external chart repo (air-gapped) and fails if `charts/prometheus/Chart.yaml` is missing. The `dpn-prometheus` release is installed with the per-cluster AWS values file; `prometheus-node-exporter` is disabled by the workflow. To change the chart version, re-pull `kube-prometheus-stack` into `charts/prometheus/` and commit it — do not hand-edit its `templates/`.

Trigger it via **Actions → DPN Health Monitoring → Run workflow**, supplying `environment` (dev/test), `cluster` (dpn01/dpn02), `cloud` (`aws`), `imageTag` (OTel Collector image tag, default `0.95.0`), and **`portalImageTag`** (the DPN Portal container image tag — required, no default; a short git-SHA printed by the DPN Portal application's own CI build) — the orchestrator's `init` job (**Resolve Deployment Config**) reads the rest of the component config from `.github/config/aws/<environment>-<cluster>.json` itself and passes it to every job. `otelImageRepository` (the OTel Collector image path after the config file's `IMAGE_REGISTRY/`) is optional — leave it blank to use the environment's configured repository. `portalImageRepository` (the image path after `IMAGE_REGISTRY/`) defaults to `dpn-portal` if left blank.

> **Prometheus and Thanos no longer sit behind an `oauth2-proxy` gateway.** Neither UI is meant for direct browser access — both are consumed through Perses instead. Their own component jobs still deploy the Prometheus/Thanos Query Services directly with no login of any kind in front, at the same ports (`9081`/`9091`) their retired `oauth2-proxy` gateways used to publish on. In the `test-*` per-cluster values files they are `type: LoadBalancer` on an internal AWS Network Load Balancer; in the `dev-*` files (`dev-dpn01`/`dev-dpn02`) `dpn-prometheus-health-ui` and `dpn-thanos-query-health` are currently `ClusterIP` only, with no load balancer. Restrict network access to these ports at the VPC/security-group level accordingly.

**What the pipeline does automate:** `dpn-gha-oauth2-proxy-cd.yaml` (**DPN CD - OAuth2 Proxy (Keycloak Gateway)**) provisions its own AWS IAM role (IRSA, `dpn-oauth2-proxy-secrets-role`, trusted by the `dpn-oauth2-proxy` ServiceAccount) and its own Secrets Manager copy of the Keycloak client secret (`dpn/<environment>-<cluster>/oauth2-proxy/KC-SERVICE-CLIENT-SECRET`, copied from the Keycloak secret below if missing) on every run, and installs/updates the shared `dpn-redis-ui-health` session store (`charts/oauth2-proxy-redis`) — this is idempotent and requires no manual AWS IAM setup. The role ARN and secret prefix the chart consumes are pinned per cluster in `charts/oauth2-proxy/values/aws/<environment>-<cluster>.yaml` (`serviceAccount.irsaRoleArn`, `secretsManager.secretPrefix`) — update them if you deploy to a different AWS account.

**What the pipeline does *not* automate:**
- The Keycloak `dpn-service-client` credential must already exist in AWS Secrets Manager, at `dpn/<environment>-<cluster>/keycloak/KC_SERVICE_CLIENT_SECRET` — the same secret `dpn-gha-keycloak-cd.yaml` (DPN Authentication Service) reads on its AWS deploy path; neither workflow creates it, so load it before deploying Keycloak (see [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md)).
- The `dpn-health-tls` Secret (a `kubernetes.io/tls` Secret holding `tls.crt`, `tls.key` and `ca.crt`) must already exist in `ns-dpn-health-01` — every `oauth2-proxy` release and the OTel Collector's TLS-enabled OTLP receivers consume it, and none of them create it.
- The Thanos S3 bucket name and its IRSA role (see [Step 1](#step-1-prepare-environment-configuration-file)) — the Prometheus workflow creates the `dpn-mon-storage-connection-string` Secret itself, but from `charts/thanos/objstore-aws.yaml`, whose `bucket` is a placeholder you must replace before running.
- The three OpenSearch passwords in AWS Secrets Manager at `dpn/<environment>-<cluster>/opensearch/{ADMIN_PASSWORD,KIBANASERVER_PASSWORD,DATAWRITER_PASSWORD}` and the `tls-auth-secret` Secret (keys `KEYSTORE_PASSWORD`, `TRUSTSTORE_PASSWORD`) in `ns-dpn-health-01` (created by the TLS workflow). Neither is created here; `dpn-gha-validate-required-secrets.yaml` checks they exist (existence only, never the value) and fails the run before Kafka if not.
- A DPN Portal container image already built and pushed to GHCR, with its tag known ahead of triggering the workflow — this repository's pipeline deploys that image, it does not build it.

See the [installation guide](../03-installation/03-dpn-health-monitoring-service-installation-process.md) for the exact commands.

---

## Step 1: Prepare Environment Configuration File

Organisations should prepare a config file per environment/cluster where the health monitoring service is deployed, and keep it in the following location. This file will be read by the `init` job of the orchestrator workflow during deployment.

```text
root/
└── .github/
    └── config/
        └── aws/
            └── <environment>-<cluster>.json
```

This config file's keys are the same common ones described in [Step2.2: AWS Environment Configuration](00-common-dpn-configuration.md#step22-aws-environment-configuration) — this service has no health-monitoring-specific keys of its own in that JSON file. Of those keys, the orchestrator only passes `AWS_REGION`, `AWS_ACCOUNT_ID`, `EKS_CLUSTER` and `IMAGE_REGISTRY` on to the component workflows on the AWS path (`IMAGE_REGISTRY` is the prefix for the `otelImageRepository`, `portalImageRepository` and other image-path overrides — in the checked-in files it is `ghcr.io/energy-dsi/1.0.1` for `dev-*` and `ghcr.io/energy-dsi` for `test-*`); the namespace is fixed to `ns-dpn-health-01` by the orchestrator itself, regardless of the file's `NAMESPACE` value. Two things beyond the JSON file still need preparing per environment/cluster before deploying:

- **Thanos' long-term object storage.** `charts/prometheus/values/aws/<environment>-<cluster>.yaml` points Thanos' sidecar at `objectStorageConfig.name: dpn-mon-storage-connection-string` (key `objstore.yml`). On AWS the Prometheus workflow (`dpn-gha-prometheus-cd.yaml`) creates/updates this Secret itself on every run, from `charts/thanos/objstore-aws.yaml` (`type: S3`, `endpoint: s3.eu-west-2.amazonaws.com`, `region: eu-west-2`, **no access keys**). Before deploying you must: (1) replace the placeholder `bucket: "thanos-bucket name"` in `charts/thanos/objstore-aws.yaml` with your Thanos S3 bucket name (and adjust `endpoint`/`region` if not eu-west-2) and commit it; (2) provide credentials through IRSA — the file expects an `eks.amazonaws.com/role-arn` annotation on the Prometheus ServiceAccount, with an IAM role granting S3 access to that bucket; no such role or annotation ships in the per-cluster values files, so create the role and add the annotation yourself.
- **The DPN Portal image.** The orchestrator's `portalImageTag` input (and optionally `portalImageRepository`, default `dpn-portal`) is supplied at trigger time, not read from the JSON config file — see [Continuous Deployment (CD)](#continuous-deployment-cd) above.

> **Image path convention.** This service's AWS values files (OpenSearch, Prometheus/Thanos/Alertmanager, Perses, OTel Collector, Data Prepper, Jaeger, and the Kafka/Zookeeper/Kafka UI images used by its Kafka stack) reference GHCR at `ghcr.io/energy-dsi/1.0.1/<component>` in the `dev-*` files and `ghcr.io/energy-dsi/<component>` in the `test-*` files (Prometheus, Alertmanager and kube-state-metrics use `registry: ghcr.io` plus `repository: energy-dsi/<component>` in both). The DPN Portal image is `<IMAGE_REGISTRY>/<portalImageRepository>`, with `portalImageRepository` defaulting to `dpn-portal`, i.e. `ghcr.io/energy-dsi/1.0.1/dpn-portal` for `dev-*` and `ghcr.io/energy-dsi/dpn-portal` for `test-*`. See [Reference: Container Images Used](../03-installation/03-dpn-health-monitoring-service-installation-process.md#reference-container-images-used) in the installation guide.

---

**Environment-specific values in the Helm values files.** Set them in `charts/<chart>/values/aws/<environment>-<cluster>.yaml`:

| Key | Chart | Description | Example (placeholder) |
|-----|-------|-------------|-----------------------|
| `clusterName` and the `cluster` attribute `value` | `otel-collector` | EKS cluster name; the collector tags every metric, log and trace with it as the `cluster` attribute. Use the same value in both places | `eks-dpn-<env>-<region>` |

---

## Step 2: Prepare Secrets Configuration

DPN Health Monitoring requires the following Kubernetes secrets/external secrets to be created for deployment. The `dpn-nginx-basic-auth` secret previously required here is **no longer needed** — the Nginx observability proxy it authenticated has been retired.

| secret-name | Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
| dpn-mon-storage-connection-string | Thanos long-term object storage config (`objstore.yml` key) | Kubernetes Secret, created by `dpn-gha-prometheus-cd.yaml` from `charts/thanos/objstore-aws.yaml` — you only set the bucket name, see [Step 1](#step-1-prepare-environment-configuration-file) |
| tls-auth-secret | `KEYSTORE_PASSWORD` / `TRUSTSTORE_PASSWORD` used by Kafka UI and Data Prepper | Kubernetes Secret, created by the TLS workflow, not by this pipeline — checked by `dpn-gha-validate-required-secrets.yaml` |
| dpn/`<environment>-<cluster>`/opensearch/{ADMIN_PASSWORD, KIBANASERVER_PASSWORD, DATAWRITER_PASSWORD} | The three OpenSearch account passwords read by the OpenSearch SecretProviderClass | AWS Secrets Manager secrets, created manually — checked by `dpn-gha-validate-required-secrets.yaml` (existence only) |
| dpn-health-tls | `kubernetes.io/tls` cert/key/CA used by `oauth2-proxy` and the OTel Collector's TLS OTLP receivers | Kubernetes Secret, created manually (not created by this pipeline) |
| dpn/`<environment>-<cluster>`/keycloak/KC_SERVICE_CLIENT_SECRET | The `dpn-service-client` Keycloak client credential | AWS Secrets Manager secret, created manually (also read by `dpn-gha-keycloak-cd.yaml`'s AWS deploy path) — must exist before `dpn-gha-oauth2-proxy-cd.yaml` runs |

`dpn-gha-oauth2-proxy-cd.yaml` additionally provisions its own AWS IAM role (IRSA) and its own private Secrets Manager copy of the Keycloak client secret automatically on every run — no manual action needed for that part.

### IAM roles (IRSA) for the health-monitoring ServiceAccounts

Two ServiceAccounts in `ns-dpn-health-01` read AWS Secrets Manager through the Secrets Store CSI driver using IRSA. Each has its own role, scoped read-only to its own prefix. Reference policy files are kept in the `dpn-iam` export under `template/roles/<role-name>/`.

| Role | ServiceAccount (`ns-dpn-health-01`) | Secrets Manager scope | Actions | Created by |
|---|---|---|---|---|
| `dpn-oauth2-proxy-secrets-role` | `dpn-oauth2-proxy` | `dpn/<environment>-<cluster>/oauth2-proxy/*` | `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` | `dpn-gha-oauth2-proxy-cd.yaml` (automatic) |
| `dpn-opensearch-secrets-role` | `dpn-opensearch` | `dpn/<environment>-<cluster>/opensearch/*` | `secretsmanager:GetSecretValue` | Manually, once per account/cluster |

**Trust policy** (same shape for both roles — only the `sub` differs):

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
          "oidc.eks.<region>.amazonaws.com/id/<oidc-provider-id>:sub": "system:serviceaccount:ns-dpn-health-01:<dpn-oauth2-proxy | dpn-opensearch>"
        }
      }
    }
  ]
}
```

**Permission policy — `dpn-opensearch-secrets-role`:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:<region>:<account-id>:secret:dpn/<environment>-<cluster>/opensearch/*"
    }
  ]
}
```

**Permission policy — `dpn-oauth2-proxy-secrets-role`** (shown for reference; the pipeline creates it):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      "Resource": "arn:aws:secretsmanager:<region>:<account-id>:secret:dpn/<environment>-<cluster>/oauth2-proxy/*"
    }
  ]
}
```

Create the OpenSearch role manually and set its ARN as the ServiceAccount's `eks.amazonaws.com/role-arn` annotation in the chart values:

```bash
aws iam create-role \
  --role-name dpn-opensearch-secrets-role \
  --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \
  --role-name dpn-opensearch-secrets-role \
  --policy-name dpn-opensearch-secrets-read \
  --policy-document file://dpn-opensearch-secrets-read.json
```

> **Keycloak SSO is now the only front door for OpenSearch, Jaeger and Perses.** Each is served over **HTTPS** through its own `oauth2-proxy` release, terminating OIDC login against the DPN Authentication Service (Keycloak) — there is no basic-auth fallback any more. The **DPN Portal** tile landing page is itself also fronted by its own `oauth2-proxy` release (`portal`, port `8443`). See [DPN Portal Operations](../../../05-dpn-user-interfaces/08-dpn-portal-ui-operations.md) and [Configure DPN Authentication Service](02-configure-dpn-authentication-service.md).
>
> **Prometheus and Thanos have no login of any kind in front of them.** Their `oauth2-proxy` gateways have been retired — neither UI is meant for direct browser access (both are consumed through Perses), so their Query/UI Services now publish directly (on an internal AWS NLB in the `test-*` values; `ClusterIP` only in the `dev-*` values). Restrict network access to these at the VPC/security-group level; do not expose them beyond the internal network.
>
> **Kafka UI authenticates natively, not through `oauth2-proxy`.** Its own oauth2-proxy release has been removed — Kafka UI now runs its own OIDC login directly against the `dpn-realm` realm, with `dpnadmin`/`dpnreader` realm roles mapped to Kafka UI's own RBAC (full access vs. view-only). See [Kafka Health UI Operations](../../../05-dpn-user-interfaces/07-kafka-health-ui-operations.md#3-accessing-the-kafka-ui). `kafka-ui-2` (ns-dpn-01) also had its `oauth2-proxy` gateway removed with **no replacement added from this service** — securing/exposing it is now the owning domain's own responsibility.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V1.1.0 |
