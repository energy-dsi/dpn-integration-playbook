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

The DPN Health Monitoring Service hosts the observability platform for DPN. It provides health metrics and detailed logs reported by each DPN component. The Health Monitoring service is deployed in a separate namespace, `ns-dpn-health-01`.

---

## Continuous Deployment (CD)

DPN Health Monitoring Service is provided in repository `dpn-health-monitoring-service` 

Every health monitoring component is a third-party Helm chart/image compliant with Apache 2.0. There is no CI pipeline for this component. Deployment is orchestrated by `monitoring-master-cd.yaml`, calling each component's own CD template as a dependent stage.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── cd-pipelines/
            └── monitoring-master-cd.yaml
```
---

## Step 1: Prepare Environment Configuration File

Organisations should prepare a `config.json` file per environment where the health monitoring service is deployed, and keep it in the following location. This file will be referenced by the CD pipeline during deployment.

```text
Root-Repository/
└── .pipelines/
    └── azure-pipelines/
        └── config/
            └── dpn-<env-name>.json
```

Refer to [Step2.2: Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration) for the per-environment configurations.

---

## Step 2: Prepare Secrets Configuration

DPN Health Monitoring requires the following Kubernetes secrets to be created for deployment. 

|secret-name| Secret value | Secret-Creation-Step |
|-----------|--------------|----------------------|
|dpn-nginx-basic-auth| A 16 char length complex password with special characters | Kubernetes Secret using volume mount i.e. kubectl create secret generic <secret-name> --from-file=`<path-to-file>` |
| dpn-mon-storage-connection-string | SAS Token generated on the storage account for Thanos | i.e. kubectl create secret generic <secret-name> --from-file=`<path-to-file>`|

The nginx proxy authentication acts as a basic authentication gateway for the following user interfaces.

- Opensearch
- Jaeger
- Apache Perses
- Kafka-health-UI
- Kafka-UI

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
