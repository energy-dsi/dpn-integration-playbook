Release : 2.1.0 - Oct 2026

# DPN Data Pipeline Installation Process

---

## Table of Contents

- [Overview](#overview)
- [STEP-01: Prerequisites](#step-01-prerequisites)
- [STEP-02: Run the CI Pipeline](#step-02-run-the-ci-pipeline)
- [STEP-03: Run the CD Pipeline](#step-03-run-the-cd-pipeline)
- [STEP-04: Troubleshooting](#step-04-troubleshooting)
- [Review Notes](#review-notes)

---

## Overview

This guide lists **only what a participant organisation must do** to install the DPN Data Pipeline on Azure using Azure DevOps (ADO) pipelines. Repository: https://github.com/energy-dsi/dpn-data-pipelines.git

| Action | Where |
|--------|-------|
| **Required participant action:** complete the prerequisites | [STEP-01](#step-01-prerequisites) |
| **Required participant action:** run the CI pipeline | [STEP-02](#step-02-run-the-ci-pipeline) |
| **Required participant action:** run the CD pipeline | [STEP-03](#step-03-run-the-cd-pipeline) |

> **Informational (no action required):**
> - CI builds and pushes five images to your Azure Container Registry (ACR): the producer file and topic images, the consumer file and topic extractors, and the Self-Service UI.
> - CD deploys the Self-Service UI and the two consumer pipelines into `ns-dpn-dp-01` using Helm.
> - Producer data products are created at runtime by the Self-Service UI. They are not deployed by the pipelines.

---

## STEP-01: Prerequisites

**Required participant actions.** Complete all of the following before running the pipelines.

| # | Action | Detail |
|---|--------|--------|
| 1 | Copy the repository to your Azure DevOps repository | Clone `dpn-data-pipelines`, check out `main` (or `release/<version>`) and push it to your ADO repository |
| 2 | Provide the platform services | AKS (with metrics-server), ACR attached to AKS, DPN Streaming Service (Kafka), DPN Authentication Service (Keycloak) and DPN Health Monitoring Service (OTEL collector running) |
| 3 | Update the configuration values | Complete the [Configuration Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-01-configuration-table) |
| 4 | Create the secrets | Complete the [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table) in `ns-dpn-dp-01` |
| 5 | Update the environment config file | In `.pipelines/azure-pipelines/config/<environment>-<cluster>.json`, set your ACR name, subscription, resource group, AKS cluster, Key Vault and namespace |
| 6 | Update the pipeline files | Set your agent pool name. Remove or replace the security and quality stages in the CI pipeline that you do not use (Checkmarx, FOSSA, SonarQube, JFrog X-Ray). Leave no `<<Your specific value>>` placeholders |
| 7 | Set the approval gate | Configure the approval check on the Azure DevOps Environment used by the CD pipeline |
| 8 | Apply network and firewall rules | See [Network and Ports Configuration](../02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration) |

[Refer to the **Prerequisites** documentation for details](../01-prerequisites/01-dpn-prerequisites.md)

---

## STEP-02: Run the CI Pipeline

**Required participant action.** Create a pipeline from `.pipelines/azure-pipelines/ci-pipelines/dpn-self-service-ci.yaml` and run it with these parameters:

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | Azure service connection that can push to the ACR |
| `environment` | Target environment, e.g. `dev` |
| `cluster` | `dpn01` or `dpn02` |

**Record the image tag** shown in the run summary (the run's build number). The CD pipeline needs it.

To check the result, confirm the images exist in the ACR under that tag:

```bash
az acr repository show-tags --name <acr-name> --repository dsi/dpn-consumer-file-extractor --output table
```

---

## STEP-03: Run the CD Pipeline

**Required participant action.** Create a pipeline from `.pipelines/azure-pipelines/cd-pipelines/dpn-self-service-cd.yaml` and run it with these parameters:

| Parameter | Value |
|-----------|-------|
| `ServiceConnection` | Service connection that can deploy to the AKS cluster |
| `environment` | Same environment as the CI run |
| `cluster` | `dpn01` or `dpn02` |
| `imageTag` | The image tag recorded in [STEP-02](#step-02-run-the-ci-pipeline) |

Approve the deployment when the approval gate is raised.

**Required after the first deployment:** register the Self-Service UI address as a redirect URI on the Keycloak client `dpn-service-client` (`<url>/oauth2/callback`, with **Standard flow** enabled). The pipeline prints the address in a warning. Login does not work until this is done.

To check the result, all three pods must show `Running`:

```bash
kubectl get pods -n ns-dpn-dp-01
```

```text
dpn-self-service-xxxxxxxx-xxxxx
dpn-consumer-file-extractor-xxxxxxxx-xxxxx
dpn-consumer-topic-extractor-xxxxxxxx-xxxxx
```

> **Informational (no action required):** The UI address is filled in automatically by the pipeline. To roll back or remove the platform, use `dpn-self-service-rollback.yaml` or `dpn-self-service-uninstall-cd.yaml`.

---

## STEP-04: Troubleshooting

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| CI fails at push | The service connection cannot push to the ACR | Grant push permission on the ACR |
| CI fails in a scan stage | A tool stage is not configured for your organisation | Remove or replace the stage |
| `ImagePullBackOff` / `ErrImagePull` | AKS cannot pull from the ACR, or the image tag does not exist | Attach the ACR to AKS. Check the tag exists in the ACR |
| Pod stuck in `Pending` or not starting | Insufficient node resources, or a Secret the pod references is missing | `kubectl describe pod <pod> -n ns-dpn-dp-01` and read the Events |
| `CrashLoopBackOff` | Missing or incorrect secret, wrong truststore password, or invalid configuration value | `kubectl logs <pod> -n ns-dpn-dp-01`. Check the [Secrets Table](../02-configuration/07-configure-dpn-data-pipelines.md#step-02-secrets-table) and that storage connection strings are base64-encoded |
| Kafka SASL `invalid_token` | The Keycloak token endpoint uses the load-balancer hostname | Use the `dpn-keycloak` ClusterIP service URL |
| UI login fails | The redirect URI is not registered in Keycloak, or the user has no `dpnadmin`, `dpnoperator` or `dpnreader` role | Register `<url>/oauth2/callback` on `dpn-service-client`. Assign a role |
| `401` on every UI request | The request bypassed the login proxy (for example `kubectl port-forward`) | Use the UI's external address |

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| May-2026 | DSI Assurance   | Final  | V1.0.0 |
| Sep-2026 | DSI Assurance   | Final  | V2.0.0 |
| Oct-2026 | DSI Assurance   | Final  | V3.0.0 |
