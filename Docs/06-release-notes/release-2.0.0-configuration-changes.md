# Release 2.0.0 — Configuration Changes

This page lists every configuration-level change introduced since **Release 1.0.0**, organised by component. Each table marks an item as **Added**, **Removed**, or **Modified** so a participant already running Release 1.0.0 can see exactly what to review before upgrading.

This page covers **configuration and deployment surface only** (Helm values, pipeline parameters, secrets, endpoints). For narrative descriptions of each change, see the linked configuration guide for that component.

---

## Table of Contents

- [New Components](#new-components)
- [DPN Vault Service](#dpn-vault-service)
- [DPN Certificate Manager](#dpn-certificate-manager)
- [DPN Federator Gateway](#dpn-federator-gateway)
- [DPN File Scan Service](#dpn-file-scan-service)
- [DPN Observability UIs](#dpn-observability-uis)
- [Upgrade Checklist](#upgrade-checklist)

---

## New Components

Two components are entirely new in this release — every configuration item below is **Added**, not a change to something that existed in Release 1.0.0.

### DPN Authentication Service (Keycloak)

New shared OAuth2/OIDC Identity Provider. See [Configure DPN Authentication Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/07-configure-dpn-authentication-service.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `dpn-keycloak-cd.yaml` / `dpn-keycloak-uninstall-cd.yaml` | Deploy/uninstall pipelines, new repository `dpn-authentication-service` |
| Added | `config.KC_HOSTNAME`, `config.KC_HTTPS_KEY_ALIAS` | Helm values controlling the advertised hostname and TLS key alias |
| Added | `keyvault.name` / `keyvault.clientID` / `keyvault.tenantId` | Key Vault CSI configuration for this component |
| Added | `KC-DB-PASSWORD`, `KEYCLOAK-ADMIN-PASSWORD`, `KC-HTTPS-KEY-STORE-PASSWORD`, `KC-HTTPS-TRUST-STORE-PASSWORD` | Required Key Vault secrets |
| Added | `dpn-tls` Kubernetes secret | Pre-existing `Opaque` secret holding `keystore.jks`/`truststore.jks` for Keycloak's HTTPS listener |

### DPN REST Federator Gateway

New synchronous, HTTPS-based alternative to the gRPC Federator Gateway, in the new repository `dpn-rest-federator-gateway`. See [Configure DPN REST Federator Gateway](../03-dpn-application-deployment/azure-ado-beta/02-configuration/08-configure-dpn-rest-federator-gateway.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `rest-federator-cd.yml` | Deploy pipeline, with an additional `cloud` parameter (`azure`/`aws`/`gcp`) not present on the gRPC Federator's pipeline |
| Added | `restFederatorServer.tls.enabled` / `mtls.enabled` | HTTPS/mTLS listener toggles |
| Added | `restFederatorServer.backend.baseUrl`, `backend.apiKeySecret` | Internal backend the gateway proxies authorised requests to |
| Added | `restFederatorServer.producerId`, `managementNode.baseUrl`, `idp.*` | Management Node and Identity Provider settings, same shape as the gRPC Federator |
| Added | `restFederatorServer.redis.*` | This chart owns its own Redis cache, deployed as a separate release (`dpn-redis`) |
| Added | `restFederatorServer.vault.*` (incl. `vault.appRole.*`) | Vault connectivity — ships with AppRole as the built-in option, not just token |
| Added | `BACKEND-API-KEY` / `dpn-backend-api-key` | Shared secret authenticating the gateway to its internal backend |
| Added | `rest-federator-client` library | Importable Java dependency for consumers — not a deployed component |

---

## DPN Vault Service

See [Configure DPN Vault Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `vault-approle-setup-cd.yaml` pipeline | New 4th pipeline — provisions a scoped AppRole identity (policy + role + `role_id`/`secret_id`) per Vault-consuming component |
| Added | `VAULT-APPROLE-SECRET-ID` Key Vault secret | Output of the new pipeline; 355-day expiry, requires periodic re-run to rotate |
| Modified | `storeRootTokenInAkv` (in `vault-https-cd`) | Still required — the bundle-load pipeline always needs the root token — but no longer the *only* credential path for downstream components |

---

## DPN Certificate Manager

See [Configure DPN Certificate Manager](../03-dpn-application-deployment/azure-ado-beta/02-configuration/03-configure-dpn-certificate-manager.md).

| Change | Item | Details |
|--------|------|---------|
| Removed | `fileShare.storageAccount`, `fileShare.shareName`, `fileShare.secretName` | Shared Azure SMB file share eliminated — the chart no longer creates a PV/PVC |
| Removed | `certDest.path`, `certDest.keystoreFile`, `certDest.truststoreFile`, `certDest.keystoreAlias` | No P12 files are written to disk any more |
| Removed | `mtls.keystorePath`, `mtls.truststorePath`, `mtls.keystoreType` | Superseded by in-memory keystore construction |
| Removed | `azure-fileshare-secret` prerequisite | No longer needed — nothing mounts the file share |
| Added | `vault.uri`, `vault.authentication` (`APPROLE`\|`TOKEN`), `vault.pkiMount`, `vault.secretPath` | Vault connection settings — `APPROLE` is the chart's own default |
| Added | `vault.appRole.roleId`, `vault.appRole.mountPath` | AppRole identity configuration |
| Added | `certIdent.keystoreAlias` | Alias for the in-memory keystore entry (replaces `certDest.keystoreAlias`) |
| Added | `VAULT-APPROLE-SECRET-ID` → `vaultAppRoleSecretId` | New Key Vault secret / Kubernetes secret key, alternative to `VAULT-TOKEN` |
| Added | `existingSecret.name`, `vaultTruststore.secretName` | Explicit Key Vault / truststore secret wiring |
| Modified | `VAULT-TOKEN` → `vaultToken` (Kubernetes secret key) | Kept for backward compatibility; only used when `vault.authentication: TOKEN` |
| Modified | `cert.subject.altNames` | Must now also cover the REST Federator Gateway's endpoint (e.g. `producer-rest01...`) if that component is deployed alongside the gRPC Federator |

---

## DPN Federator Gateway

See [Configure DPN Federator Gateway](../03-dpn-application-deployment/azure-ado-beta/02-configuration/04-configure-dpn-federator-gateway.md).

| Change | Item | Details |
|--------|------|---------|
| Removed | `pvc-dpn-certs-fileshare` shared file share PVC | No longer mounted — certificate material is read from Vault directly |
| Added | `vaultConfig.tlsEnabled`, `vaultConfig.tlsBasePath`, `vaultConfig.tlsKeystoreAlias` | In-memory TLS material construction |
| Added | `vaultConfig.authMethod` (`approle`\|`token`), `vaultConfig.appRole.*` | Vault authentication — AppRole is the recommended option |
| Added | `vaultConfig.mountCertFileShare` | Explicit `false` toggle documenting the file-share removal (kept for backward compatibility) |
| Added | `kafka.authMode` (`sasl_ssl`\|`ssl`\|`plaintext`) | Single value reconfiguring all Kafka listeners; `sasl_ssl` is the production default |
| Added | `kafka.oauth.tokenEndpointUrl` | Keycloak token endpoint used for `OAUTHBEARER` authentication, required when `authMode: sasl_ssl` |
| Modified | `certificate-manager-secrets` contents | Now carries either the AppRole `secret-id` or the root token, instead of always the root token |

---

## DPN File Scan Service

See [Configure DPN File Scan Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/06-configure-dpn-file-scan-service.md) (Azure) and the new [AWS File Scan Service RUNBOOK](../03-dpn-application-deployment/aws-gha-beta/05-file-scan-service/RUNBOOK.md).

| Change | Item | Details |
|--------|------|---------|
| Added | AWS deployment path | New — uses Amazon GuardDuty Malware Protection for S3 instead of Microsoft Defender for Storage |
| Added | `CLOUD_PROVIDER_TYPE=S3` | Selects the AWS code path in the service |
| Added | `AWS_REGION`, `S3_BUCKET_INBOUND`, `S3_BUCKET_OUTBOUND`, `SQS_QUEUE`, `SNS_TOPIC` | AWS-specific configuration, parallel to the existing Azure settings |
| Added | IRSA role annotation on the pod's ServiceAccount | AWS credential mechanism, parallel to the existing Azure managed-identity + Key Vault CSI approach |

No changes to the existing Azure Defender for Storage configuration.

---

## DPN Observability UIs

See [DPN Portal Operations](../05-dpn-user-interfaces/08-dpn-portal-ui-operations.md), [Kafka UI Operations](../05-dpn-user-interfaces/04-kafka-ui-operations.md), [Kafka Health UI Operations](../05-dpn-user-interfaces/07-kafka-health-ui-operations.md), [OpenSearch Dashboard Operations](../05-dpn-user-interfaces/05-opensearch-dashboard-ui-operations.md), and [Jaeger Dashboard Operations](../05-dpn-user-interfaces/06-jaeger-dashboard-ui-operations.md).

| Change | Item | Details |
|--------|------|---------|
| Added | DPN Portal | New single landing page, organised into cards (Users & Roles, Data/Store, Gateway, Data/Pipeline, Security/Services, Health/Monitoring Service) each linking one or more component UIs |
| Added | `dpnadmin` / `dpnreader` Keycloak groups | Control card visibility on the DPN Portal — the "Users & Roles" card (Keycloak Console) is `dpnadmin`-only; every other card is visible to both groups today |
| Modified | Kafka Health UI, OpenSearch Dashboards, Jaeger access URL | Changed from `http://<host>:<port>` with HTTP Basic Auth (nginx) to `https://dpn-observability...:<port>` gated by Keycloak SSO via an `oauth2-proxy` sidecar |
| Modified | Kafka UI, Apache Airflow authentication | Moved from HTTP Basic Auth (nginx) directly to **native** Keycloak OIDC login (no `oauth2-proxy` hop) — Keycloak realm roles map to each application's own RBAC (`dpnadmin`/`dpnreader` → full/view-only in Kafka UI, → `Op`/`Viewer` in Airflow) |
| Modified | Data pipeline OTLP telemetry endpoint | New `OTEL_EXPORTER_OTLP_INSECURE` toggle selects between the OTel Collector's plaintext gRPC endpoint (`:4317`) and its HTTPS endpoint (`:4318`) |

> **Not changed in this release:** the Federator Client JobRunr dashboard (`:8085`) remains plain HTTP by default — a Keycloak-gated HTTPS mode now exists (`federatorClient.auth.enabled`) but is opt-in, not the default. The OpenTelemetry Collector's **gRPC** OTLP receiver (`:4317`) also remains plain HTTP with no TLS option — only its **HTTP** OTLP receiver (`:4318`) gained a certificate-based HTTPS mode (on by default, `tls.enabled: true`).

---

## Upgrade Checklist

For an organisation moving from Release 1.0.0:

1. **Vault**: no mandatory action — root token continues to work. Optionally run `vault-approle-setup-cd` per component and switch `vault.authentication`/`vaultConfig.authMethod` to the AppRole values above.
2. **Certificate Manager**: remove any `fileShare.*`/`certDest.*`/`mtls.*` overrides from your `values-<env>.yaml` — they no longer exist in the chart. Add `vault.uri`, `vault.pkiMount`, `vault.secretPath` if not already set. The `azure-fileshare-secret` and its PV/PVC can be decommissioned once you've confirmed the new deployment is healthy.
3. **Federator Gateway**: remove any file-share-related overrides. Decide on `kafka.authMode` — set to `sasl_ssl` and populate `kafka.oauth.tokenEndpointUrl` if you want Keycloak-authenticated Kafka; deploy the [DPN Authentication Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/07-configure-dpn-authentication-service.md) first if so.
4. **Optional new components**: deploy the DPN Authentication Service and/or the REST Federator Gateway only if you need Keycloak-backed Kafka/UI authentication or a REST-based integration pattern — neither is required to keep an existing Release 1.0.0 deployment running.
5. **File Scan Service**: no action for Azure deployments. AWS deployments can adopt the new GuardDuty-based RUNBOOK in place of building your own.
6. **Observability UIs**: if you front these with your own reverse proxy or bookmark direct URLs, update them to the new HTTPS addresses and expect a Keycloak login in place of HTTP Basic Auth.
