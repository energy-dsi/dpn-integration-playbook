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
- [OpenSearch Dashboard](#opensearch-dashboard)
- [DPN Observability UIs](#dpn-observability-uis)
- [DPN Internal DNS Configuration](#dpn-internal-dns-configuration)
- [Upgrade Checklist](#upgrade-checklist)

---

## New Components

Three components are entirely new in this release — every configuration item below is **Added**, not a change to something that existed in Release 1.0.0. Each ships its own image versioned independently of the DPN platform's `2.0.0` release number, starting at its own `1.0.0`.

### DPN Authentication Service (Keycloak)

New shared OAuth2/OIDC Identity Provider. See [Configure DPN Authentication Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/02-configure-dpn-authentication-service.md).


### DPN REST Federator Gateway

New synchronous, HTTPS-based alternative to the gRPC Federator Gateway, in the new repository `dpn-rest-federator-gateway`. See [Configure DPN REST Federator Gateway](../03-dpn-application-deployment/azure-ado-beta/02-configuration/06-configure-dpn-rest-federator-gateway.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `DSI DPN REST Producer` endpoint (`https://producer-rest01.dpn01.dsipreprod1.neso.energy`) | New pdev DSM endpoint for REST-based DPN-to-DPN data sharing, alongside the existing gRPC producer endpoint — see [Step1: DSI DSM Endpoint Configuration](../03-dpn-application-deployment/azure-ado-beta/02-configuration/00-common-dpn-configuration.md#step1-dsi-dsm-endpoint-configuration) |
| Action required | Firewall rules ([Step5: Network and Ports Configuration](../03-dpn-application-deployment/azure-ado-beta/02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration)) | Participants deploying the REST Federator Gateway must open an outbound/bi-directional rule for `producer-rest01.dpn01.dsi(xxx).neso.energy` on TCP 443, in addition to the existing gRPC producer rule — the REST endpoint uses HTTP/1.1 and is compatible with a Layer 7 load balancer, unlike the gRPC endpoint |

### DPN Portal (Unified UI)

New single landing page for every DPN component UI, in `dpn-health-monitoring-service`'s `charts/dpn-portal`. Published as `ghcr.io/energy-dsi/dpn-portal:1.0.0`, its first release — see [DPN Internal DNS Configuration](#dpn-internal-dns-configuration) below for how its UI links are configured, and the [GHCR upgrade checklist](#upgrade-checklist) for the image reference.

---

## DPN Vault Service

See [Configure DPN Vault Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md).

| Change | Item | Details |
|--------|------|---------|
| Added | `vault-approle-setup-cd.yaml` pipeline | New 4th pipeline — provisions a scoped AppRole identity (policy + role + `role_id`/`secret_id`) for the Certificate Manager. Not a generic per-component pipeline: the Federator Gateway is provisioned by running that repository's own `vault/setup-approle.sh` manually, and the REST Federator Gateway has no policy file or setup script yet at all |
| Added | `VAULT-APPROLE-SECRET-ID` Key Vault secret | Output of the new pipeline; 355-day expiry, requires periodic re-run to rotate |
| Modified | `storeRootTokenInAkv` (in `vault-https-cd`) | Still required — the bundle-load pipeline always needs the root token — but no longer the *only* credential path for downstream components |
| Added | Certificate Bootstrapping and Edge Certificates documentation | New section in [DPN Vault Service Installation Process](../03-dpn-application-deployment/azure-ado-beta/03-installation/01-dpn-vault-installation-process.md#certificate-bootstrapping-and-edge-certificates) — ties the Federator bootstrap certificate flow to the existing Step 3C bundle-load pipeline, and adds a placeholder for organisations fronting DPN with an edge proxy: request the long-lived Edge component certificate with a server sign certificate CSR at a **60-day TTL**, reinstated manually at the edge on every renewal (no auto-renew, unlike the Federator bootstrap certificate) |

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
| Added | `kafkaSrc.oauth.*` / `kafkaTarget.oauth.*` (`clientId`, `jwksUrl`, `tokenEndpointUrl`, `expectedAudience`, `expectedIssuer`, `adminUser`) | Per-broker Keycloak `OAUTHBEARER` settings used for Oauth Authentication of DPN Federator Gateway components i.e. Redis, Kafka |
| Added | `kafkaSrc.tls.*` / `kafkaTarget.tls.*` (`keystoreLocation`, `keystoreType`, `truststoreLocation`, `truststoreType`, `keyPassword`, `clientAuth`) | Per-broker TLS material configuration |
| Added | `kafka.authMode` (`sasl_ssl`\|`ssl`\|`plaintext`) | Single value reconfiguring all Kafka listeners; `sasl_ssl` is the production default, requiring the `kafkaSrc`/`kafkaTarget` OAuth settings above |
| Removed | `kafkaTopicCreator`, `kafkaTopicPopulator` chart sections | Demo/test-data jobs removed entirely from the chart and templates |
| Added | `kafkaUI.oauth.clientId`, `kafkaUI.tls.enabled`, `kafkaUI.oidcRbac.enabled`, `.browserHost`, `.keycloakBaseUrl`, `.keycloakRealm`, `.clusterNames` | Native Keycloak OIDC login and RBAC for Kafka UI (`dpnadmin` → full access, `dpnreader` → view-only) — this configuration lives in **this repository's** `charts/dpn-platform`, not in DPN Monitoring Services |
| Added | `federatorClient.auth.enabled`, `.issuerUrl`, `.audience`, `.adminRole`, `.readerRole`, `.headerName`, `.headerScheme` | Keycloak-gated HTTPS scaffolding for the Federator Client JobRunr dashboard (`:8085`), shipped **disabled by default** in this release — enable once ready rather than waiting for a future release |
| Added | `otel.tls.enabled` (default `true`), `otel.collector.host`/`.port` | TLS to the OTel Collector, plus `OTEL_EXPORTER_OTLP_PROTOCOL: "http/protobuf"` |
| Modified | `certificate-manager-secrets` contents | Now carries either the AppRole `secret-id` or the root token, instead of always the root token |
| Added | `redis.tls.enabled` (default `true`), `redis.truststore.path` | Redis is now TLS-only (server-auth) by default in every environment, reusing the existing `dpn-tls` certificate — see [Step3e](../03-dpn-application-deployment/azure-ado-beta/02-configuration/05-configure-dpn-federator-gateway.md#step3e-configure-redis-security). Health probes moved from a `redis-cli ping` exec check to a `tcpSocket` check |

---

## DPN File Scan Service

See [Configure DPN File Scan Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/08-configure-dpn-file-scan-service.md) (Azure) and [Configure DPN File Scan Service](../03-dpn-application-deployment/aws-gha-beta/02-configuration/08-configure-dpn-file-scan-service.md) (AWS).

`CLOUD_PROVIDER_TYPE` (`env.cloudprovidertype` in the Helm chart) selects which listener/storage code path the service starts with. The application (`app/main.py`) recognises exactly three values, case-sensitive:

| `CLOUD_PROVIDER_TYPE` value | Cloud | Listener started |
|---|---|---|
| `AZURE` | Azure | Azure Service Bus listener (`app/providers/azure/listener.py`) — the only value currently wired into the Helm chart's `values-*.yaml` |
| `AWS` | AWS | AWS SQS listener (`app/providers/aws/listener.py`) — application code only, not yet set by any chart values file |
| `GCP` | GCP | GCP processor (`app/providers/gcp/processor.py`) — application code only, not yet set by any chart values file |

Any other value (including `S3`, which is not a recognised provider type — it names the AWS storage service the AWS path talks to, not the provider itself) raises `Unsupported cloud provider` and the service fails to start.

| Change | Item | Details |
|--------|------|---------|
| Added (application code only — **not yet wired into the Helm chart**) | `CLOUD_PROVIDER_TYPE=AWS` | Selects the AWS code path in the service — see the cloud provider type table above |
| Added (application code only — **not yet wired into the Helm chart**) | `AWS_REGION`, `S3_BUCKET_INBOUND`, `S3_BUCKET_OUTBOUND`, `SQS_QUEUE`, `SNS_TOPIC`, `S3_BUCKET_QUARANTINE`, `SQS_ENDPOINT`, `SNS_ENDPOINT` | AWS-specific configuration read by `app/config/settings.py` and `app/providers/aws/*.py`, parallel to the existing Azure settings |
| Added | `env.otelExporterCertificate`, `env.truststorePath`, `env.otelTlsSecretName` (default `dpn-tls`), `FILESCAN-OTEL-TRUSTSTORE` Key Vault secret | TLS to the OTel Collector, mounted via a new `dpn-tls` secret volume |
| Modified | `OTEL_ENDPOINT` → `OTEL_EXPORTER_OTLP_ENDPOINT` | Renamed; `env.otelExporterInsecure` removed as part of the same change |

---

## OpenSearch Dashboard

OpenSearch itself is unchanged in this release — it has been running since Release 1.0.0. What changed is the **content** of the DPN Pipeline Monitoring dashboard: a set of defects in the shipped saved objects (`config/opensearch/dashboard-provisioning/log-status-dashboard.ndjson`) have been fixed. See [OpenSearch Dashboard Operations](../05-dpn-user-interfaces/05-opensearch-dashboard-ui-operations.md) for the dashboard's normal end-user operation.

| Change | Item | Details |
|--------|------|---------|
| Fixed | `log-status-dashboard.ndjson` saved objects (index-patterns, visualizations, searches, dashboards) | Defect fixes only — no new panels, no schema/index-template change, no OpenSearch or OpenSearch Dashboards version bump |

### Why no container image change is involved

The dashboard is not baked into the OpenSearch Dashboards image or any Helm chart values — it is loaded at runtime as OpenSearch Dashboards **saved objects**, provisioned by a one-shot Kubernetes `Job` (`dpn-dashboard-init`) that `curl`s the saved-objects import API. Applying this fix to an already-running Release 1.0.0 environment is therefore **not** a `helm upgrade` / pod restart / image pull — it is a re-run of that provisioning Job against the already-running OpenSearch Dashboards service, sourced from the corrected `.ndjson` file.

### Steps to apply the fix via CI/CD (recommended path)

Both CI/CD systems provision the dashboard as one stage of the full observability stack pipeline — there is currently no standalone "OpenSearch dashboard only" pipeline. Running either path below re-applies the corrected saved objects to the already-running containers without touching any other component's image or configuration, because every other stage is idempotent against unchanged inputs.

**Azure DevOps** — run the `monitoring-master-cd` pipeline (`.pipelines/azure-pipelines/cd-pipelines/monitoring-master-cd.yaml`, manual trigger only):

1. From the Azure DevOps portal, select **Run pipeline** on `monitoring-master-cd`.
2. Choose the parameters for the target environment: `ServiceConnection`, `environment` (`dev`/`devtest`/`test`/`pdev`/`ptest`/`puat`), `cluster` (`dpn01`/`dpn02`), `approval_group`.
3. Approve the run at the approval gate (owned by the selected `approval_group`).
4. The `opensearch-cd.yaml` stage will:
   - Refresh the `dpn-dashboard-provisioning-files` ConfigMap from the corrected `log-status-dashboard.ndjson`.
   - Delete and recreate the `dpn-dashboard-init` Job (Jobs are immutable once run).
   - Wait for the Job to reach `condition=complete` and print its logs.
5. Confirm success in the pipeline logs — the Job's own output lists the dashboard URLs it re-imported (`/app/dashboards#/view/dpn-dashboard-pipeline-monitoring`, `/app/dashboards#/view/dpn2-dashboard`).

**GitHub Actions** — run the `DPN Health Monitoring` workflow (`dpn-health-monitoring-azure-cd-install.yml`, `workflow_dispatch`):

1. From the GitHub Actions tab, select **Run workflow** on `DPN Health Monitoring`.
2. Choose `environment` (`dev`/`test`), `cluster` (`dpn01`/`dpn02`), and `imageTag`.
3. The reusable `DPN CD - OpenSearch` workflow (`dpn-cd-opensearch.yml`) runs the same ConfigMap-refresh / Job-recreate steps as the Azure DevOps path above.

### What happens to existing dashboard state

The provisioning script deletes the previous versions of every DPN saved object **by ID** before re-importing with `overwrite=true`, so re-running it against a live environment always leaves a clean copy — no manual cleanup is required. Any ad hoc changes a user made directly in OpenSearch Dashboards to these specific saved objects (rather than through this pipeline) will be overwritten by the fixed version.

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

---

## DPN Internal DNS Configuration

New in this release: a consistent internal domain naming strategy for every DPN user interface, based on Kubernetes Service DNS (`<service>.<namespace>.svc.cluster.local`) rather than per-UI ingress hostnames or IP addresses, configured centrally through the DPN Portal (Unified UI) service.

| Change | Item | Details |
|--------|------|---------|
| Added | DPN internal DNS naming reference table, one row per UI component | See [Step6: DPN Internal Domain Naming (DNS) Configuration](../03-dpn-application-deployment/azure-ado-beta/02-configuration/00-common-dpn-configuration.md#step6-dpn-internal-domain-naming-dns-configuration) for the full component-by-component DNS table and required client-side DNS setup |
| Added | Guidance for organisations wanting to use their own corporate DNS instead of the `*.svc.cluster.local` names | Same section — covers the certificate SAN, `externalUrl`, and Keycloak redirect URI changes required; this is not a DNS-only change |

---

## Upgrade Checklist

For an organisation moving from Release 1.0.0:

1. **Vault**: no mandatory action — root token continues to work. `vault.uri`, `vault.pkiMount`, and `vault.secretPath` are unchanged from Release 1.0.0. Optionally migrate to AppRole and switch `vault.authentication`/`vaultConfig.authMethod` to `APPROLE` (a `KUBERNETES` option also now exists): run `vault-approle-setup-cd` for the Certificate Manager, or run the Federator Gateway's own `vault/setup-approle.sh` manually (no pipeline exists for it yet) — see [Configure DPN Vault Service, Step 3D](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md#step-3d-configure-approle-authentication-recommended).
2. **Certificate Manager**: remove any `fileShare.*`/`certDest.*`/`mtls.*` overrides, and any `secrets.oauth2ClientSecret` override, from your `values-<env>.yaml` — they no longer exist in the chart. The `azure-fileshare-secret` and its PV/PVC can be decommissioned once you've confirmed the new deployment is healthy.
3. **Federator Gateway**: remove any file-share-related overrides once you've moved fully to Vault (`vaultConfig.mountCertFileShare` defaults to `true` for backward compatibility — set it to `false` explicitly when ready). Decide on `kafka.authMode` — set to `sasl_ssl` and populate the new per-broker `kafkaSrc.oauth.*`/`kafkaTarget.oauth.*` and `kafkaSrc.tls.*`/`kafkaTarget.tls.*` settings if you want Keycloak-authenticated Kafka; deploy the [DPN Authentication Service](../03-dpn-application-deployment/azure-ado-beta/02-configuration/02-configure-dpn-authentication-service.md) first if so as it has a dependency.
4. **New components**: deploy the DPN Authentication Service and/or the REST Federator Gateway only if you need a REST-based integration pattern
5. **File Scan Service**: no action for Azure deployments. The AWS/GuardDuty code path exists is added in the application and to be deployed via GitHub Actions in ADO
6. **OpenSearch Dashboard**: no `helm upgrade` needed — re-run the CI/CD pipeline (`monitoring-master-cd` on Azure DevOps, or `DPN Health Monitoring` on GitHub Actions) for your environment/cluster to refresh the dashboard-provisioning ConfigMap and re-run the `dpn-dashboard-init` Job against the already-running OpenSearch Dashboards containers — see [OpenSearch Dashboard](#opensearch-dashboard) above.
7. **Observability UIs**: New HTTPS addresses and a Keycloak login in place of HTTP Basic Auth.
8. **Internal DNS**: publish `dpn-observability.ns-dpn-health-01.svc.cluster.local` and `dpn-keycloak-service-lb.ns-dpn-01.svc.cluster.local` in your VNet/corporate DNS, resolving to their static internal Load Balancer IPs, before rolling out the DPN Portal or any Keycloak-fronted UI — see [Step6: DPN Internal Domain Naming (DNS) Configuration](../03-dpn-application-deployment/azure-ado-beta/02-configuration/00-common-dpn-configuration.md#step6-dpn-internal-domain-naming-dns-configuration). If you plan to use your own corporate hostnames instead, follow the certificate/`externalUrl`/Keycloak redirect URI steps in that section rather than only adding a DNS record.
9. **REST Federator Gateway firewall rule**: if deploying the REST Federator Gateway, open the new `producer-rest01.dpn01.dsi(xxx).neso.energy` endpoint on TCP 443 in addition to the existing gRPC producer rule — see [Step5: Network and Ports Configuration](../03-dpn-application-deployment/azure-ado-beta/02-configuration/00-common-dpn-configuration.md#step5-network-and-ports-configuration).

### Upgrading a GHCR-based deployment from 1.0.0 to 2.0.0

Participants who deployed Release 1.0.0 through GHCR, they need to upgrade by pulling the newer images from `ghcr.io/energy-dsi/...` and re-running `helm upgrade` with the updated chart values from this release. This does **not** apply to the DPN Authentication Service or the REST Federator Gateway, both of which are to be deployed first time with version 1.0.0 only.

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
   | Certificate Manager | `ghcr.io/energy-dsi/dpn-federator-certificate-manager` | `2.0.0` |
   | File Scan Service | `ghcr.io/energy-dsi/dpn-file-scan-service` | `2.0.0` |
   | Data Pipelines (Airflow) | `ghcr.io/energy-dsi/dpn-airflow` | `2.0.0` |

3. **Update chart values for your environment** (`values-<env>.yaml` under each repository's `.pipelines/github-actions-pipelines/.../charts/**`) with the confirmed image tags from step 2, and apply the configuration changes documented in the component sections above (Vault AppRole settings, Kafka OAuth/TLS blocks, Redis TLS, Observability UI URLs, etc.) before upgrading.

4. **Roll out with Helm**, one component at a time, verifying health before moving to the next:

   ```bash
   helm upgrade dpn-federator-gateway ./charts/dpn-platform \
     -f charts/dpn-platform/values-<env>.yaml \
     --namespace <your-namespace>
   ```

   Repeat per component (Certificate Manager, Vault, File Scan Service, Data Pipelines, Observability stack), following each component's own configuration guide linked above for the full set of values to change.

5. **Verify** each component comes up healthy against the new images and Vault/Keycloak configuration before decommissioning any Release 1.0.0 resources (file shares, PVCs, old secrets) called out in steps 1–3.
