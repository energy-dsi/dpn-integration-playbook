# DPN Data Pipeline Configuration

---

## Table of Contents

- [Overview](#overview)
- [Data Pipeline Blueprints](#data-pipeline-blueprints)
- [STEP-01: Set Up a New Data Product (Self-Service)](#step-01-set-up-a-new-data-product-self-service)
- [STEP-02: Set Up Data Consumers](#step-02-set-up-data-consumers)
- [STEP-03: Producer Configuration Reference](#step-03-producer-configuration-reference)
  - [STEP-03a: Producer Configuration For File Based Pathway](#step-03a-producer-configuration-for-file-based-pathway)
  - [STEP-03b: Producer Configuration For Topic Based Pathway](#step-03b-producer-configuration-for-topic-based-pathway)
- [STEP-04: Consumer Configuration Reference](#step-04-consumer-configuration-reference)
  - [STEP-04a: Consumer Configuration For File Based Pathway](#step-04a-consumer-configuration-for-file-based-pathway)
  - [STEP-04b: Consumer Configuration For Topic Based Pathway](#step-04b-consumer-configuration-for-topic-based-pathway)
- [STEP-05: Configure Horizontal Pod Autoscaler (HPA)](#step-05-configure-horizontal-pod-autoscaler-hpa)
- [STEP-06: Configure Scheduling](#step-06-configure-scheduling)
- [STEP-07: Operate a Data Product](#step-07-operate-a-data-product)
- [STEP-08: Configure Secrets](#step-08-configure-secrets)
  - [STEP-08a: Configure Storage Secrets](#step-08a-configure-storage-secrets)
  - [STEP-08b: Configure Kafka Security (SASL/TLS)](#step-08b-configure-kafka-security-sasltls)
  - [STEP-08c: Configure the Image Pull Secret](#step-08c-configure-the-image-pull-secret)
- [STEP-09: Configure DPN Data Store](#step-09-configure-dpn-data-store)
  - [STEP-09a: Storage Blob Configuration](#step-09a-storage-blob-configuration)
  - [STEP-09b: Configure Streaming Service (Kafka)](#step-09b-configure-streaming-service-kafka)
- [Review Notes](#review-notes)

---

## Overview

DPN Data Pipeline moves data products between an organisation's internal storage/Kafka and the shared location read by the Federator Secure Gateway (producer side), and from the Federator's drop location into the organisation's own destination (consumer side). Files and messages are never rewritten: a file lands in the target container under its original name, and a Kafka message is forwarded with metadata headers added.

From release **3.0.0** the data pipeline is a **simplified, single-container design**:

| Aspect | Behaviour |
|--------|-----------|
| Containers per pathway | **One.** A single container per pathway performs the whole pipeline on both the producer and the consumer side. |
| Images | **One generic image per pathway.** Every identifier (product name, container/topic names, organisation, cloud credentials) is supplied as environment variables at container start. A new data product is a new set of environment variables, not a folder copy or a rebuild. |
| Producer creation | Producer data products are **created at runtime through the DPN Self-Service UI**, which launches one Deployment per data product (`dpn-producer-<pathway>-<product_type>`). |
| Consumers | Fixed platform pipelines: exactly **one file extractor and one topic extractor** per platform. They receive every subscribed data product and need no per-product configuration. |
| Scheduling | Every container self-schedules (`SCHEDULER_BACKEND=interval`). No external orchestrator is required. See [STEP-06](#step-06-configure-scheduling). |
| Organisation and cloud | Organisation name and cloud provider are platform-level settings, not chosen per product. |

The four pipeline containers are:

| Side | Pathway | Container | What one cycle does |
|------|---------|-----------|---------------------|
| Producer | file | File adaptor | Lists the source container, copies each new or updated file to the target container under its original name, then publishes one Kafka notification per file. |
| Producer | topic | Topic adaptor | Consumes the source topic, adds metadata headers (`orgName`, `productType`, `processedAt`, `offset` and trace context) and produces to the target topic. |
| Consumer | file | File extractor | Same as the producer file adaptor, but reads the Federator's drop container and writes to the organisation's destination container. |
| Consumer | topic | Topic extractor | Consumes the Federator's drop topic and forwards each message to a per-product target topic resolved from the message headers. |

## Data Pipeline Blueprints

DSI provides one blueprint per pathway and side. Each contains the container source, a Dockerfile and a **reference** Helm chart.

```text
Root-Repository
  └── blueprints
        ├── producer
        │     ├── file
        │     │     └── adaptor    (main.py, Dockerfile, charts/)
        │     └── topic
        │           └── adaptor    (main.py, Dockerfile, charts/)
        └── consumer
              ├── file
              │     └── extractor  (main.py, Dockerfile, charts/)
              └── topic
                    └── extractor  (main.py, Dockerfile, charts/)
```

| Blueprint | Image name (default) | How it is deployed |
|-----------|----------------------|--------------------|
| `producer/file/adaptor` | `dpn-producer-file-adaptor-generic` | Created per data product by the Self-Service UI |
| `producer/topic/adaptor` | `dpn-producer-topic-adaptor-generic` | Created per data product by the Self-Service UI |
| `consumer/file/extractor` | `dpn-consumer-file-extractor` | Helm-deployed once by the CD workflow |
| `consumer/topic/extractor` | `dpn-consumer-topic-extractor` | Helm-deployed once by the CD workflow |

The `values.yaml` files under `blueprints/` **must not** be modified directly. The producer charts exist for manual or reference deployment (for example testing one instance outside the self-service flow); the consumer charts are what the CD workflow installs, with environment values supplied at deploy time.

## STEP-01: Set Up a New Data Product (Self-Service)

A producing organisation creates a data product in the **DPN Self-Service UI**. No blueprint folder is copied and no image is built; the UI launches the generic image for the chosen pathway with the product's environment variables.

The UI is deployed from `service/charts` and is typically placed behind an oauth2-proxy with Keycloak login (see [STEP-07](#step-07-operate-a-data-product) for roles). Organisation name and cloud provider are set once when the UI is deployed (`DPN_ORG_NAME`, `DPN_CLOUD_PROVIDER: azure`) and are inherited by every product.

**Creating a product is a two-step flow:**

1. Open **Create New Data Product** and supply:

   | Field | Description | Rules |
   |-------|-------------|-------|
   | `product_type` | Unique data product identifier (also written as `PRODUCT_NAME` / `productType`) | Lowercase letters, digits and hyphens only. It becomes part of the Kubernetes Deployment name `dpn-producer-<pathway>-<product_type>`, which is capped at 63 characters, so keep it short. |
   | `pipeline_type` | Integration pathway | `file` or `topic` |
   | `schedule_seconds` | Poll interval (file pathway) or consumer window (topic pathway) | 5–3600, default 60 |
   | `execution_mode` | `automatic` runs on schedule; `manual` only runs when **Run Now** is used | default `automatic` |

2. Review the **proposed names** and confirm or override them. Nothing launches until you confirm.

   | Pathway | Proposed name | Default |
   |---------|---------------|---------|
   | file | Source storage container | `{product_type}-stage` |
   | file | Target storage container | `{product_type}-target` |
   | file | Notification topic | `dpn-producer-file-{product_type}-target` |
   | topic | Source topic | `dpn-producer-{product_type}-stage` |
   | topic | Target topic | `dpn-producer-{product_type}-target` |

   The consumer group for the topic pathway is derived from `product_type` automatically.

**Name rules and pre-checks**

- Storage container names are validated against the intersection of the Azure, S3 and GCS rules: 3–63 characters, lowercase letters, digits and single hyphens, starting and ending with a letter or digit — the same rule Azure Blob Storage containers already require on their own.
- Every confirmed container and topic name must be **brand new**. A pre-check against the real storage account and Kafka broker blocks creation if a name already exists. The platform only creates new topics and containers for a product; it never attaches to an existing one.
- Containers and topics are **created automatically** by the pipeline when needed. They no longer have to be pre-created (see [STEP-09](#step-09-configure-dpn-data-store)).

**What gets deployed**

```text
Kubernetes namespace (e.g. ns-dpn-dp-01)
  └── Deployment  dpn-producer-<pathway>-<product_type>     <- one per data product
```

## STEP-02: Set Up Data Consumers

Consumer pipelines are **not** created per product. A consuming organisation deploys the two fixed consumer pipelines once per platform through the CD workflow, using the consumer charts under `blueprints/consumer/{file,topic}/extractor/charts` with environment-specific values.

| Pipeline | Deployment name | Receives | Delivers to |
|----------|-----------------|----------|-------------|
| File | `dpn-consumer-file-extractor` | Files dropped by the Federator client in `srcContainerName` | `targetContainerName`, plus one Kafka notification per file on `targetTopicName` |
| Topic | `dpn-consumer-topic-extractor` | Messages on `srcTopicName` | Topic `dpn-consumer-<org>-<product>-target`, resolved per message |

The consumer topic extractor reads `orgName` and `productType` from each message's headers (stamped by the producer topic adaptor). Messages with missing or invalid metadata are **skipped**; no catch-all topic is created.

> **Note:** The values file can be replicated per environment or DPN deployment (e.g. `values-<env>-dpn01.yaml`). The organisation specifies which values are used in the pipeline configuration described in [Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration).

## STEP-03: Producer Configuration Reference

For a self-service product these variables are generated by the UI (`service/env_builder.py`); the tables below document what each container reads. The same names are used by the reference Helm charts when a producer is deployed manually.

Platform-level values (organisation, cloud account, Kafka, telemetry) are injected into every product automatically and are never typed per product.

### STEP-03a: Producer Configuration For File Based Pathway

**Identity & Image**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Kubernetes namespace | `ns-dpn-dp-01` |
| name | Deployment name (self-service: `dpn-producer-file-<product_type>`) | `producer-file-adaptor-example` |
| cloudProviderType | Cloud provider | `azure` |
| imageRegistry | Registry path images are pulled from — GHCR, same as every other DPN component on this path | `ghcr.io/energy-dsi/dsi` |
| imageName | Image name | `dpn-producer-file-adaptor-generic` |
| imageTag | Image tag | `latest` |
| productType | Data product name | `eq-sample-1` |
| PRODUCT_NAME | Runtime alias of `productType` (same value). Required, no default | `eq-sample-1` |
| orgName | Organisation name. Injected on this pathway but not used to name files | `orga` |

**Storage**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| srcContainerName | Source container the adaptor reads | `eq-sample-1-stage` |
| targetContainerName | Target container files are copied to (original filename kept) | `eq-sample-1-target` |

**Azure Blob Storage**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| storageConnectionSecret | Kubernetes secret holding the Azure Blob Storage connection string(s) for this product — see [STEP-08a](#step-08a-configure-storage-secrets) | `producer-file-dp-secret` |

> **No per-stage Workload Identity/ServiceAccount.** Unlike the old per-schema producer charts, the single-container design authenticates to Blob Storage purely through `storageConnectionSecret`'s connection string — there is no `serviceAccount.*`/Workload Identity path for Blob access on this pathway, mirroring how AWS equally dropped its own per-stage IRSA pattern in the same release (see the note under [STEP-08a](#step-08a-configure-storage-secrets)).

**Kafka**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| bootstrapServer | Kafka bootstrap server | `dpn-kafka-src.ns-dpn-01.svc.cluster.local:9092` |
| targetTopicName | Topic on which one notification per file is published | `dpn-producer-file-eq-sample-1-target` |

Kafka authentication is covered in [STEP-08b](#step-08b-configure-kafka-security-sasltls).

**Scheduling & Scaling**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | See [STEP-06](#step-06-configure-scheduling) | `interval` |
| EXECUTION_MODE | `automatic` or `manual` | `automatic` |
| scheduleInterval | Poll interval in seconds | `60` |
| replicaCount, hpa.* | See [STEP-05](#step-05-configure-horizontal-pod-autoscaler-hpa) | `1` |

**Observability**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SERVICE_NAME | Service name reported to tracing/metrics backends | `dpn data pipeline` |
| SERVICE_VERSION | Service version reported to tracing/metrics backends | `1.0.0` |
| ENVIRONMENT | Environment label on telemetry | `production` |
| OTEL_EXPORTER_OTLP_ENDPOINT | OTel collector endpoint | `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` |
| OTEL_EXPORTER_OTLP_INSECURE | `false` = TLS to the collector (default) | `false` |
| OTEL_OAUTH_DISABLED | `true` skips OAuth to the collector (dev/test only) | `false` |
| HEARTBEAT_INTERVAL_SECONDS | Periodic liveness log interval | `60` |
| STATSD_HOST | StatsD host (leave empty to disable) | `""` |
| STATSD_PORT | StatsD port | `8125` |

> **Note:** `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_INSECURE` must be changed together. Port `4318` with `INSECURE: false` is the supported default; plaintext on port `4317` with `INSECURE: true` is a manual, non-default choice.

### STEP-03b: Producer Configuration For Topic Based Pathway

Identity, Kafka security, scheduling and observability parameters are as in [STEP-03a](#step-03a-producer-configuration-for-file-based-pathway), with these differences. The topic pathway is Kafka-to-Kafka only, so it has **no** `cloudProviderType`, Blob Storage or `storageConnectionSecret` parameters.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| name | Deployment name (self-service: `dpn-producer-topic-<product_type>`) | `producer-topic-adaptor-example` |
| imageName | Image name | `dpn-producer-topic-adaptor-generic` |
| orgName | Organisation name. **Used** to stamp headers | `orga` |
| productType | Product name. **Used** to stamp headers | `eq-sample-1` |
| bootstrapServer | Kafka bootstrap server | `dpn-kafka-src.ns-dpn-01.svc.cluster.local:9092` |
| srcTopicName | Source topic the adaptor consumes | `dpn-producer-eq-sample-1-stage` |
| srcGroupId | Consumer group for the source topic | `producer-topic-adaptor-eq-sample-1` |
| targetTopicName | Target topic produced to. In self-service this is the confirmed value. If left blank on a manual deploy it falls back to `dpn-producer-<org>-<product>-target` with non-alphanumeric characters removed | `dpn-producer-eq-sample-1-target` |
| consumerRetryDelaySecs | Delay before retrying a failed consume | `5` |
| TOPIC_TASK_TIMEOUT_SECS | Length of one consumer window in seconds. Self-service sets this from `schedule_seconds` | `60` |
| producerFlushTimeoutSecs | Upper bound on the per-cycle producer flush, so an undelivered backlog cannot hang the adaptor | `10` |
| statsdPort | StatsD port on this pathway's reference chart | `8125` |

Headers added to every forwarded message: `orgName`, `productType`, `processedAt`, `offset`, plus OpenTelemetry trace context.

## STEP-04: Consumer Configuration Reference

### STEP-04a: Consumer Configuration For File Based Pathway

Chart: `blueprints/consumer/file/extractor/charts`.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Kubernetes namespace | `ns-dpn-dp-01` |
| name | Deployment name | `dpn-consumer-file-extractor` |
| cloudProviderType | Cloud provider | `azure` |
| imageRegistry | Registry path images are pulled from. Set at deploy time | `ghcr.io/energy-dsi/dsi` |
| imageName | Image name | `dpn-consumer-file-extractor` |
| imageTag | Image tag. Set at deploy time | `latest` |
| PRODUCT_NAME | Logical name used in logs/messages | `consumer-file` |
| srcContainerName | Container the Federator client drops files into | `dp-consumer-stage` |
| targetContainerName | Organisation's destination container | `dp-consumer-target` |
| targetTopicName | Topic for one notification per file | `dp-consumer-file-target` |
| bootstrapServer | Kafka bootstrap server | `dpn-kafka-target.ns-dpn-01.svc.cluster.local:9092` |
| scheduleInterval | Poll interval in seconds | `60` |
| storageConnectionSecret | Kubernetes secret holding the Azure Blob Storage connection string(s) for this extractor — see [STEP-08a](#step-08a-configure-storage-secrets) | `consumer-file-dp-secret` |
| FILE_COPY_MAX_WORKERS | Optional. Maximum concurrent file copies (default `8`) | `8` |
| DEBUG_STORAGE_SDK | Optional. `true` enables cloud-SDK HTTP logging for diagnosis | `false` |

Files are copied directly from `srcContainerName` to `targetContainerName` under their original name. Only new or updated files are processed on each cycle.

### STEP-04b: Consumer Configuration For Topic Based Pathway

Chart: `blueprints/consumer/topic/extractor/charts`.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Kubernetes namespace | `ns-dpn-dp-01` |
| name | Deployment name | `dpn-consumer-topic-extractor` |
| imageRegistry | Registry path images are pulled from. Set at deploy time | `ghcr.io/energy-dsi/dsi` |
| imageName | Image name | `dpn-consumer-topic-extractor` |
| imageTag | Image tag. Set at deploy time | `latest` |
| PRODUCT_NAME | Logical name used in logs/messages | `consumer-topic` |
| bootstrapServer | Kafka bootstrap server | `dpn-kafka-target.ns-dpn-01.svc.cluster.local:9092` |
| srcTopicName | Topic the extractor consumes | `dp-consumer-topic-stage` |
| srcGroupId | Consumer group | `consumer-topic-extractor` |
| targetTopicName | **Not used.** Resolved per message as `dpn-consumer-<org>-<product>-target` and created automatically | — |
| TOPIC_TASK_TIMEOUT_SECS | Maximum length of one consume window | `60` |
| DRAIN_IDLE_SECS | A window ends early once the topic has been quiet this long | `15` |
| consumerRetryDelaySecs | Delay before retrying a failed consume | `5` |
| producerFlushTimeoutSecs | Bound on producer flush | `10` |
| scheduleInterval | Interval between windows, in seconds | `60` |
| statsdPort | StatsD port | `8125` |

Scheduling and observability parameters are as in [STEP-03a](#step-03a-producer-configuration-for-file-based-pathway).

> **Naming conventions**
>
> - Product types and storage container names: lowercase letters, digits and hyphens. Product type is enforced by the Self-Service UI; container names are enforced to the cross-cloud rules in [STEP-01](#step-01-set-up-a-new-data-product-self-service).
> - Kafka topic names and consumer group IDs are not restricted by the pipeline to hyphens; prefer hyphens as a convention.
> - Organisation names are abbreviated without spaces. The topic adaptor strips non-alphanumeric characters when it computes a topic name from the organisation or product.

## STEP-05: Configure Horizontal Pod Autoscaler (HPA)

Each producer adaptor and consumer extractor can scale horizontally through the `hpa.*` block, which requires the Kubernetes metrics-server — enabled by default on AKS.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| hpa.enabled | Enables the HPA | `false` |
| hpa.minReplicas | Minimum pod count | `1` |
| hpa.maxReplicas | Maximum pod count | `3` |
| hpa.scaleUp.cpuUtilization | Average CPU utilisation (%) that triggers scale-out | `80` |
| hpa.scaleUp.memoryUtilization | Average memory utilisation (%) that triggers scale-out | `80` |
| hpa.scaleUpBehavior.stabilizationWindowSeconds | Wait before acting on a scale-out signal | `60` |
| hpa.scaleUpBehavior.policies | Scale-out policies | `[{type: Pods, value: 1, periodSeconds: 60}]` |
| hpa.scaleDown.stabilizationWindowSeconds | Wait before acting on a scale-in signal | `300` |
| hpa.scaleDown.policies | Scale-in policies | `[{type: Percent, value: 50, periodSeconds: 60}]` |

> **Note:** **Leave HPA disabled (the default) while `SCHEDULER_BACKEND: interval` is in use**, which is the case for every self-service deployment. With `interval`, each replica runs its own poll loop and work is not partitioned, so scaling beyond one replica risks duplicate processing. HPA is only appropriate once a stage consumes work through a model that partitions it across replicas (Kafka consumer groups on a partitioned topic).

> **Note:** HPA templates are provided in the producer charts. When `hpa.enabled: true`, `replicaCount` only sets the initial count; check `kubectl get hpa` for the live value.

## STEP-06: Configure Scheduling

`utils/scheduler_backend.py` decides **when** a pipeline cycle runs. The backend is selected with `SCHEDULER_BACKEND`:

| Value | Behaviour | Used by |
|-------|-----------|---------|
| `interval` | Self-scheduling loop. The container runs a cycle every `scheduleInterval` seconds. No external orchestrator. | **All self-service producers and the consumer charts (the supported configuration)** |
| `kafka-trigger` | Waits for a matching trigger message on `PIPELINE_CONTROL_TOPIC`, runs one cycle, then reports to `PIPELINE_STATUS_TOPIC`. For orchestrated deployments. | Optional; requires something to publish triggers |
| `standalone` | Runs one cycle and exits. This is the code default when `SCHEDULER_BACKEND` is unset. | Manual testing |

**Execution mode.** Every backend checks `EXECUTION_MODE` before running a cycle:

| EXECUTION_MODE | Behaviour |
|----------------|-----------|
| `automatic` | Scheduled or triggered cycles run. |
| `manual` | Scheduled and triggered cycles are **skipped**. A cycle only runs when forced with `--run-once`, which is what the UI's **Run Now** button does inside the running container. |

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Backend from the table above | `interval` |
| EXECUTION_MODE | `automatic` or `manual` | `automatic` |
| scheduleInterval | Interval in seconds for `interval` | `60` |
| PIPELINE_CONTROL_TOPIC | Trigger topic, `kafka-trigger` only | `dpn-pipeline-control` |
| PIPELINE_STATUS_TOPIC | Status topic, `kafka-trigger` only | `dpn-pipeline-status` |

> **Note:** Do not set `kafka-trigger` unless something publishes to `PIPELINE_CONTROL_TOPIC`. Without a publisher the pod waits indefinitely and `automatic` mode never runs a cycle. The consumer charts were deliberately moved to `interval` for this reason. This also replaces the Airflow-orchestrated scheduling previously documented here — Airflow is no longer part of this component's supported configuration.

## STEP-07: Operate a Data Product

Once created, a data product is operated from the Self-Service UI. The same actions are available as HTTP endpoints.

| Action | Effect | Role required |
|--------|--------|---------------|
| Start | Creates the data product's Deployment | `dpnadmin` or `dpnoperator` |
| Stop | Removes the Deployment; the product definition is kept | `dpnadmin` or `dpnoperator` |
| Run Now | Forces one cycle immediately (`--run-once`) | `dpnadmin` or `dpnoperator` |
| Logs / run history | View container logs and recent runs | any, including `dpnreader` |
| Delete | Removes the Deployment **and** its Kafka topic(s) and storage container(s) | `dpnadmin` only |

Run Now also applies to the two consumer pipelines. Delete on a consumer removes its Deployment only.

> **Warning:** Delete tears down the product's Kafka topics and storage containers. Treat it as irreversible.

Access control is enforced server-side behind the oauth2-proxy (`dpnadmin`, `dpnoperator`, `dpnreader`) — the same Keycloak-backed `oauth2-proxy` pattern already used elsewhere on this path (see [Configure DPN Health Monitoring Service](03-configure-dpn-health-monitoring-service.md)). Requests that bypass the proxy are rejected when the chart is installed with the proxy enabled. Before enabling the proxy, the Keycloak client used for login must have Standard flow enabled and the UI's `/oauth2/callback` registered as a redirect URI.

The product registry is a JSON file on a persistent volume, mirrored to cloud storage on each write and restored automatically if the local file is missing.

## STEP-08: Configure Secrets

DSI Data Pipeline uses Kubernetes secrets by design, as this is a Bring-Your-Own (BYO) component. Storage credentials and Kafka authentication material are separate concerns.

### STEP-08a: Configure Storage Secrets

Storage credentials are required only for pathways that use Blob Storage (the **file** pathway). The topic pathway needs none.

> - Platform/producer secret: `producer-file-dp-secret` (believed to also be the Self-Service chart's own `platformStorageSecretName` **default** on Azure, by analogy with AWS needing to override it to `aws-access-secret` — this specific default was not independently verified against the chart's `values.yaml`, so confirm before relying on it)
> - Consumer secret: `consumer-file-dp-secret`, referenced by the file extractor chart's `storageConnectionSecret`

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Blob Storage connection string for the source container |
| TARGET_CONNECTION_STRING | Blob Storage connection string for the target container |

```bash
kubectl create secret generic producer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>

kubectl create secret generic consumer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```

The **mapper** stage and its `MAPPER_CONNECTION_STRING` key no longer exist — the single-container design has only a source and a target per pathway/side.

The same `producer-file-dp-secret` may serve the Self-Service UI and the producer pods it creates when one storage account hosts all containers. Use a separate secret only when producer and consumer containers sit in different storage accounts.

> **Note:** There is no Workload Identity/ServiceAccount path for this component's Blob Storage access — unlike the AWS path, which documents IRSA as an optional manual hardening step on top of its own `aws-access-secret`, this chart has no equivalent ServiceAccount annotation for Blob Storage; `storageConnectionSecret` is the only supported mechanism today.

> **Note:** Secret references are optional in the charts so an install does not fail outright, but a container refuses to start without valid values. Create the secrets **before** deploying.

### STEP-08b: Configure Kafka Security (SASL/TLS)

Every container that connects to Kafka authenticates using SASL over TLS with OAuth2 client credentials issued by Keycloak. The client configuration is built in a single place (`utils/kafka_security.py`) from these values. **If the variables are unset, the code defaults to `SASL_SSL` + `OAUTHBEARER`; it never silently downgrades to plaintext.**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| KAFKA_SECURITY_PROTOCOL | Transport security | `SASL_SSL` (`SSL` for mutual TLS) |
| KAFKA_SASL_MECHANISM | SASL mechanism | `OAUTHBEARER` |
| KAFKA_OAUTH_CLIENT_ID | Keycloak service-account client | `dpn-service-client` |
| KAFKA_OAUTH_TOKEN_ENDPOINT_URL | Keycloak token endpoint | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| kafkaTlsSecretName | Secret providing `truststore.jks` (and `keystore.jks` for mutual TLS), mounted into the pod | `dpn-tls` |
| kafkaOauthSecretName | Secret providing the Keycloak client secret (`KC_SERVICE_CLIENT_SECRET`) | `dpn-keycloak-secrets` |
| tlsAuthSecretName | Secret providing `TRUSTSTORE_PASSWORD` and `KEYSTORE_PASSWORD` | `tls-auth-secret` |

> **Note:** The token endpoint must use the plain `dpn-keycloak` ClusterIP service, **not** the load-balancer hostname. Keycloak writes the token's `iss` claim from the hostname the client used; the Kafka broker only accepts the ClusterIP issuer, and any other produces a SASL `invalid_token` error.

> **Note:** The truststore is password-protected. A wrong password or a tampered file **fails loudly** and does not fall back to another trust source.

In self-service deployments these values are set once on the Self-Service chart (`DPN_KAFKA_*`, `DPN_KAFKA_TLS_SECRET_NAME`) and forwarded to every product container.

### STEP-08c: Configure the Image Pull Secret

DSI images are published to the private GHCR registry `ghcr.io/energy-dsi` — on this Azure path, the same registry is used as on AWS; there is no Azure Container Registry involved (see [Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration)). Create a pull secret in the data pipeline namespace before the CD workflow runs, using a GitHub PAT with `read:packages` scope:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<PAT with read:packages> \
  -n <your namespace>
```

On other clouds, the CD workflow passes the secret name to the Self-Service chart (`imagePullSecretName`) and to the UI as `env.DPN_IMAGE_PULL_SECRET`, so producer Deployments created from the UI use it too. **On Azure, this is not confirmed** — the Self-Service UI itself is currently deployed via the Azure DevOps pipeline rather than a GitHub Actions workflow in this repository (see the [Overview callout](../03-installation/07-dpn-data-pipeline-installation-process.md#overview)), and the confirmed Azure GHA consumer workflow pulls from this environment's own ACR rather than GHCR, with no `imagePullSecretName`/`ghcr-pull-secret` wiring observed in it. Confirm the actual pull-secret mechanism for both the Self-Service UI and the consumer pods with the platform team before relying on this paragraph for Azure.

---

## STEP-09: Configure DPN Data Store

The DPN Data Store consists of two sub-components:

- **Azure Blob Storage** — file storage for pipeline artefacts
- **Kafka Streaming Service** — event streaming between DPN components

### STEP-09a: Storage Blob Configuration

Storage is the integration layer between the organisation's data source, the Federator Gateway, the data pipelines and the data destination.

**Containers are created automatically.** The pipeline creates missing storage containers and Kafka topics, and the Self-Service UI refuses names that already exist. Deleting a data product removes its container and topics. The source storage account itself, and a source container you intend to read from, must be reachable with the connection string(s) in [STEP-08a](#step-08a-configure-storage-secrets).

| Process | Source container | Target container |
|---------|------------------|------------------|
| producer file adaptor | `{product_type}-stage` | `{product_type}-target` |
| consumer file extractor | `dp-consumer-stage` | `dp-consumer-target` |

The names above are proposals; the producer names can be overridden at the review step in [STEP-01](#step-01-set-up-a-new-data-product-self-service).

```text
Example container names (product_type = eq-sample-1):

  eq-sample-1-stage
  eq-sample-1-target
  dp-consumer-stage
  dp-consumer-target
```

> **Note:** Files keep their **original filename** in the target container. They are not renamed or prefixed with the organisation name.

> **Note:** Storage containers are accessed asynchronously by the Federator Gateway and the organisation's data source and destination to pick up and deposit files.

---

### STEP-09b: Configure Streaming Service (Kafka)

The DPN Streaming Service uses Kafka to emit events between DPN components: the data pipeline adaptors and extractors, the Federator Gateway, and the organisation's data source/destination endpoints. Topics are created automatically when first needed; the names below are the proposed conventions and may be customised.

**File based integration pathway**

| Process | Source | Target (notification topic) | Bootstrap server |
|---------|--------|-----------------------------|------------------|
| producer file adaptor | source container | `dpn-producer-file-{product_type}-target` | `dpn-kafka-src.<namespace>.svc.cluster.local:9092` |
| consumer file extractor | `dp-consumer-stage` container | `dp-consumer-file-target` | `dpn-kafka-target.<namespace>.svc.cluster.local:9092` |

**Topic based integration pathway**

| Process | Source topic | Target topic | Bootstrap server |
|---------|--------------|--------------|------------------|
| producer topic adaptor | `dpn-producer-{product_type}-stage` | `dpn-producer-{product_type}-target` | `dpn-kafka-src.<namespace>.svc.cluster.local:9092` |
| consumer topic extractor | `dp-consumer-topic-stage` | `dpn-consumer-{org}-{product}-target` (resolved from message headers) | `dpn-kafka-target.<namespace>.svc.cluster.local:9092` |

where **`product_type`** is the data product name such as `eq-sample-1`, as described in [STEP-01](#step-01-set-up-a-new-data-product-self-service).

> **Note:** The port shown (`9092`) is the chart default. Confirm the listener port that matches your broker's `SASL_SSL` configuration for your environment.

The file pathway notification message follows the convention below, which enables the Federator Server to locate and retrieve the file from the specified storage location:

```json
{
  "sourceType": "{cloud type}",
  "storageContainer": "{name of the storage container where the file is placed}",
  "path": "folder-name/file-name"
}
```

Example:

```json
{
  "sourceType": "AZURE",
  "storageContainer": "eq-sample-1-target",
  "path": "eq-orga-sample_v1.xml"
}
```

> **Note:** Valid values for `sourceType` are `AZURE`, `GCP` and `S3`. `path` is the file's original name.

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
| Oct-2026 | DSI Assurance   | Draft  | V2.0.0 |
