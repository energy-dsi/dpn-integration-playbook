Release : 2.1.0 - Oct 2026

# DPN Data Pipeline Installation Process

---

## Table of Contents

- [Overview](#overview)
- [STEP-01: Prerequisites](#step-01-prerequisites)
- [STEP-02: Run the CI Workflow](#step-02-run-the-ci-workflow)
- [STEP-03: Run the CD Workflow](#step-03-run-the-cd-workflow)
- [STEP-04: Troubleshooting](#step-04-troubleshooting)
- [Review Notes](#review-notes)

---

## Overview

This guide lists **only what a participant organisation must do** to install the DPN Data Pipeline on AWS using GitHub Actions workflows. Repository: https://github.com/energy-dsi/dpn-data-pipelines.git

| Action | Where |
|--------|-------|
| **Required participant action:** complete the prerequisites | [STEP-01](#step-01-prerequisites) |
| **Required participant action:** run the CI workflow | [STEP-02](#step-02-run-the-ci-workflow) |
| **Required participant action:** run the CD workflow | [STEP-03](#step-03-run-the-cd-workflow) |

> **Informational (no action required):**
> - CI builds and pushes five images to the GitHub Container Registry (`ghcr.io/energy-dsi/dsi/`): the producer file and topic images, the consumer file and topic extractors, and the Self-Service UI.
> - CD deploys the Self-Service UI and the two consumer pipelines into `ns-dpn-dp-01` on EKS using Helm.
> - Producer data products are created at runtime by the Self-Service UI. They are not deployed by the workflows.

---

## STEP-01: Prerequisites

**Required participant actions.** Complete all of the following before running the workflows.

| # | Action | Detail |
|---|--------|--------|
| 1 | Get the repository | Clone `dpn-data-pipelines` and check out `main` (or `release/<version>`). If you run the workflows from your own GitHub organisation, push the code there |
| 2 | Provide the platform services | EKS (with the metrics-server add-on), DPN Streaming Service (Kafka), DPN Authentication Service (Keycloak) and DPN Health Monitoring Service (OTEL collector running) |
| 3 | Create the namespace | `ns-dpn-dp-01` must exist. The workflow does not create it |
| 4 | Set up the CD workflow's AWS access | Create an IAM role for the `roleToAssume` input: trusted through GitHub OIDC for your repository, with `eks:DescribeCluster`, mapped into the EKS cluster (`aws-auth` or an access entry) and bound to the Role/RoleBinding in `dpn-self-service-eks-rbac.yaml` |
| 5 | Update the configuration values | Complete the [Configuration Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-01-configuration-table) |
| 6 | Create the secrets | Complete the [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table) in `ns-dpn-dp-01` |
| 7 | Update the environment config file | In `.pipelines/github-actions-pipelines/aws-pipelines/config/<environment>-<cluster>.json`, set `AWS_ACCOUNT_ID`, `AWS_REGION`, `EKS_CLUSTER` and `NAMESPACE`. Leave no placeholder values |
| 8 | Set the approval gate | Create the GitHub Environment `dpn-self-service-<environment>` (for example `dpn-self-service-dev`) and add the required reviewers. The rollback and uninstall workflows use the same environments |
| 9 | Apply network and firewall rules | See [Network and Ports Configuration](../02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration), including outbound access to `ghcr.io` |

[Refer to the **Prerequisites** documentation for details](../01-prerequisites/01-dpn-prerequisites.md)

> **Informational (no action required):** The AWS workflows are in `.pipelines/github-actions-pipelines/aws-pipelines/`. They are currently not present on the `develop` branch of `dpn-data-pipelines`. If they are missing from the branch you cloned, restore them from the repository's git history (the commit before `Temporarily remove AWS GitHub Actions pipelines`). The one-time EKS setup is in `dpn-self-service-eks-setup.md`.

---

## STEP-02: Run the CI Workflow

**Required participant action.** Run the workflow `dpn-self-service-ci.yaml` (**DPN Self-Service — CI (Build, Test, Push)**) from the Actions tab. It takes no inputs and builds all five images in one run.

**Record the image tag** (the run number shown in the Actions run header). The CD workflow needs it.

To check the result, confirm the five packages exist under `dsi/` in GHCR with that tag:

```bash
gh api /orgs/energy-dsi/packages/container/dsi%2Fdpn-consumer-file-extractor/versions --jq '.[].metadata.container.tags'
```

---

## STEP-03: Run the CD Workflow

**Required participant action.** Run the workflow `dpn-self-service-cd.yaml` (**DPN Self-Service — Deploy (AWS EKS)**) with these inputs:

| Input | Value |
|-------|-------|
| `environment` | `dev` or `devtest` |
| `cluster` | `dpn01` or `dpn02` |
| `roleToAssume` | ARN of the IAM role from [STEP-01](#step-01-prerequisites) |
| `imageTag` | The image tag recorded in [STEP-02](#step-02-run-the-ci-workflow) |

Approve the deployment when the GitHub Environment approval gate is raised.

**Required after the first deployment (to enable UI login):** read the address assigned to `dpn-self-service-external`, redeploy with `oauth2Proxy.enabled=true` and `oauth2Proxy.externalUrl=<address>`, then register `<address>/oauth2/callback` as a redirect URI on the Keycloak client `dpn-service-client` (with **Standard flow** enabled). Login is off by default until this is done.

To check the result, all three pods must show `Running`:

```bash
kubectl get pods -n ns-dpn-dp-01
```

```text
dpn-self-service-xxxxxxxx-xxxxx
dpn-consumer-file-extractor-xxxxxxxx-xxxxx
dpn-consumer-topic-extractor-xxxxxxxx-xxxxx
```

> **Informational (no action required):** The Self-Service UI is deployed with `env.DPN_CLOUD_PROVIDER=aws` and an internal EKS load balancer, so its address is reachable only from inside the VPC or a connected network. To roll back or remove the platform, use `dpn-self-service-rollback.yaml` or `dpn-self-service-uninstall-cd.yaml`.

---

## STEP-04: Troubleshooting

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| CI fails at push | The workflow cannot publish to GHCR | Grant `packages: write` and allow publishing to `ghcr.io/energy-dsi` |
| CD fails to authenticate to EKS | The IAM role is not trusted through OIDC, or is not mapped into the cluster | Check the trust policy, `eks:DescribeCluster`, the `aws-auth` or access-entry mapping and `dpn-self-service-eks-rbac.yaml` |
| `ImagePullBackOff` / `ErrImagePull` | The pull secret is missing or expired, nodes cannot reach `ghcr.io`, or the image tag does not exist | Recreate `ghcr-pull-secret`. Check outbound access to `ghcr.io`. Check the tag exists in GHCR |
| Pod stuck in `Pending` or not starting | Insufficient node resources, or a Secret the pod references is missing | `kubectl describe pod <pod> -n ns-dpn-dp-01` and read the Events |
| `CrashLoopBackOff` | Missing or incorrect secret, wrong truststore password, invalid configuration value, or non-empty `awsEndpointUrl` | `kubectl logs <pod> -n ns-dpn-dp-01`. Check the [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table) and that `awsEndpointUrl` is `""` |
| Storage errors (access denied, bucket cannot be created) | `aws-access-secret` is invalid or the IAM identity lacks S3 permissions | Check the permissions listed in the Secrets Table. S3 bucket names are global, so a name used by another AWS account is rejected |
| Kafka SASL `invalid_token` | The Keycloak token endpoint uses the load-balancer hostname | Use the `dpn-keycloak` ClusterIP service URL |
| TLS handshake or truststore password error | Wrong `TRUSTSTORE_PASSWORD` in `tls-auth-secret`, or `dpn-tls` has no `truststore.jks` | Verify both secrets |
| UI login fails | The redirect URI is not registered in Keycloak, or the user has no `dpnadmin`, `dpnoperator` or `dpnreader` role | Register `<address>/oauth2/callback` on `dpn-service-client`. Assign a role |
| `401` on every UI request | The request bypassed the login proxy (for example `kubectl port-forward`) | Use the UI's external address |

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Draft  | V2.0.0 |
