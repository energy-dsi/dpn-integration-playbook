# DPN Data Pipeline Configuration

---

## Table of Contents

- [Overview](#overview)
- [Data Pipeline Blueprints](#data-pipeline-blueprints)
- [Step1: Setup a New Data Product (Self-Service)](#step1-setup-a-new-data-product-self-service)
- [Step2: Setup Data Consumers](#step2-setup-data-consumers)
- [Step3: Setup Producer Helm Charts](#step3-setup-producer-helm-charts)
  - [Step3a: Set Up Producer Helm Charts For File Based Pathways](#step3a-set-up-producer-helm-charts-for-file-based-pathways)
  - [Step3b: Set Up Producer Helm Charts For Topic Based Pathways](#step3b-set-up-producer-helm-charts-for-topic-based-pathways)
- [Step4: Setup Consumer Helm Charts](#step4-setup-consumer-helm-charts)
  - [Step4a: Setup Consumer Helm Charts For File Based Integration Pathway](#step4a-setup-consumer-helm-charts-for-file-based-integration-pathway)
  - [Step4b: Setup Consumer Helm Charts For Topic Based Integration Pathway](#step4b-setup-consumer-helm-charts-for-topic-based-integration-pathway)
- [Step5: Configure Horizontal Pod Autoscaler (HPA)](#step5-configure-horizontal-pod-autoscaler-hpa)
- [Step6: Configure Scheduling](#step6-configure-scheduling)
  - [Scheduler Backend Options](#scheduler-backend-options)
  - [Behavior](#behavior)
- [Step7: Operate a Data Product](#step7-operate-a-data-product)
- [Step8: Configure Secrets](#step8-configure-secrets)
  - [Step8a: Configure Storage Secrets](#step8a-configure-storage-secrets)
  - [Step8b: Configure Kafka Security (SASL/TLS)](#step8b-configure-kafka-security-sasltls)
- [Step9: Configure DPN Data Store](#step9-configure-dpn-data-store)
  - [Step9a: Storage Blob / S3 Configuration](#step9a-storage-blob--s3-configuration)
  - [Step9b: Configure Streaming Service (Kafka)](#step9b-configure-streaming-service-kafka)
- [Review Notes](#review-notes)

---

## Overview

DPN Data Pipeline ensures secure and governed data exchange by moving data products between an organisation's internal storage/Kafka and the shared location read by the Federator Gateway (producer side), and from the Federator's drop location into the organisation's own destination (consumer side). Files are copied to the target bucket under their original name, and Kafka messages are forwarded with metadata headers added.

The data pipeline uses a **self-service, single-container design**:

| Aspect | Behaviour |
|--------|-----------|
| Containers per pathway | **One.** Each producer adaptor and consumer extractor performs schema mapping itself, so a data product is a single Deployment regardless of pathway. |
| Images | **One generic image per pathway.** Every identifier (product name, bucket/topic names, organisation) is supplied as environment variables at container start. A new data product is a new set of environment variables, not a folder copy or an image rebuild. |
| Producer creation | Producer data products are **created at runtime through the DPN Self-Service UI**, which launches one Deployment per data product (`dpn-producer-<pathway>-<product_type>`) through the Kubernetes API. These Deployments are not Helm releases. |
| Consumers | Fixed platform pipelines: exactly **one file extractor and one topic extractor** per platform (`dpn-consumer-file-extractor`, `dpn-consumer-topic-extractor`), Helm-deployed once. |
| Scheduling | Every container self-schedules (`SCHEDULER_BACKEND: interval`). No external orchestrator is required. See [Step6](#step6-configure-scheduling). |
| Organisation and cloud | Organisation name (`DPN_ORG_NAME`) and cloud provider (`DPN_CLOUD_PROVIDER: aws`) are platform-level settings of the Self-Service UI, not chosen per product. |

The data pipeline source, blueprints and Helm charts live in the central `dpn-containerised-deployment-service` repository under the `dpn-data-pipelines/` folder, and are deployed by the GitHub Actions workflows in the same repository (see the [installation guide](../03-installation/07-dpn-data-pipeline-installation-process.md)).

> **Upgrading from an earlier release: existing data products are not imported.** Data products deployed by earlier releases as separate per-product producer/consumer Helm releases are not discovered by the Self-Service UI. Each must be **recreated** through the UI following [Step1](#step1-setup-a-new-data-product-self-service). The UI only accepts bucket and topic names that do not exist yet, so a recreated product cannot attach to the old product's buckets or topics.

## Data Pipeline Blueprints

DSI provides one blueprint per pathway and side. Each contains the container source, a Dockerfile and a **reference** Helm chart with per-environment AWS values files. The Self-Service UI has its own chart under `service/charts`.

```text
dpn-containerised-deployment-service/
  └── dpn-data-pipelines/
        ├── blueprints/
        │     ├── producer/
        │     │     ├── file/adaptor/                 (main.py, Dockerfile, charts/)
        │     │     └── topic/adaptor/                (main.py, Dockerfile, charts/)
        │     └── consumer/
        │           ├── file/extractor/               (main.py, Dockerfile, charts/)
        │           └── topic/extractor/              (main.py, Dockerfile, charts/)
        └── service/
              └── charts/                             <- Self-Service UI chart

Each charts/ folder:
  charts/
    ├── values.yaml                                   <- Reference file; do not edit directly
    └── values/aws/<environment>-<cluster>.yaml       <- Your environment + cluster overrides
```

| Blueprint | Image name (default) | How it is deployed |
|-----------|----------------------|--------------------|
| `producer/file/adaptor` | `dpn-producer-file-adaptor-generic` | Created per data product by the Self-Service UI |
| `producer/topic/adaptor` | `dpn-producer-topic-adaptor-generic` | Created per data product by the Self-Service UI |
| `consumer/file/extractor` | `dpn-consumer-file-extractor` | Helm-deployed once by `dpn-self-service-cd.yml` |
| `consumer/topic/extractor` | `dpn-consumer-topic-extractor` | Helm-deployed once by `dpn-self-service-cd.yml` |
| `service` (Self-Service UI) | `dpn-self-service` | Helm-deployed once by `dpn-self-service-cd.yml` |

The `values.yaml` files under `blueprints/` **must not** be modified directly; environment overrides go in `values/aws/<environment>-<cluster>.yaml`. The producer charts exist for manual or reference deployment (for example testing one instance outside the self-service flow); the UI-created Deployments mirror their spec.

> **Note:** AWS values files are currently checked in for `test-dpn01` and `test-dpn02` only (the producer adaptor charts for `test-dpn01` only). Add `values/aws/<environment>-<cluster>.yaml` files for any other environment/cluster before deploying to it — the workflows pass that file with `-f` and fail if it is missing.

## Step1: Setup a New Data Product (Self-Service)

A producing organisation creates a data product in the **DPN Self-Service UI**. No blueprint folder is copied and no image is built; the UI launches the generic image for the chosen pathway with the product's environment variables.

**Creating a product is a two-step flow:**

1. Open **Create New Data Product** and supply:

   | Field | Description | Rules |
   |-------|-------------|-------|
   | `product_type` | Unique data product identifier (also written as `PRODUCT_NAME` / `productType`) | Lowercase letters, digits and hyphens only. It becomes part of the Deployment name `dpn-producer-<pathway>-<product_type>`, which Kubernetes caps at 63 characters, so keep it short |
   | `pipeline_type` | Integration pathway | `file` or `topic` |
   | `schedule_seconds` | Poll interval (file pathway) or consumer window (topic pathway) | 5–3600, default `60` |
   | `execution_mode` | `automatic` runs on schedule; `manual` only runs when **Run Now** is used | default `automatic` |

2. Review the **proposed names** and confirm or override them. Nothing launches until you confirm.

   | Pathway | Proposed name | Default |
   |---------|---------------|---------|
   | file | Source S3 bucket | `{product_type}-stage` |
   | file | Target S3 bucket | `{product_type}-target` |
   | file | Notification topic | `dpn-producer-file-{product_type}-target` |
   | topic | Source topic | `dpn-producer-{product_type}-stage` |
   | topic | Target topic | `dpn-producer-{product_type}-target` |

   The consumer group for the topic pathway is derived from `product_type` automatically.

**Name rules and pre-checks**

- Bucket names are validated against the cross-cloud storage naming rules: 3–63 characters, lowercase letters, digits and hyphens, starting and ending with a letter or digit.
- Every confirmed bucket and topic name must be **brand new**. A pre-check against S3 and the Kafka broker blocks creation if a name already exists.
- Buckets and topics are **created automatically** by the pipeline when needed (see [Step9](#step9-configure-dpn-data-store)).

**What gets deployed**

```text
ns-dpn-dp-01
  └── Deployment  dpn-producer-<pathway>-<product_type>     <- one per data product, not a Helm release
```

The Deployment runs as the Self-Service UI's ServiceAccount (`env.DPN_PRODUCER_SERVICE_ACCOUNT`, `dpn-self-service` in the AWS values files), so it inherits the UI's IRSA role for S3 access (see [Step8a](#step8a-configure-storage-secrets)).

## Step2: Setup Data Consumers

Consumer pipelines are **not** created per product. The two fixed consumer pipelines are deployed once per platform by the `dpn-self-service-cd.yml` workflow from `blueprints/consumer/{file,topic}/extractor/charts`, with `values/aws/<environment>-<cluster>.yaml`.

| Pipeline | Helm release / Deployment | Receives | Delivers to |
|----------|---------------------------|----------|-------------|
| File | `dpn-consumer-file-extractor` | Files dropped by the Federator client in `srcContainerName` | `targetContainerName`, plus one Kafka notification per file on `targetTopicName` |
| Topic | `dpn-consumer-topic-extractor` | Messages on `srcTopicName` | Topic `dpn-consumer-<org>-<product>-target`, resolved per message |

The consumer topic extractor reads `orgName` and `productType` from each message's headers (stamped by the producer topic adaptor). Messages with missing metadata are skipped; no catch-all topic is created.

> **Note:** The values file is replicated per environment and DPN deployment under `values/aws/<environment>-<cluster>.yaml` (e.g. `values/aws/test-dpn01.yaml`). The workflow selects it from the `environment`/`cluster` inputs, alongside the config JSON described in [AWS Environment Configuration](00-common-dpn-configuration.md#step22-aws-environment-configuration).

## Step3: Setup Producer Helm Charts

For a self-service product these variables are generated by the UI; the tables below document what each container reads. The same names are used by the reference Helm charts (`blueprints/producer/{file,topic}/adaptor/charts`) when a producer is deployed manually.

### Step3a: Set Up Producer Helm Charts For File Based Pathways

**Identity & Image**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-dp-01` |
| name | Deployment name (self-service: `dpn-producer-file-<product_type>`) | `producer-file-adaptor-example` |
| cloudProviderType | Cloud provider to run on | `aws`|
| imageRegistry | Registry path images are pulled from | `ghcr.io/energy-dsi` |
| imagePullSecret | Image pull secret for GHCR | `ghcr-pull-secret` |
| imageName | Image name | `dpn-producer-file-adaptor-generic` |
| imageTag | Image tag to deploy | `latest` |
| productType | Product type name — lowercase alphanumeric and hyphens only | `eq-sample-1` |
| PRODUCT_NAME | Runtime env var alias of `productType` — same value, consumed by application code (see [Step1](#step1-setup-a-new-data-product-self-service)) | `eq-sample-1` |
| orgName | Organisation name | `example-org` |

**Storage**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| srcContainerName | Source S3 bucket the adaptor reads | `eq-sample-1-stage` |
| targetContainerName | Target S3 bucket files are copied to (original filename kept) | `eq-sample-1-target` |
| storageConnectionSecret | Kubernetes secret for storage connection strings (`SRC_CONNECTION_STRING`/`TARGET_CONNECTION_STRING`, referenced as optional). Not needed on AWS, where S3 access goes through IRSA (see below) | `producer-file-dp-secret` |

**AWS S3** (only when `cloudProviderType: aws`)

| Parameter | Purpose | Example |
|-----------|---------|---------|
| awsEndpointUrl | Custom S3 endpoint URL, rendered into the `<name>-aws-config` ConfigMap. Leave empty to use the AWS default — the chart derives `https://s3.<awsRegion>.amazonaws.com` | `""` |
| awsRegion | AWS region for the S3 bucket(s) | `eu-west-2` |
| awsAccessSecret | Kubernetes secret holding `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (referenced as optional). Real S3 access comes from the pod's IRSA-bound ServiceAccount, so this secret need not exist | `aws-access-secret` |

**ServiceAccount / IRSA (AWS only)**

The file-pathway charts ship `templates/serviceaccount.yaml`, created only when `cloudProviderType: aws` and `serviceAccount.create: true`; the Deployment's `serviceAccountName` is set to it automatically:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| serviceAccount.create | Whether to create the IRSA ServiceAccount | `true` |
| serviceAccount.name | ServiceAccount name | `dpn-producer-file-adaptor` |
| serviceAccount.irsaRoleArn | ARN of the IAM role this ServiceAccount assumes. Its trust policy must scope `sts:AssumeRoleWithWebIdentity` to `system:serviceaccount:<namespace>:<serviceAccount.name>`, and its policy must grant S3 access to the source and target buckets | `arn:aws:iam::<account-id>:role/<serviceAccount.name>-s3-role` |

> **Note:** when a producer chart is deployed manually through `dpn-cd-data-pipelines.yml` with `processType: file`, the workflow creates the source/target buckets if missing and creates/updates an IAM role named `<serviceAccount.name>-s3-role` scoped to exactly those two buckets, then overrides `serviceAccount.irsaRoleArn` with it (see the [installation guide](../03-installation/07-dpn-data-pipeline-installation-process.md#step2c-execute-data-pipeline-cd-workflow)).

**Kafka Connectivity**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| bootstrapServer | Kafka bootstrap server address | `dpn-kafka-src.ns-dpn-01.svc.cluster.local:9092` |
| targetTopicName | Kafka topic on which one notification per file is published | `dpn-producer-file-eq-sample-1-target` |

Kafka authentication (SASL/TLS/OAuth) is configured separately from topic naming — see [Step8b: Configure Kafka Security (SASL/TLS)](#step8b-configure-kafka-security-sasltls).

**Scheduling & Scaling**

`SCHEDULER_BACKEND`, `EXECUTION_MODE`, `scheduleInterval`, `PIPELINE_CONTROL_TOPIC`, and `PIPELINE_STATUS_TOPIC` also live in this values.yaml — see [Step6: Configure Scheduling](#step6-configure-scheduling). `replicaCount` and the `hpa.*` block are covered in [Step5: Configure Horizontal Pod Autoscaler (HPA)](#step5-configure-horizontal-pod-autoscaler-hpa).

**Observability**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| STATSD_HOST | StatsD host for metrics emission (leave empty to disable) | `""` |
| STATSD_PORT | StatsD port | `8125` |
| SERVICE_NAME | Service name reported to tracing/metrics backends | `dpn data pipeline` |
| SERVICE_VERSION | Service version reported to tracing/metrics backends | `1.0.0` |
| OTEL_EXPORTER_OTLP_ENDPOINT | OTel collector's OTLP endpoint. Defaults to the HTTPS endpoint on port `4318` | `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` |
| OTEL_EXPORTER_OTLP_INSECURE | Whether the OTLP endpoint above is called over plaintext. Defaults to `false` (HTTPS, port `4318`) | `false` |
| OTEL_OAUTH_DISABLED | `true` skips OAuth to the collector (dev/test only) | `false` |
| ENVIRONMENT | Deployment environment label attached to telemetry | `production` |

> **Note:** `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_INSECURE` default to the HTTPS endpoint on port `4318` with `INSECURE: false`, and this is the supported out-of-the-box configuration. Plaintext HTTP on port `4317` is also supported, but only as a manual, user-driven change — to switch to it, update **both** values together:
>
> | Mode | OTEL_EXPORTER_OTLP_ENDPOINT | OTEL_EXPORTER_OTLP_INSECURE |
> |------|------------------------------|------------------------------|
> | HTTPS (default) | `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` | `false` |
> | Plaintext HTTP (manual) | `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4317` | `true` |
>
> Changing only the port or only the flag results in a mismatched configuration — the port and the `INSECURE` flag must be updated together.

### Step3b: Set Up Producer Helm Charts For Topic Based Pathways

Identity, Kafka security, scheduling and observability parameters are as in [Step3a](#step3a-set-up-producer-helm-charts-for-file-based-pathways), with these differences. The topic pathway is Kafka-to-Kafka only: it has no S3 parameters, and its Deployment does not bind a ServiceAccount.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| name | Deployment name (self-service: `dpn-producer-topic-<product_type>`) | `producer-topic-adaptor-example` |
| imageName | Image name | `dpn-producer-topic-adaptor-generic` |
| orgName | Organisation name, stamped into message headers | `example-org` |
| productType / PRODUCT_NAME | Product name, stamped into message headers | `eq-sample-1` |
| bootstrapServer | Kafka bootstrap server address | `dpn-kafka-src.ns-dpn-01.svc.cluster.local:9092` |
| srcTopicName | Kafka topic the adaptor consumes | `dpn-producer-eq-sample-1-stage` |
| srcGroupId | Kafka consumer group for the source topic | `producer-topic-adaptor-eq-sample-1` |
| targetTopicName | Target topic produced to. In self-service this is the confirmed value; if left blank on a manual deploy it falls back to `dpn-producer-<org>-<product>-target` | `dpn-producer-eq-sample-1-target` |
| consumerRetryDelaySecs | Delay, in seconds, before retrying a failed consume | `5` |
| TOPIC_TASK_TIMEOUT_SECS | Length, in seconds, of one consumer window. Self-service sets this from `schedule_seconds` | `60` |
| producerFlushTimeoutSecs | Upper bound, in seconds, on the per-cycle producer flush | `10` |

Headers added to every forwarded message: `orgName`, `productType`, `processedAt`, `offset`, plus trace context.

## Step4: Setup Consumer Helm Charts

### Step4a: Setup Consumer Helm Charts For File Based Integration Pathway

Chart: `blueprints/consumer/file/extractor/charts`, deployed as the `dpn-consumer-file-extractor` release.

**Identity & Image**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace (overridden at deploy time) | `ns-dpn-dp-01` |
| name | Deployment name | `dpn-consumer-file-extractor` |
| cloudProviderType | Cloud provider to run on | `aws`|
| imageRegistry | Registry path images are pulled from (overridden at deploy time with the config JSON's `IMAGE_REGISTRY`) | `ghcr.io/energy-dsi/1.0.1` |
| imagePullSecret | Image pull secret for GHCR | `ghcr-pull-secret` |
| imageName | Image name (set at deploy time) | `dpn-consumer-file-extractor` |
| imageTag | Image tag (set at deploy time) | `<version>` |
| PRODUCT_NAME | Logical name used in logs/messages | `consumer-file` |

**Storage**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| srcContainerName | S3 bucket the Federator client drops files into | `dpn-<environment>-<nn>-dp-consumer-stage` |
| targetContainerName | Organisation's destination S3 bucket | `dp-consumer-target-<environment>-<nn>-<account-id>-<region>` |
| targetTopicName | Kafka topic for one notification per file | `dp-consumer-file-target` |

**AWS S3** (only when `cloudProviderType: aws`)

| Parameter | Purpose | Example |
|-----------|---------|---------|
| awsEndpointUrl | Custom S3 endpoint URL. The AWS values files set it to `""` to use the AWS default | `""` |
| awsRegion | AWS region for the S3 bucket(s) | `eu-west-2` |

**ServiceAccount / IRSA (AWS only)**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| serviceAccount.create | Whether to create the IRSA ServiceAccount | `true` |
| serviceAccount.name | ServiceAccount name | `dpn-consumer-file-extractor` |
| serviceAccount.irsaRoleArn | ARN of the IAM role this ServiceAccount assumes, granting S3 access to the source and target buckets | `arn:aws:iam::<account-id>:role/dpn-data-pipeline-s3-role` |

**Kafka Connectivity**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| bootstrapServer | Kafka bootstrap server address | `dpn-kafka-target.ns-dpn-01.svc.cluster.local:9092` |
| DRAIN_IDLE_SECS | Idle time, in seconds, with no new messages before the consumer stops draining the topic | `15` |
| topicTaskTimeoutSecs | Timeout, in seconds, for processing a single topic message/task | `60` |

Kafka authentication (SASL/TLS/OAuth) is configured separately — see [Step8b: Configure Kafka Security (SASL/TLS)](#step8b-configure-kafka-security-sasltls).

**Scheduling & Observability**

`SCHEDULER_BACKEND` (`interval`), `EXECUTION_MODE`, `scheduleInterval`, `PIPELINE_CONTROL_TOPIC` and `PIPELINE_STATUS_TOPIC` are as in [Step6](#step6-configure-scheduling). `SERVICE_NAME` / `SERVICE_VERSION`, `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_INSECURE`, `OTEL_OAUTH_DISABLED` and `ENVIRONMENT` are as in [Step3a](#step3a-set-up-producer-helm-charts-for-file-based-pathways). The consumer charts also set `HEARTBEAT_INTERVAL_SECONDS` (periodic liveness log, `60`).

> **Note:** the file-based consumer's reference `values.yaml` sets only `STATSD_PORT` (no `STATSD_HOST` equivalent).

### Step4b: Setup Consumer Helm Charts For Topic Based Integration Pathway

Chart: `blueprints/consumer/topic/extractor/charts`, deployed as the `dpn-consumer-topic-extractor` release.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace (overridden at deploy time) | `ns-dpn-dp-01` |
| name | Deployment name | `dpn-consumer-topic-extractor` |
| imageName | Image name (set at deploy time) | `dpn-consumer-topic-extractor` |
| PRODUCT_NAME | Logical name used in logs/messages | `consumer-topic` |
| bootstrapServer | Kafka bootstrap server address | `dpn-kafka-target.ns-dpn-01.svc.cluster.local:9092` |
| srcTopicName | Kafka topic the extractor consumes | `dp-consumer-topic-stage` |
| srcGroupId | Kafka consumer group | `consumer-topic-extractor` |
| targetTopicName | Not used. Resolved per message as `dpn-consumer-<org>-<product>-target` | Not required |
| TOPIC_TASK_TIMEOUT_SECS | Maximum length, in seconds, of one consume window | `60` |
| DRAIN_IDLE_SECS | A window ends early once the topic has been quiet this long | `15` |
| consumerRetryDelaySecs | Delay, in seconds, before retrying a failed consume | `5` |
| producerFlushTimeoutSecs | Bound, in seconds, on the producer flush | `10` |
| scheduleInterval | Interval between windows, in seconds | `60` |
| statsdPort | StatsD port | `8125` |

Scheduling and observability parameters are as in [Step4a](#step4a-setup-consumer-helm-charts-for-file-based-integration-pathway).

DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

> **Naming conventions**

Organisations must adopt the following naming convention

> - Product types and S3 bucket names must use only lowercase alphanumeric characters and hyphens (`-`). Product type is enforced by the Self-Service UI; bucket names are enforced to the rules in [Step1](#step1-setup-a-new-data-product-self-service).
> - Organisation names must be abbreviated without spaces.
> - Kafka topic names and consumer group IDs should follow the same hyphenated convention.

## Step5: Configure Horizontal Pod Autoscaler (HPA)

The producer adaptor charts can scale horizontally based on load, rather than running a fixed `replicaCount`. This requires the Kubernetes **metrics-server** to be running in the EKS cluster (install the `metrics-server` add-on if not already present).

| Parameter | Purpose | Example |
|-----------|---------|---------|
| hpa.enabled | Enables the Horizontal Pod Autoscaler for this stage | `false` |
| hpa.minReplicas | Minimum pod count, including at idle | `1` |
| hpa.maxReplicas | Maximum pod count under peak load | `3` |
| hpa.scaleUp.cpuUtilization | Average CPU utilisation (as % of requested CPU) that triggers scale-out | `80` |
| hpa.scaleUp.memoryUtilization | Average memory utilisation (as % of requested memory) that triggers scale-out | `80` |
| hpa.scaleUpBehavior.stabilizationWindowSeconds | How long the controller waits before acting on a scale-out signal (Kubernetes HPA v2 `behavior.scaleUp`) | `60` |
| hpa.scaleUpBehavior.policies | Scale-out policies (`type`: `Pods` or `Percent`, `value`, `periodSeconds`) | `[{type: Pods, value: 1, periodSeconds: 60}]` |
| hpa.scaleDown.stabilizationWindowSeconds | How long the controller waits before acting on a scale-in signal (Kubernetes HPA v2 `behavior.scaleDown`) | `300` |
| hpa.scaleDown.policies | Scale-in policies (`type`: `Pods` or `Percent`, `value`, `periodSeconds`) | `[{type: Percent, value: 50, periodSeconds: 60}]` |

> **Note:** when `hpa.enabled: true`, the chart's `replicaCount` value is treated only as the **initial** replica count at first deploy — the HPA controller owns the replica count from that point on. Check `kubectl get hpa` for the running count.

> **Note:** `hpa.enabled` defaults to `false`. Leave it disabled while `SCHEDULER_BACKEND: interval` is in use (the default, see [Step6](#step6-configure-scheduling)) — each replica runs its own poll loop with no work partitioning, so scaling beyond one replica risks duplicate processing. Only enable HPA once the stage consumes work through a model that partitions it across replicas (`kafka-trigger` over a partitioned topic).

## Step6: Configure Scheduling

Each data pipeline container decides **when** a cycle runs through the `SCHEDULER_BACKEND` parameter in its `values.yaml` (for self-service products, set by the UI). No external scheduler is deployed.

### Scheduler Backend Options

| Value | Description |
|---------|---------|
| `interval` | Self-scheduling loop. The container runs a cycle every `scheduleInterval` seconds. **Default for every chart and every self-service product** |
| `kafka-trigger` | Event-driven execution. The container waits for a trigger message on `PIPELINE_CONTROL_TOPIC` before starting a run and reports progress to `PIPELINE_STATUS_TOPIC`. Requires something to publish the triggers |

There are other options available i.e. standalone but not exercised as part of DSI package.

### Behavior

- With **`SCHEDULER_BACKEND=interval`**, the pipeline runs automatically at the configured `scheduleInterval` when `EXECUTION_MODE=automatic`.
- With **`SCHEDULER_BACKEND=kafka-trigger`**, a message published to `PIPELINE_CONTROL_TOPIC` starts a run, and the pipeline reports progress to `PIPELINE_STATUS_TOPIC`. Do not use it unless something publishes to the control topic — otherwise the pod waits indefinitely.
- With **`EXECUTION_MODE=manual`**, scheduled and triggered cycles are skipped; a cycle only runs when forced, which is what the UI's **Run Now** button does.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Backend from the table above | `interval` |
| EXECUTION_MODE | `automatic` or `manual` | `automatic` |
| scheduleInterval | Interval in seconds for `interval` | `60` |
| PIPELINE_CONTROL_TOPIC | Kafka topic the pipeline stage listens on for a start signal (`kafka-trigger` only) | `dpn-pipeline-control` |
| PIPELINE_STATUS_TOPIC | Kafka topic the pipeline stage publishes run status/progress to (`kafka-trigger` only) | `dpn-pipeline-status` |

<a id="step-07-operate-a-data-product"></a>

## Step7: Operate a Data Product

Once created, a data product is operated from the Self-Service UI. The same actions are available as HTTP endpoints (`/data-products/<product_type>/<action>`).

| Action | Effect | Role required |
|--------|--------|---------------|
| Start | Creates the data product's Deployment | `dpnadmin` or `dpnoperator` |
| Stop | Removes the Deployment; the product definition is kept | `dpnadmin` or `dpnoperator` |
| Pause / Resume | Switches `EXECUTION_MODE` to `manual` / `automatic`; the Deployment keeps running | `dpnadmin` or `dpnoperator` |
| Run Now | Forces one cycle immediately | `dpnadmin` or `dpnoperator` |
| Logs / run history | View container logs and recent runs | any, including `dpnreader` |
| Delete | Removes the Deployment **and** its Kafka topic(s) and S3 bucket(s), and its registry entry | `dpnadmin` only |

The two consumer pipelines can also be paused, resumed, run and deleted from the UI. Delete on a consumer removes its Deployment only; it comes back only by re-running `dpn-self-service-cd.yml`.

> **Warning:** Delete tears down the product's Kafka topics and S3 buckets. Treat it as irreversible.

Access control is enforced server-side behind an `oauth2-proxy` in the same Helm release (`oauth2Proxy.*` in `service/charts`), with login against Keycloak's `dpn-realm` using the `dpn-service-client` client. The allowed realm roles are `dpnadmin`, `dpnoperator` and `dpnreader`. Before login works, `dpn-service-client` must have **Standard flow** enabled and `<oauth2Proxy.externalUrl>/oauth2/callback` registered as a valid redirect URI (plus `<oauth2Proxy.externalUrl>` as a post-logout redirect URI and web origin).

The product registry is a JSON file on a persistent volume (`persistence.*`, `gp3` storage class on AWS), mirrored to the S3 bucket named by `env.DPN_REGISTRY_BACKUP_CONTAINER` on every write.

## Step8: Configure Secrets

DSI Data Pipeline uses Kubernetes secrets by design, as this is a Bring-Your-Own (BYO) component. On AWS, S3 access uses IRSA rather than stored credentials; Kafka authentication material is held in Kubernetes secrets. All secrets must exist in the data pipeline namespace `ns-dpn-dp-01`.

> **New environment:** create these secrets once in every new environment, then restart the data pipeline pods so they pick them up. See [One-time setup for a new environment](../03-installation/07-dpn-data-pipeline-installation-process.md#one-time-setup-for-a-new-environment-create-secrets-and-restart-pods).

| Secret | Purpose |
|--------|---------|
| `dpn-tls` | Kafka truststore (`truststore.jks`) and keystore (`keystore.jks`), mounted into pods |
| `tls-auth-secret` | `TRUSTSTORE_PASSWORD` and `KEYSTORE_PASSWORD` |
| `dpn-keycloak-secrets` | Keycloak client secret (`KC_SERVICE_CLIENT_SECRET`) |
| `dpn-health-ca` | CA bundle for the OTEL collector's TLS listener (`env.DPN_OTEL_TLS_SECRET_NAME`, forwarded to UI-created producers) |
| `ghcr-pull-secret` | Pull secret for GHCR (GitHub PAT with `read:packages`) |

### Step8a: Configure Storage Secrets

On AWS, S3 access comes from **IRSA**, not from stored keys:

- The Self-Service UI's ServiceAccount (`dpn-self-service`) is annotated with `serviceAccount.irsaRoleArn` from `service/charts/values/aws/<environment>-<cluster>.yaml`. Producer Deployments created by the UI run as this ServiceAccount (`env.DPN_PRODUCER_SERVICE_ACCOUNT`), so the role must grant S3 read/write **and bucket creation** for every product's buckets, plus access to the registry backup bucket.
- The consumer file extractor uses its own ServiceAccount (`serviceAccount.*` in its values file) — see [Step4a](#step4a-setup-consumer-helm-charts-for-file-based-integration-pathway).
- `awsAccessSecret` (`aws-access-secret`) and the Self-Service chart's `platformStorageSecretName` (default `producer-file-dp-secret`) reference `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` as **optional**. Leave them unset when IRSA is in place; create them only if you choose static keys instead:

```bash
kubectl create secret generic aws-access-secret -n ns-dpn-dp-01 \
  --from-literal=AWS_ACCESS_KEY_ID=<key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret>
```

> **Note:** the IRSA roles referenced by the Self-Service and consumer values files (`serviceAccount.irsaRoleArn`) are not created by `dpn-self-service-cd.yml` — create them before deploying, with a trust policy scoped to `system:serviceaccount:ns-dpn-dp-01:<serviceAccount name>`.

### Step8b: Configure Kafka Security (SASL/TLS)

Every container that connects to Kafka authenticates using SASL over TLS, with OAuth2 client-credentials issued by Keycloak. These are set directly in each chart's `values.yaml`, alongside `bootstrapServer` (see [Step3a](#step3a-set-up-producer-helm-charts-for-file-based-pathways)):

| Parameter | Purpose | Example |
|-----------|---------|---------|
| KAFKA_SECURITY_PROTOCOL | Transport security for the Kafka connection | `SASL_SSL` (set to `SSL` or `PLAINTEXT` to opt out) |
| KAFKA_SASL_MECHANISM | SASL mechanism | `OAUTHBEARER` (OAuth2 client-credentials via Keycloak) |
| KAFKA_OAUTH_CLIENT_ID | Keycloak service-account client ID | `dpn-service-client` |
| KAFKA_OAUTH_TOKEN_ENDPOINT_URL | Keycloak realm token endpoint | `https://dpn-keycloak.ns-dpn-01.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| kafkaTlsSecretName | Kubernetes secret providing the `dpn-tls` volume. The charts mount `truststore.jks`/`keystore.jks` as subPaths at `/etc/secrets/truststore.jks` and `/etc/secrets/keystore.jks` | `dpn-tls` |
| kafkaOauthSecretName | Kubernetes secret providing the Keycloak client secret (key `KC_SERVICE_CLIENT_SECRET`) | `dpn-keycloak-secrets` |
| tlsAuthSecretName | Kubernetes secret providing `TRUSTSTORE_PASSWORD` and `KEYSTORE_PASSWORD` | `tls-auth-secret` |

> **Note:** In self-service deployments these values are set once on the Self-Service chart (`env.DPN_KAFKA_*`, `env.DPN_KAFKA_TLS_SECRET_NAME`, `kafkaOauthSecretName`, `tlsAuthSecretName`) and forwarded to every product container. UI-created producer Deployments mount `dpn-tls` as a directory at `/etc/kafka/secrets` and read the CA from `/etc/kafka/secrets/ca.crt`, so `dpn-tls` must also carry `ca.crt` for them.

---

## Step9: Configure DPN Data Store

The DPN Data Store consists of two sub-components:

- **S3** — File storage for pipeline artefacts
- **Kafka Streaming Service** — Event streaming between DPN components

### Step9a: Storage Blob / S3 Configuration

S3 is the integration layer between the organisation's internal data source, the Federator Gateway, Data Pipelines, and the data destination.

**Buckets are created automatically.** The pipeline creates missing buckets, and the Self-Service UI refuses names that already exist. Deleting a data product removes its buckets. The recommended naming convention is:

| Process | Source Bucket Name | Target Bucket Name |
|---------|-----------------------|-----------------------|
| producer file adaptor | `{product_type}-stage` | `{product_type}-target` |
| consumer file extractor | `dp-consumer-stage` | `dp-consumer-target` |

The producer names are proposals and can be overridden at the review step in [Step1](#step1-setup-a-new-data-product-self-service). The consumer AWS values files use environment-qualified names (e.g. `dpn-<environment>-<nn>-dp-consumer-stage`), and `dpn-cd-data-pipelines.yml` qualifies bucket names as `<name>-<environment>-<nn>-<account-id>-<region>` because S3 bucket names are globally unique.

```text
Example bucket names (product_type = eq-sample-1):

  eq-sample-1-stage
  eq-sample-1-target
  dp-consumer-stage
  dp-consumer-target
```

> **Note:** Files keep their **original filename** in the target bucket.

> **Note:** S3 buckets are accessed asynchronously by the Federator Gateway and the organisation's data source and destination to pick up and deposit files.

---

### Step9b: Configure Streaming Service (Kafka)

The DPN Streaming Service uses Kafka to emit events between DPN components, including the Data Pipeline adaptors and extractors, Federator Gateway, and organisation data source/destination endpoints. Topics are created automatically when first needed; the proposed names are listed below and may be customised.

For file based integration pathway, the following convention is recommended

| Process | Source | Target (notification) Topic Name | Bootstrap Server |
|---------|-------------------|-------------------|------------------|
| producer file adaptor | source bucket | `dpn-producer-file-{product_type}-target` | `dpn-kafka-src.ns-dpn-01.svc.cluster.local:9092` |
| consumer file extractor | `dp-consumer-stage` bucket | `dp-consumer-file-target` | `dpn-kafka-target.ns-dpn-01.svc.cluster.local:9092` |

For streaming based integration pathway, the following convention is recommended

| Process | Source Topic Name | Target Topic Name | Bootstrap Server |
|---------|-------------------|-------------------|------------------|
| producer topic adaptor | `dpn-producer-{product_type}-stage` | `dpn-producer-{product_type}-target` | `dpn-kafka-src.ns-dpn-01.svc.cluster.local:9092` |
| consumer topic extractor | `dp-consumer-topic-stage` | `dpn-consumer-{org}-{product}-target` (resolved from message headers) | `dpn-kafka-target.ns-dpn-01.svc.cluster.local:9092` |


where **`product_type`** is the name of the data product name such as `eq-sample-1` as described in previous sections.

The file pathway notification message follows the convention below. This enables the Federator Server to locate and retrieve the file from the specified storage location during file transfer:

```json
{
  "sourceType": "S3",
  "storageContainer": "{name of the S3 bucket where the file is placed}",
  "path": "folder-name/file-name"
}
```

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|----------|
| Sep-2026 | DSI Assurance   | Final  | V1.0.0 |
