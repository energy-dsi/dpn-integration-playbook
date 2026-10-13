# DPN Authentication Service Installation Process

This document covers the installation of the **DPN Authentication Service** — the platform's OAuth2/OIDC identity provider, **Keycloak** — into a single target environment and DPN cluster on Amazon Elastic Kubernetes Service (EKS).

**Full instructions live in the configuration guide.** The end-to-end Authentication Service flow — overview, prerequisites, the secrets/TLS/values to populate, deployment, realm configuration and post-deployment verification — is documented in one place:

**[Configure DPN Authentication Service](../02-configuration/02-configure-dpn-authentication-service.md)**

This installation page is a quick-reference summary that points to that guide.

**Deploy this before components that authenticate against it.** The Federator Gateway's Kafka brokers (`kafka.authMode: sasl_ssl`) and the DPN observability UIs (kafka-ui, OpenSearch Dashboards, Jaeger, Perses, Portal, and the Federator Gateway's Job Runner dashboards) authenticate against the realm this service creates. Deploy the Authentication Service first.

---

## Table of Contents

- [Overview](#overview)
- [Step1: Verify Prerequisites](#step1-verify-prerequisites)
- [Step2: Execute CD Workflow](#step2-execute-cd-workflow)
  - [Step2a. Configure GHCR Image Access](#step2a-configure-ghcr-image-access)
  - [Step2b. Execute CD Workflow](#step2b-execute-cd-workflow)
  - [Step2c. Verify CD Workflow](#step2c-verify-cd-workflow)
- [Step3: Post-Deployment Realm and Client Configuration](#step3-post-deployment-realm-and-client-configuration)
- [Step4: Troubleshooting](#step4-troubleshooting)
  - [Secrets Preflight Failure](#secrets-preflight-failure)
  - [KC_HTTPS_KEY_ALIAS Not Found](#kc_https_key_alias-not-found)
  - [Certificate SAN Does Not Cover KC_HOSTNAME](#certificate-san-does-not-cover-kc_hostname)
  - [Internal Load Balancer Is Not Actually Internal](#internal-load-balancer-is-not-actually-internal)
  - [Downstream Login/Logout Failures After Deploy](#downstream-loginlogout-failures-after-deploy)
  - [Rollout Status Check Fails Against the Wrong Resource Kind](#rollout-status-check-fails-against-the-wrong-resource-kind)
- [Review Notes](#review-notes)

---

## Overview

Keycloak is deployed with the `dpn-gha-keycloak-cd.yml` GitHub Actions workflow, into `ns-dpn-01` over **standard one-way HTTPS** (`KC_HTTPS_CLIENT_AUTH=none`, `KC_HTTP_ENABLED=false`), reachable in-cluster and through an internal AWS Network Load Balancer only. Keycloak itself runs as a **StatefulSet** (one PersistentVolumeClaim per replica); its bundled PostgreSQL instance runs as a plain Deployment.

Unlike the source-built DPN components, this service does **not** build a custom image via a CI pipeline — it deploys stock upstream images (`keycloak/keycloak` and `postgres`), pulled via GHCR by default, so there is no separate CI stage to configure.

The workflow (display name **DPN CD - Keycloak**) and the Keycloak Helm chart both live in the central `dpn-containerised-deployment-service` repository:

```text
dpn-containerised-deployment-service/
├── .github/
│   └── workflows/
│       └── dpn-gha-keycloak-cd.yml
└── dpn-authentication-service/
    └── charts/
        └── keycloak/
            └── values/aws/<environment>-<cluster>.yaml
```

---

## Step1: Verify Prerequisites

Confirm the prerequisites before starting — see [Configure DPN Authentication Service → Step1: Meet the Prerequisites](../02-configuration/02-configure-dpn-authentication-service.md#step1-meet-the-prerequisites).

In summary the following must be in place:

- EKS cluster, and or an IRSA-annotated ServiceAccount for AWS Secrets Manager (`secretsManager.enabled: true`)
- `dpn-tls` Kubernetes secret present in the target namespace (Java `keystore.jks`/`truststore.jks`, **not** a `kubernetes.io/tls` secret) and the shared `tls-auth-secret` (`KEYSTORE_PASSWORD`/`TRUSTSTORE_PASSWORD`) — both created by **DPN CD - Prerequisite Pipeline (AWS Universal TLS) #1** (`dpn-gha-tls-cd.yaml`)
- Three secrets populated in AWS Secrets Manager under `dpn/<environment>-<cluster>/keycloak/`: `KC_DB_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`, `KC_SERVICE_CLIENT_SECRET` (the keystore/truststore passwords now come from `tls-auth-secret`, not the SecretProviderClass)
- Target namespace created (the workflow does not create it)

**Note:** Organisations must review the CD workflow for the following before relying on it.

- `KC-SERVICE-CLIENT-SECRET`/`KC_SERVICE_CLIENT_SECRET` matches whatever secret value is already configured on the consuming services' side (`dpn-health-monitoring-service`'s oauth2-proxy/kafka-ui) — a mismatch does not fail the pipeline, it fails login for every dependent UI
- The environment parameters point to the correct deployment environment
- Required firewall rules are applied (outbound access to the container registry, and inbound from consuming namespaces to the internal load balancer)

---

## Step2: Execute CD Workflow

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

Go to **Actions → DPN CD - Keycloak → Run workflow**, and supply:

| Input | Value |
|-----------|-------|
| `environment` | `dev` / `test` |
| `cluster` | `dpn01` / `dpn02` |
| `cloud` | `aws` |
| `keycloakImageRepository` | Optional — path after `ghcr.io/energy-dsi/`; blank uses the environment values file's configured repository |
| `keycloakImageTag` | Optional — blank uses the environment values file's configured tag |
| `postgresImageRepository` / `postgresImageTag` | Same, for the bundled PostgreSQL image |

The workflow runs, in order: config load → cloud login → secrets preflight (Key Vault only — see [Step4](#secrets-preflight-failure)) → `helm lint` + dry run → `helm upgrade --install` → rollout status → **automatic realm/client/role configuration** (`configure-keycloak.sh` — see [Step3](#step3-post-deployment-realm-and-client-configuration)) → deployed image digest published as a workflow artifact. There is no approval-gate concept built in — configure a required reviewer on the GitHub Environment (`<environment>-<cluster>`) if you want a manual sign-off before deploy.

---

### Step2c. Verify CD Workflow

```bash
kubectl get pods -n <namespace> -l app=dpn-keycloak
kubectl get pods -n <namespace> -l app=dpn-keycloak-postgres
kubectl get svc  -n <namespace> dpn-keycloak-service-lb
```

Confirm Keycloak itself came up as a StatefulSet (one pod per configured replica, each with its own PVC):

```bash
kubectl get statefulset dpn-keycloak -n <namespace>
kubectl get pvc -n <namespace> -l app.kubernetes.io/name=dpn-keycloak
```

Confirm the internal NLB has an assigned hostname and is annotated internal:

```bash
kubectl get svc dpn-keycloak-service-lb -n <namespace> \
  -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-internal}'
```

Tail the logs and confirm there are no startup errors, and that the realm-configuration step completed:

```bash
kubectl logs -n <namespace> -l app=dpn-keycloak --tail=100
```

On success, the workflow's realm-configuration step logs `Keycloak configuration complete: realm <realm>, clients <client> + <ui-client>.`

---

## Step3: Post-Deployment Realm and Client Configuration

The Deploy job runs `dpn-authentication-service/charts/keycloak/scripts/configure-keycloak.sh` automatically as its last application step, port-forwarding to the internal Service — no separate manual admin-console step is required:

| Object | Purpose |
|---|---|
| `dpn-realm` realm | Session/audit settings (`ssoSessionIdleTimeout`, `ssoSessionMaxLifespan`, event retention), custom login theme and header branding (`KC_LOGIN_THEME`/`KC_DISPLAY_NAME_HTML`) |
| `DPN-Client` (machine-to-machine) | Client-credentials-only client for service-to-service calls; realm roles mapped onto its service account |
| `dpn-service-client` | Shared OIDC client used by every DPN UI — kafka-ui, the Federator Gateway's Job Runner dashboards directly; OpenSearch Dashboards/Jaeger/Perses/Portal via their `oauth2-proxy` sidecars |
| Realm roles / groups | `dpnreader`/`dpn-readers`, `dpnadmin`/`dpn-admins`, and now **`dpnoperator`/`dpn-operators`** — trigger/enable/disable DAGs and manage task state without edit/delete rights |

**On AWS**, the workflow no longer looks up each UI's LoadBalancer hostname before running `configure-keycloak.sh` — the `KC_UI_HOST_*` variables are left at the script's own defaults, which point at each UI's stable internal Service DNS name (e.g. `dpn-oauth2-proxy-portal.ns-dpn-health-01.svc.cluster.local:8443`) rather than the raw NLB hostname, which changes on every redeploy. This relies on browsers being able to resolve `*.svc.cluster.local` from outside the cluster (Route 53 Resolver / VPC DNS forwarding). `KC_ADMIN_PASSWORD` and `KC_SERVICE_CLIENT_SECRET` are read from Secrets Manager (`dpn/<environment>-<cluster>/keycloak/KEYCLOAK_ADMIN_PASSWORD` and `.../keycloak/KC_SERVICE_CLIENT_SECRET`).

Two things to confirm after every deploy:

- The redirect URIs/web origins on `dpn-service-client` cover every UI that needs to authenticate in this environment, including the two Federator Gateway Job Runner dashboards (`KC_UI_HOST_FEDERATOR_CLIENT_1`/`KC_UI_HOST_FEDERATOR_CLIENT_2`).
- `KC-SERVICE-CLIENT-SECRET`/`KC_SERVICE_CLIENT_SECRET` in this environment's secrets backend matches the secret value already configured on the consuming services' side — this is a manual, hand-kept-in-sync value, not sourced from a shared location.

---

## Step4: Troubleshooting

### Secrets Preflight Failure

The workflow's "Key Vault Secret Preflight" step is Azure-only and is skipped for `cloud: aws`. On the AWS Secrets Manager path, a missing `KC_DB_PASSWORD`/`KEYCLOAK_ADMIN_PASSWORD`/`KC_SERVICE_CLIENT_SECRET` surfaces as a pod mount/CSI error instead (the rollout-status check then fails and prints `kubectl describe secretproviderclass dpn-keycloak-kv-secrets`), or as an `aws secretsmanager get-secret-value` error in the realm-configuration step. A missing `tls-auth-secret` stops the Keycloak pod from starting, because its keystore/truststore password environment variables reference it. Create the missing secret (re-run `dpn-gha-tls-cd.yaml` for `dpn-tls`/`tls-auth-secret`) and re-run; check `kubectl describe pod` for the affected pod.

---

### KC_HTTPS_KEY_ALIAS Not Found

Keycloak aborts at startup if `config.KC_HTTPS_KEY_ALIAS` does not match a real alias inside `dpn-tls`'s `keystore.jks`. Find the correct alias:

```bash
kubectl get secret dpn-tls -n <namespace> \
  -o jsonpath='{.data.keystore\.jks}' | base64 -d > keystore.jks

keytool -list -keystore keystore.jks \
  -storepass "$(kubectl get secret tls-auth-secret -n <namespace> \
    -o jsonpath='{.data.KEYSTORE_PASSWORD}' | base64 -d)"
```

For a keystore generated by `dpn-gha-tls-cd.yaml` the alias is `dpn-server`. Set `config.KC_HTTPS_KEY_ALIAS` in `dpn-authentication-service/charts/keycloak/values/aws/<environment>-<cluster>.yaml` to the alias listed, then re-run the CD workflow.

---

### Certificate SAN Does Not Cover KC_HOSTNAME

Keycloak will still start if the certificate behind `KC_HTTPS_KEY_ALIAS` does not carry `config.KC_HOSTNAME` as a SAN, but every issuer URL and redirect URI it advertises will use the mismatched hostname, which browsers/consumers will reject. Set `KC_HOSTNAME` to a name the certificate actually carries, or leave it empty with `KC_HOSTNAME_STRICT: "false"` to derive the hostname from the incoming request instead — see the pinning note in [Configure DPN Authentication Service, Step3](../02-configuration/02-configure-dpn-authentication-service.md#step3-configure-tls) for why leaving it empty can itself leak an internal hostname into a browser redirect.

---

### Internal Load Balancer Is Not Actually Internal

If the NLB ends up internet-facing, the almost-certain cause is `cloudProvider` left at its chart default (`azure`) in the environment values file — the Service then carries the Azure-style annotation instead of `service.beta.kubernetes.io/aws-load-balancer-internal: "true"` / `aws-load-balancer-type: "nlb"`, and AWS ignores the annotation it doesn't recognise. Check:

```bash
kubectl get svc dpn-keycloak-service-lb -n <namespace> -o yaml | grep -A5 annotations
```

Set `cloudProvider: aws` in the values file and redeploy.

---

### Downstream Login/Logout Failures After Deploy

If a specific UI cannot complete login, or logout leaves the SSO session alive with an "Invalid redirect uri" error, check:

- The UI's internal Service DNS name registered by `configure-keycloak.sh` (see [Step3](#step3-post-deployment-realm-and-client-configuration)) resolves from the browser — if not, check Route 53 Resolver / VPC DNS forwarding for `*.svc.cluster.local`.
- For UIs behind `oauth2-proxy` (OpenSearch Dashboards, Jaeger, Perses, Portal), the bare root hostname (no path) matches the `post.logout.redirect.uris` entry and the `post_logout_redirect_uri` the proxy actually sends.
- `KC-SERVICE-CLIENT-SECRET`/`KC_SERVICE_CLIENT_SECRET` in the secrets backend matches the secret configured on the consuming service's side.

---

### Rollout Status Check Fails Against the Wrong Resource Kind

Keycloak is a **StatefulSet**, not a Deployment (PostgreSQL remains a Deployment) — the workflow's rollout-status step checks each with its matching `kubectl rollout status <kind>/<name>` call. If you see `Error from server (NotFound): statefulsets.apps "dpn-keycloak" not found` (or the reverse, a `deployments.apps "dpn-keycloak" not found`), the workflow file and the deployed chart version have drifted out of sync — redeploy from the current chart, or confirm the workflow file in use matches the chart's resource kind.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-------------------|--------|---------|
| — | — | Draft — pending DSI Assurance review | V0.1.0 |
