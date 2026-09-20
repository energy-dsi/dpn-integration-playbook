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

New shared OAuth2/OIDC Identity Provider. See [Configure DPN Authentication Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/02-configure-dpn-authentication-service.md).


### DPN REST Federator Gateway

New synchronous, HTTPS-based alternative to the gRPC Federator Gateway, in the new repository `dpn-rest-federator-gateway`. See [Configure DPN REST Federator Gateway](../03-dpn-application-deployment/azure-ado-beta/02-configuration/06-configure-dpn-rest-federator-gateway.md).

> **Note:** both new components (`dpn-authentication-service` and `dpn-rest-federator-gateway`) currently ship only through the ACR/Azure DevOps pipeline path — neither repository has a GitHub Actions / GHCR pipeline yet, so they are not part of the GHCR image list in the [Upgrade Checklist](#upgrade-checklist) below.

---

## DPN Vault Service

See [Configure DPN Vault Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `vault-approle-setup-cd.yaml` pipeline | New 4th pipeline — provisions a scoped AppRole identity (policy + role + `role_id`/`secret_id`) for the Certificate Manager. Not a generic per-component pipeline: the Federator Gateway is provisioned by running that repository's own `vault/setup-approle.sh` manually, and the REST Federator Gateway has no policy file or setup script yet at all |
| Added | `VAULT-APPROLE-SECRET-ID` Key Vault secret | Output of the new pipeline; 355-day expiry, requires periodic re-run to rotate |
| Modified | `storeRootTokenInAkv` (in `vault-https-cd`) | Still required — the bundle-load pipeline always needs the root token — but no longer the *only* credential path for downstream components |

---

## DPN Certificate Manager

See [Configure DPN Certificate Manager](../03-dpn-application-deployment/azure-ado-beta/02-configuration/04-configure-dpn-certificate-manager.md).

| Change | Item | Details |
|--------|------|---------|
| Removed | `fileShare.storageAccount`, `fileShare.shareName`, `fileShare.secretName` | Shared Azure SMB file share eliminated — the chart no longer creates a PV/PVC |
| Removed | `certDest.path`, `certDest.keystoreFile`, `certDest.truststoreFile`, `certDest.keystoreAlias` | No P12 files are written to disk any more |
| Removed | `mtls.keystorePath`, `mtls.truststorePath`, `mtls.keystoreType` | Superseded by in-memory keystore construction |
| Removed | `azure-fileshare-secret` prerequisite | No longer needed — nothing mounts the file share |
| Modified | `vault.authentication` (now `TOKEN`\|`KUBERNETES`\|`APPROLE`) | `vault.uri`, `vault.pkiMount`, and `vault.secretPath` already existed in Release 1.0.0 — the only genuinely new part is the `APPROLE` value (now the chart's own default) plus a third, previously-undocumented `KUBERNETES` option |
| Added | `vault.appRole.roleId`, `vault.appRole.mountPath` | AppRole identity configuration |
| Added | `certIdent.keystoreAlias` | Alias for the in-memory keystore entry (replaces `certDest.keystoreAlias`) |
| Added | `VAULT-APPROLE-SECRET-ID` → `vaultAppRoleSecretId` | New Key Vault secret / Kubernetes secret key, alternative to `VAULT-TOKEN` |
| Added | `existingSecret.name`, `vaultTruststore.secretName` | Explicit Key Vault / truststore secret wiring |
| Added | `otel.env.OTEL_TRUSTSTORE_LOCATION` | Path to the OTel exporter truststore (`/app/truststore/truststore.jks`) |
| Modified | `VAULT-TOKEN` → `vaultToken` (Kubernetes secret key) | Kept for backward compatibility; only used when `vault.authentication: TOKEN` |
| Removed | `secrets.mtlsKeystorePassword`, `mtlsTruststorePassword`, `certDestKeystorePassword`, `certDestTruststorePassword` | No longer needed once P12 files are no longer written to disk |
| Removed | `secrets.oauth2ClientSecret` | Dead OAuth2 code path removed — unrelated to the file-share change |
| Removed | `AZURE-STORAGE-ACCOUNT-NAME`, `AZURE-STORAGE-ACCOUNT-KEY` (in `secretproviderclass.yaml`) | No longer synced from Key Vault now that the file share is gone; `VAULT-TRUSTSTORE-PASSWORD` is now sourced from the shared `tls-auth-secret` instead of its own Key Vault re-sync |
| Modified | `cert.subject.altNames` | Must now also cover the REST Federator Gateway's endpoint (e.g. `producer-rest01...`) if that component is deployed alongside the gRPC Federator |

---

## DPN Federator Gateway

See [Configure DPN Federator Gateway](../03-dpn-application-deployment/azure-ado-beta/02-configuration/05-configure-dpn-federator-gateway.md).

| Change | Item | Details |
|--------|------|---------|
| Removed | `pvc-dpn-certs-fileshare` shared file share PVC | No longer mounted — certificate material is read from Vault directly |
| Added | `vaultConfig.tlsEnabled`, `vaultConfig.tlsBasePath`, `vaultConfig.tlsKeystoreAlias` | In-memory TLS material construction |
| Added | `vaultConfig.authMethod` (`approle`\|`token`, default `approle`), `vaultConfig.appRole.roleId`, `.mountPath`, `.useSecretIdRef`, `.secretIdSecretName`, `.secretIdSecretKey`, `.renewalIntervalSecs` | Vault authentication — AppRole is the recommended and default option |
| Added | `vaultConfig.mountCertFileShare` (default **`true`**) | Backward-compatibility toggle — the file share is **not** removed by default in this chart (unlike the Certificate Manager, where it is fully gone); set to `false` only once all TLS material is confirmed sourced from Vault |
| Added | `kafkaSrc.oauth.*` / `kafkaTarget.oauth.*` (`clientId`, `jwksUrl`, `tokenEndpointUrl`, `expectedAudience`, `expectedIssuer`, `adminUser`) | Per-broker Keycloak `OAUTHBEARER` settings — six keys each for the source and target Kafka brokers, not a single flat `kafka.oauth.tokenEndpointUrl` |
| Added | `kafkaSrc.tls.*` / `kafkaTarget.tls.*` (`keystoreLocation`, `keystoreType`, `truststoreLocation`, `truststoreType`, `keyPassword`, `clientAuth`) | Per-broker TLS material configuration |
| Added | `kafka.authMode` (`sasl_ssl`\|`ssl`\|`plaintext`) | Single value reconfiguring all Kafka listeners; `sasl_ssl` is the production default, requiring the `kafkaSrc`/`kafkaTarget` OAuth settings above |
| Removed | `kafkaTopicCreator`, `kafkaTopicPopulator` chart sections | Demo/test-data jobs removed entirely from the chart and templates |
| Added | `kafkaUI.oauth.clientId`, `kafkaUI.tls.enabled`, `kafkaUI.oidcRbac.enabled`, `.browserHost`, `.keycloakBaseUrl`, `.keycloakRealm`, `.clusterNames` | Native Keycloak OIDC login and RBAC for Kafka UI (`dpnadmin` → full access, `dpnreader` → view-only) — this configuration lives in **this repository's** `charts/dpn-platform`, not in DPN Monitoring Services |
| Added | `federatorClient.auth.enabled`, `.issuerUrl`, `.audience`, `.adminRole`, `.readerRole`, `.headerName`, `.headerScheme` | Keycloak-gated HTTPS scaffolding for the Federator Client JobRunr dashboard (`:8085`), shipped **disabled by default** in this release — enable once ready rather than waiting for a future release |
| Added | `otel.tls.enabled` (default `true`), `otel.collector.host`/`.port` | TLS to the OTel Collector, plus `OTEL_EXPORTER_OTLP_PROTOCOL: "http/protobuf"` |
| Modified | `certificate-manager-secrets` contents | Now carries either the AppRole `secret-id` or the root token, instead of always the root token |
| Added | `redis.tls.enabled` (default `true`), `redis.truststore.path` | Redis is now TLS-only (server-auth) by default in every environment, reusing the existing `dpn-tls` certificate — see [Step3e](../03-dpn-application-deployment/azure-ado-beta/02-configuration/05-configure-dpn-federator-gateway.md#step3e-configure-redis-security). Health probes moved from a `redis-cli ping` exec check to a `tcpSocket` check |

> `redis.username`/`redis.password` remain unchanged, blank placeholders in both Release 1.0.0 and 2.0.0 — Redis ACL authentication was never enabled in either release; there is nothing to remove here.
>
> **Note** the REST Federator Gateway uses its own separate Redis cache (`dpn-redis`) and it has no TLS yet. Authenticated Redis is to be added in a future release.

---

## DPN File Scan Service

See [Configure DPN File Scan Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/08-configure-dpn-file-scan-service.md) (Azure) and [Configure DPN File Scan Service](../03-dpn-application-deployment/aws-gha-beta/02-configuration/08-configure-dpn-file-scan-service.md) (AWS).

| Change | Item | Details |
|--------|------|---------|
| Added (application code only — **not yet wired into the Helm chart**) | `CLOUD_PROVIDER_TYPE=S3` | Selects the AWS code path in the service |
| Added (application code only — **not yet wired into the Helm chart**) | `AWS_REGION`, `S3_BUCKET_INBOUND`, `S3_BUCKET_OUTBOUND`, `SQS_QUEUE`, `SNS_TOPIC`, `S3_BUCKET_QUARANTINE`, `SQS_ENDPOINT`, `SNS_ENDPOINT` | AWS-specific configuration read by `app/config/settings.py` and `app/providers/aws/*.py`, parallel to the existing Azure settings |
| Added | `env.otelExporterCertificate`, `env.truststorePath`, `env.otelTlsSecretName` (default `dpn-tls`), `FILESCAN-OTEL-TRUSTSTORE` Key Vault secret | TLS to the OTel Collector, mounted via a new `dpn-tls` secret volume |
| Modified | `OTEL_ENDPOINT` → `OTEL_EXPORTER_OTLP_ENDPOINT` | Renamed; `env.otelExporterInsecure` removed as part of the same change |

> **Verification note:** every `values-*.yaml` in `charts/file-scan-service` currently sets `env.cloudprovidertype: "AZURE"`, and there is no `values-aws-*.yaml`, no `aws-gha-beta` pipeline folder, and no IRSA ServiceAccount annotation anywhere in the `dpn-file-scan-service` repository as of this validation. The AWS/GuardDuty environment variables above exist only in application code, not in the Helm chart or CD pipeline — **the AWS deployment path described in [Configure DPN File Scan Service (AWS)](../../03-dpn-application-deployment/aws-gha-beta/02-configuration/08-configure-dpn-file-scan-service.md) is not yet chart-deployable from this repository's current `release-internal/2.0.0` branch.** Confirm with the File Scan Service team whether the AWS chart/pipeline work is tracked separately before advertising it as available in this release.
>
> No changes to the existing Azure Defender for Storage configuration.

---

## DPN Observability UIs

See [DPN Portal Operations](../05-dpn-user-interfaces/08-dpn-portal-ui-operations.md), [Kafka UI Operations](../05-dpn-user-interfaces/04-kafka-ui-operations.md), [Kafka Health UI Operations](../05-dpn-user-interfaces/07-kafka-health-ui-operations.md), [OpenSearch Dashboard Operations](../05-dpn-user-interfaces/05-opensearch-dashboard-ui-operations.md), and [Jaeger Dashboard Operations](../05-dpn-user-interfaces/06-jaeger-dashboard-ui-operations.md).

| Change | Item | Details |
|--------|------|---------|
| Added | DPN Portal | New single landing page, organised into cards (Users & Roles, Data/Store, Gateway, Data/Pipeline, Security/Services, Health/Monitoring Service) each linking one or more component UIs |
| Added | `dpnadmin` / `dpnreader` Keycloak groups | Control card visibility on the DPN Portal — the "Users & Roles" card (Keycloak Console) is `dpnadmin`-only; every other card is visible to both groups today |
| Modified | Kafka Health UI, OpenSearch Dashboards, Jaeger access URL | Changed from `http://<host>:<port>` with HTTP Basic Auth (nginx) to `https://dpn-observability...:<port>` gated by Keycloak SSO via an `oauth2-proxy` sidecar |
| Modified | Kafka UI, Apache Airflow authentication | Moved from HTTP Basic Auth (nginx) directly to **native** Keycloak OIDC login (no `oauth2-proxy` hop). Keycloak realm roles map to each application's own RBAC: for Kafka UI this is configured in the **DPN Federator Gateway** repository (`kafkaUI.oidcRbac.*`, see that component's table above), `dpnadmin`/`dpnreader` → full/view-only. For Airflow (`charts/airflow/webserver_config.py`, `AUTH_ROLES_MAPPING`) it is `dpnadmin` → `Op`, `dpnreader` → `Viewer`, and a third role, `dpnoperator` → `DagOperator` |
| Modified | Data pipeline OTLP telemetry endpoint | The `OTEL_EXPORTER_OTLP_INSECURE` value itself is not new — it existed (hardcoded `true`) per-blueprint in Release 1.0.0 (e.g. `dpn-data-pipelines/blueprints/**/charts/values.yaml`, not the Airflow chart). What changed in Release 2.0.0: the value flips to `false`, the endpoint port moves from `:4317` to `:4318`, and the `OTEL_EXPORTER_OTLP_PROTOCOL: grpc` line is removed entirely from those same per-blueprint `values.yaml` files |

> **Note:** the Federator Client JobRunr dashboard (`:8085`) remains plain HTTP by default. Keycloak-gated HTTPS scaffolding (`federatorClient.auth.*`, see the Federator Gateway table above) already ships in this release but is **disabled by default** — set `federatorClient.auth.enabled: true` to turn it on rather than waiting for a future release.

---

## Upgrade Checklist

For an organisation moving from Release 1.0.0:

1. **Vault**: no mandatory action — root token continues to work. `vault.uri`, `vault.pkiMount`, and `vault.secretPath` are unchanged from Release 1.0.0. Optionally migrate to AppRole and switch `vault.authentication`/`vaultConfig.authMethod` to `APPROLE` (a `KUBERNETES` option also now exists): run `vault-approle-setup-cd` for the Certificate Manager, or run the Federator Gateway's own `vault/setup-approle.sh` manually (no pipeline exists for it yet) — see [Configure DPN Vault Service, Step 3D](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended).
2. **Certificate Manager**: remove any `fileShare.*`/`certDest.*`/`mtls.*` overrides, and any `secrets.oauth2ClientSecret` override, from your `values-<env>.yaml` — they no longer exist in the chart. The `azure-fileshare-secret` and its PV/PVC can be decommissioned once you've confirmed the new deployment is healthy.
3. **Federator Gateway**: remove any file-share-related overrides once you've moved fully to Vault (`vaultConfig.mountCertFileShare` defaults to `true` for backward compatibility — set it to `false` explicitly when ready). Decide on `kafka.authMode` — set to `sasl_ssl` and populate the new per-broker `kafkaSrc.oauth.*`/`kafkaTarget.oauth.*` and `kafkaSrc.tls.*`/`kafkaTarget.tls.*` settings if you want Keycloak-authenticated Kafka; deploy the [DPN Authentication Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/02-configure-dpn-authentication-service.md) first if so. `redis.username`/`redis.password` were never populated in either release and need no action; Redis TLS (`redis.tls.enabled`) is on by default and needs no new secret, since it reuses the existing `dpn-tls` certificate. If you relied on the demo `kafkaTopicCreator`/`kafkaTopicPopulator` jobs, recreate that behaviour yourself — they have been removed from the chart.
4. **Optional new components**: deploy the DPN Authentication Service and/or the REST Federator Gateway only if you need Keycloak-backed Kafka/UI authentication or a REST-based integration pattern — neither is required to keep an existing Release 1.0.0 deployment running. Both are currently deployed via the ACR/Azure DevOps pipeline path only; there is no GHCR pipeline for either yet.
5. **File Scan Service**: no action for Azure deployments. The AWS/GuardDuty code path exists in the application but is **not yet available as a deployable Helm chart or CD pipeline** in `dpn-file-scan-service` — confirm current availability with the File Scan Service team before planning an AWS rollout against this release.
6. **Observability UIs**: if you front these with your own reverse proxy or bookmark direct URLs, update them to the new HTTPS addresses and expect a Keycloak login in place of HTTP Basic Auth.

### Upgrading a GHCR-based (GitHub Actions) deployment from 1.0.0 to 2.0.0

Participants who deployed Release 1.0.0 through the `azure-gha-beta`/`aws-gha-beta` (GitHub Actions + GHCR) pipeline path — rather than the ACR/Azure DevOps path — upgrade by pulling the newer images from `ghcr.io/energy-dsi/...` and re-running `helm upgrade` with the updated chart values from this release. This does **not** apply to the DPN Authentication Service or the REST Federator Gateway, both of which are ACR-only today (see step 4 above).

1. **Authenticate to GHCR** on each node/runner that will pull images:

   ```bash
   echo "$GHCR_PAT" | docker login ghcr.io -u <github-username> --password-stdin
   ```

   `GHCR_PAT` needs at least `read:packages` scope against the `energy-dsi` GitHub organisation.

2. **Pull the Release 2.0.0 images.** The Federator Server/Client images carry a fixed `2.0.0` tag; every other component's tag is set at CD-pipeline run time, so confirm the exact tag from that component's GitHub Actions run (or its release notes) before pulling — do not assume `:2.0.0` exists for images other than the two below:

   | Component | Image | Confirmed 2.0.0 tag |
   |---|---|---|
   | Federator Gateway (server) | `ghcr.io/energy-dsi/dpn-federator-server` | `2.0.0` |
   | Federator Gateway (client) | `ghcr.io/energy-dsi/dpn-federator-client` | `2.0.0` |
   | Certificate Manager | `ghcr.io/energy-dsi/dpn-federator-certificate-manager` | set per CD run — check pipeline output |
   | File Scan Service | `ghcr.io/energy-dsi/dpn-file-scan-service` | set per CD run — check pipeline output |
   | Data Pipelines (Airflow) | `ghcr.io/energy-dsi/dpn-airflow` | set per CD run — check pipeline output |

   ```bash
   docker pull ghcr.io/energy-dsi/dpn-federator-server:2.0.0
   docker pull ghcr.io/energy-dsi/dpn-federator-client:2.0.0
   ```

3. **Update chart values for your environment** (`values-<env>.yaml` under each repository's `.pipelines/github-actions-pipelines/.../charts/**`) with the confirmed image tags from step 2, and apply the configuration changes documented in the component sections above (Vault AppRole settings, Kafka OAuth/TLS blocks, Redis TLS, Observability UI URLs, etc.) before upgrading.
4. **Roll out with Helm**, one component at a time, verifying health before moving to the next:

   ```bash
   helm upgrade dpn-federator-gateway ./charts/dpn-platform \
     -f charts/dpn-platform/values-<env>.yaml \
     --namespace <your-namespace>
   ```

   Repeat per component (Certificate Manager, Vault, File Scan Service, Data Pipelines, Observability stack), following each component's own configuration guide linked above for the full set of values to change.
5. **Verify** each component comes up healthy against the new images and Vault/Keycloak configuration before decommissioning any Release 1.0.0 resources (file shares, PVCs, old secrets) called out in steps 1–3.
