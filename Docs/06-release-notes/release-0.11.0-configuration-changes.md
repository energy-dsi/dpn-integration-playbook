# Release 0.11.0 — Configuration Changes

This page lists every configuration-level change introduced since **Release 2.0.0**, organised by component. Each table marks an item as **Added**, **Removed**, or **Modified** so a participant already running Release 2.0.0 can see exactly what to review before upgrading.

This page covers **configuration and deployment surface only** (Helm values, pipeline parameters, secrets, endpoints). For narrative descriptions of each change, see the linked configuration guide for that component.

---

## Table of Contents

- [DPN Federator Gateway](#dpn-federator-gateway)
- [DPN Federator Certificate Manager](#dpn-federator-certificate-manager)
- [DPN REST Federator Gateway](#dpn-rest-federator-gateway)
- [Upgrade Checklist](#upgrade-checklist)

---

## DPN Federator Gateway

See [Configure DPN Federator Gateway](../03-dpn-application-deployment/azure-ado-beta/02-configuration/05-configure-dpn-federator-gateway.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `otel.tls.enabled`, `otel.oauth.enabled`, `otel.truststorePath` | OTLP export to the Collector now supports HTTPS and OAuth2 Bearer auth via the existing `dpn-service-client` Keycloak client — both **on by default** in every environment |
| Added | `federatorClient.nginxSidecar.enabled`, `federatorClient.service.jobRunnerInternalPort` | Optional nginx sidecar fronting the JobRunr dashboard for TLS termination and a fast-path auth check — **on in every current environment's values file**, though `false` is still the base chart default |
| Modified | JobRunr heartbeat/auth behaviour | The embedded Java HTTPS/auth-gateway path (`federatorClient.auth.*`, still present and still the real authenticator) was hardened for a concurrency/stall bug independently of the nginx sidecar change above |
| Modified | Federator Server heartbeat interval | `PT1H` → `PT15M`. **Not a `values.yaml` key** — hardcoded in the chart's rendered config, so changing it per environment requires editing the chart template |
| Modified | JWT audience / client-ID comparison | Now case-sensitive (was case-insensitive), per RFC 7519 §4.1.3 — no config key changed, but any client ID registered with DSM in a different case than configured here will now be rejected |

> **Known gap — not fully migrated:** a separate, legacy `charts/dpn-platform/values/azure/*.yaml` values layout exists in this repository and was **not** updated with the new `nginxSidecar`/`jobRunnerInternalPort` keys. Confirm which values path an environment actually deploys from before assuming the nginx sidecar is active.

---

## DPN Federator Certificate Manager

See [Configure DPN Certificate Manager](../03-dpn-application-deployment/azure-ado-beta/02-configuration/04-configure-dpn-certificate-manager.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `otel.oauth2.enabled`, `otel.oauth2.tokenUri`, `otel.oauth2.clientId` | Same OTLP OAuth2 mechanism as the Federator Gateway, reusing `dpn-service-client` and the pre-existing `dpn-keycloak-secrets` / `KC_SERVICE_CLIENT_SECRET` secret. **On by default** |

> **Cross-repo dependency:** the `dpn-keycloak-secrets` secret this depends on is not created by this chart — it's produced by the DPN Authentication Service's own `SecretProviderClass` and must already be propagated into this component's namespace.

---

## DPN REST Federator Gateway

See [Configure DPN REST Federator Gateway](../03-dpn-application-deployment/azure-ado-beta/02-configuration/06-configure-dpn-rest-federator-gateway.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `restFederatorServer.otel.tls.enabled`, `restFederatorServer.otel.oauth2.enabled` | Same OTLP HTTPS/OAuth2 pattern as the gRPC Federator Gateway. Off by default everywhere, so this doesn't change existing behaviour |
| Modified | Error logging | Exceptions in the server/client/common modules now log the full stack trace and cause chain instead of just the top-level message (demo/demo-runner modules intentionally out of scope) |

---

## Upgrade Checklist

For an organisation moving from Release 2.0.0:

1. **Federator Gateway / Certificate Manager**: no mandatory action — the new OTel TLS/OAuth2 flags default to **on**, reusing credentials and certificates already present from earlier releases. If your OTel Collector does not yet enforce HTTPS/Bearer auth, you may need to set `otel.tls.enabled`/`otel.oauth.enabled` (or `otel.oauth2.enabled` on Certificate Manager) to `false` explicitly until it does.
2. **Federator Client (JobRunr dashboard)**: no mandatory action if you were already running with `federatorClient.auth.enabled: true` — the nginx sidecar is additive. If you maintain your own copy of the legacy `values/azure/*.yaml` layout, add `nginxSidecar.enabled`/`jobRunnerInternalPort` yourself or confirm you're intentionally staying on the Java-only path.
3. **Federator Server**: expect heartbeat signals to DSM every 15 minutes instead of hourly — no action needed, but update any external monitoring that assumed an hourly cadence.
4. **Any integration relying on case-insensitive client-ID matching**: confirm the client ID configured on each DPN node matches DSM's registration exactly, including case — this will now be rejected rather than silently accepted.
5. **REST Federator Gateway**: no action — the new OTel flags default off, so nothing changes unless you turn them on.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-------------------|--------|---------|
| — | — | Draft — pending DSI Assurance review | V0.1.0 |
