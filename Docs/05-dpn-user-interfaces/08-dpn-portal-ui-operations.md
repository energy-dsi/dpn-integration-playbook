# DPN Portal User Guide

> **Audience:** Operations and data team members who need a single, Keycloak-authenticated entry point into DPN's observability UIs.

---

## Table of Contents

1. [What is the DPN Portal?](#1-what-is-the-dpn-portal)
2. [Accessing the Portal](#2-accessing-the-portal)
3. [Tiles](#3-tiles)
4. [Access Control (Keycloak Groups)](#4-access-control-keycloak-groups)
5. [Troubleshooting](#5-troubleshooting)

---

## 1. What is the DPN Portal?

The DPN Portal is a single landing page linking out to every DPN observability UI — Kafka UI, OpenSearch Dashboards, Jaeger, and Apache Airflow — served over **HTTPS**. It replaces separately bookmarking each UI's own address with one authenticated starting point.

The portal itself carries **no authentication logic**. Like the other observability UIs, it sits behind its own `oauth2-proxy` sidecar, which terminates OIDC login against the DPN Authentication Service (Keycloak realm `dpn-realm` — see [Configure DPN Authentication Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/07-configure-dpn-authentication-service.md)). `oauth2-proxy` forwards the authenticated request to the portal application with `X-Forwarded-User` and `X-Forwarded-Groups` headers already attached; the portal only reads those headers to decide which tiles to show.

## 2. Accessing the Portal

```text
https://dpn-observability.<namespace>.svc.cluster.local:<portal-port>
```

Signing in redirects through the Keycloak login page. Once authenticated, the landing page lists every tile your Keycloak group grants you.

## 3. Tiles

| Tile | Links to | Purpose |
|------|----------|---------|
| Kafka UI | The health-monitoring Kafka UI | Browse topics and manage the `dpn-kafka-health`, `kafka-src`, and `kafka-target` clusters — see [Kafka UI Operations](04-kafka-ui-operations.md) / [Kafka Health UI Operations](07-kafka-health-ui-operations.md) |
| OpenSearch Dashboards | OpenSearch | Search and visualise logs shipped via the OpenTelemetry Collector — see [OpenSearch Dashboard Operations](05-opensearch-dashboard-ui-operations.md) |
| Jaeger | Jaeger | Trace requests end-to-end across DPN services — see [Jaeger Dashboard Operations](06-jaeger-dashboard-ui-operations.md) |
| Airflow | Apache Airflow | Monitor and manage the DPN data-pipeline DAGs — see [Airflow Scheduler UI Operations](02-apache-airflow-scheduler-ui-operations.md) |

Each tile opens the target UI directly over its own HTTPS address — the portal is a directory, not a reverse proxy for these UIs' content.

## 4. Access Control (Keycloak Groups)

Tile visibility is filtered by the Keycloak group(s) in the `X-Forwarded-Groups` header. Two groups exist today:

| Group | Intended for |
|-------|--------------|
| `dpnadmin` | Administrators |
| `dpnreader` | Read-only operational users |

> **Current limitation.** Both groups currently see every tile — the per-tile group list is scaffolding for a future, more granular access model rather than an enforced admin/reader split today. If a service should become admin-only, that is a configuration change to its tile's `groups` list, not a code change.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Redirected to Keycloak repeatedly, never reaches the portal | Session cookie rejected or Keycloak client misconfigured | Confirm the portal's oauth2-proxy client is registered correctly in the `dpn-realm` realm and that its redirect URI matches the portal's HTTPS address |
| Portal loads but a tile is missing | Your Keycloak group isn't in that tile's allowed `groups` list, or the tile's `*_URL` environment variable is unset | Check your assigned Keycloak groups; check the portal chart's ConfigMap for the tile's URL variable |
| Tile link loads a login page again instead of the target UI | That UI's own oauth2-proxy session has expired independently of the portal's | Sign in again on that UI directly — each UI has its own oauth2-proxy session, they are not currently unified into a single sign-on session across tiles |
