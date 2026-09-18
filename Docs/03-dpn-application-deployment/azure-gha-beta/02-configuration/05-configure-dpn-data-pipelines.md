# DPN Data Pipeline Configuration

---

## Table of Contents

- [Overview](#overview)
- [Data Pipeline Blueprints](#data-pipeline-blueprints)
- [Step1: Setup a New Data Product From Blueprint](#step1-setup-a-new-data-product-from-blueprint)
- [Step2: Setup Data Consumers From Blueprint](#step2-setup-data-consumers-from-blueprint)
- [Step3: Setup Producer Helm Charts](#step3-setup-producer-helm-charts)
  - [Step3a: Set Up Producer Helm Charts For File Based Pathways](#step3a-set-up-producer-helm-charts-for-file-based-pathways)
  - [Step3b: Set Up Producer Helm Charts For Topic Based Pathways](#step3b-set-up-producer-helm-charts-for-topic-based-pathways)
- [Step4: Setup Consumer Helm Charts](#step4-setup-consumer-helm-charts)
  - [Step4a: Setup Consumer Helm Charts For File Based Integration Pathway](#step4a-setup-consumer-helm-charts-for-file-based-integration-pathway)
  - [Step4b: Setup Consumer Helm Charts For Topic Based Integration Pathway](#step4b-setup-consumer-helm-charts-for-topic-based-integration-pathway)
- [Step5: Configure Horizontal Pod Autoscaler (HPA)](#step5-configure-horizontal-pod-autoscaler-hpa)
- [Step6: Configure Scheduling](#step6-configure-scheduling)
  - [Option A (Helm): Configure Scheduling Using Airflow](#option-a-helm-configure-scheduling-using-airflow)
  - [Scheduler Backend Options](#scheduler-backend-options)
  - [Behavior](#behavior)
  - [Option B (Helm): Configure Scheduling Without Airflow](#option-b-helm-configure-scheduling-without-airflow)
- [Step7: Onboard a New Data Product on Airflow Scheduler](#step7-onboard-a-new-data-product-on-airflow-scheduler)
- [Step8: Configure Secrets](#step8-configure-secrets)
  - [Step8a: Configure Storage Secrets](#step8a-configure-storage-secrets)
  - [Step8b: Configure Kafka Security (SASL/TLS)](#step8b-configure-kafka-security-sasltls)
- [Step9: Configure DPN Data Store](#step9-configure-dpn-data-store)
  - [Step9a: Storage Blob / S3 Configuration](#step9a-storage-blob--s3-configuration)
  - [Step9b: Configure Streaming Service (Kafka)](#step9b-configure-streaming-service-kafka)
- [Review Notes](#review-notes)

---

## Overview

DPN Data Pipeline ensures secure and governed data exchange by validating and transforming datasets before and after transmission. It is expected to perform schema assurance, metadata validation, and controlled processing across producer and consumer stages. This ensures all shared data conforms to required schemas, security classifications, and governance standards, enabling reliable and compliant data sharing. The DPN data pipeline provides blueprints of different data template schemas following CIM validation models, i.e. EQ, EQBD, SSH, DL.

## Data Pipeline Blueprints

DSI provides the following schema types belonging to CIM validation models at this moment. Organisations are expected to verify and augment any new schema type following the DSM data template definition, and to bring their own adaptor and mapper components accordingly. 

| Schema | Description |
|------|-------------|
| DL | Diagram Layout |
| EQ | Equipment |
| EQBD | Equipment Boundary |
| SSH | Steady State Hypothesis |

DSI provides the above schema-type blueprints from which organisations prepare their data products. The `values.yaml` files within the blueprints directory **must not** be modified directly. The blueprints folder is organised by integration pathway (e.g. `file` and `topic`) and by schema type within each pathway.

```text
Root-Repository
  └── blueprints
        └── consumer
              └── file
                    ├── extractor
                    │     └── charts
                    │           └── values.yaml
                    └── schema_mapper
                          └── charts
                                └── values.yaml
              └── topic
                    ├── extractor
                    │     └── charts
                    │           └── values.yaml
                    └── schema_mapper
                          └── charts
                                └── values.yaml                                
        └── producer
              └── file
                    ├── dl
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    ├── eq
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    ├── eqbd
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    └── ssh
                          ├── adaptor
                          │     └── charts
                          │           └── values.yaml
                          └── schema_mapper
                                └── charts
                                      └── values.yaml
              └── topic
                    ├── dl
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    ├── eq
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    ├── eqbd
                    │     ├── adaptor
                    │     │     └── charts
                    │     │           └── values.yaml
                    │     └── schema_mapper
                    │           └── charts
                    │                 └── values.yaml
                    └── ssh
                          ├── adaptor
                          │     └── charts
                          │           └── values.yaml
                          └── schema_mapper
                                └── charts
                                      └── values.yaml                                      
```

## Step1: Setup a New Data Product From Blueprint

The following steps are required when an organisation produces a data product:

1. Define the **`product_type`** name — the identifier/name of the data product being published. Each product type must conform to one of the schema types available in the blueprints.
2. Define the **`process_type`** - file/topic for the data product.
3. Copy the relevant schema folder (e.g. `eq`, `eqbd`, `dl`, or `ssh`) from `Root-Repository/blueprints/producer/file/{schema_type}` to `Root-Repository/producer/file/{schema_type}` if **process_type is file**.
4. Copy the relevant schema folder (e.g. `eq`, `eqbd`, `dl`, or `ssh`) from `Root-Repository/blueprints/producer/topic/{schema_type}` to `Root-Repository/producer/topic/{schema_type}` if **process_type is topic**.
5. Rename the copied `{schema_type}` folder to `{product_type}` (e.g. rename `eq` to `eq-dp-01`). Only hyphens are permitted as special characters; **all other special characters are disallowed**.
6. Ensure the `product_type` value is passed consistently during the CI pipeline run. This `product_type` defines the name of the data product being published. In some cases the term `product_name` is used which has the same value. 

**Note** The `product_type` value needs to exactly match the folder name of the data product in the dpn-data-pipelines repository otherwise pipeline execution will fail. 

```text
Root-Repository
  └── producer
        └── file
              └── {product_type}   <- e.g. eq-sample-1
                    ├── adaptor
                    │     └── charts
                    │           └── values.yaml
                    └── schema_mapper
                          └── charts
                                └── values.yaml
        └── topic
              └── {product_type}   <- e.g. eq-sample-1
                    ├── adaptor
                    │     └── charts
                    │           └── values.yaml
                    └── schema_mapper
                          └── charts
                                └── values.yaml                                
```

## Step2: Setup Data Consumers From Blueprint

The following step is required when an organisation is consuming data products:

1. Define the **process_type** file/topic integration pathway for the subscribed data product.
2. Copy the consumer folder from `Root-Repository/blueprints/consumer/file` to `Root-Repository/consumer/file` as-is, without modification, if **process_type is file**.
3. Copy the consumer folder from `Root-Repository/blueprints/consumer/topic` to `Root-Repository/consumer/topic` as-is, without modification, if **process_type is topic**.

```text
Root-Repository
  └── consumer
        └── file
              ├── extractor
              │     └── charts
              │           └── values.yaml
              └── schema_mapper
                    └── charts
                          └── values.yaml
        └── topic
              ├── extractor
              │     └── charts
              │           └── values.yaml
              └── schema_mapper
                    └── charts
                          └── values.yaml                
```

> **Note:** The `values.yaml` file can be replicated for multiple environments or DPN deployments (e.g. `values-<env>-dpn01.yaml`, `values-<env>-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](00-common-dpn-configuration.md#step22-azure-environment-configuration) section.

## Step3: Setup Producer Helm Charts

### Step3a: Set Up Producer Helm Charts For File Based Pathways

The values.yaml file created in Step 1 for a specific data product running in a specific environment must be modified as follows, for both the producer adaptor and schema mapper, using **file** based integration pathway. Most parameters are shared across both stages; where a parameter applies to only one stage this is called out explicitly.

> **Note:** `srcContainerName` applies to the **adaptor only** — it reads the source file. `mapperContainerName`/`mapperTopicName` reuse the same name across stages but the role flips: it is the adaptor's *output* and the schema mapper's *input*. `targetContainerName`/`targetTopicName` are always the schema mapper's output.

**Identity & Image**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| name | Helm release / resource name for this deployment instance | `producer-file-mapper-example` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| acrName | Azure Container Registry name to pull images from (when `cloudProviderType: azure`) | `""` (leave empty if not applicable) |
| imageName | Image name in the DSI registry | `{image name of adaptor or schema_mapper}` |
| imageTag | Image tag to deploy | `latest` |
| productType | Product type name — alphanumeric and hyphens only | `eq-sample-1` |
| PRODUCT_NAME | Runtime env var alias of `productType` — same value, consumed by application code rather than Helm templating (see [Step1](#step1-setup-a-new-data-product-from-blueprint)) | `eq-sample-1` |
| orgName | Organisation name abbreviation (no spaces) | `orga` |
| schemaType | Schema type | `eq` / `eqbd` / `dl` / `ssh` |

**Storage**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| srcContainerName | Source storage container name (**adaptor only**) | `eq-sample-1-stage` |
| mapperContainerName | Storage container name for the mapper stage | `eq-sample-1-raw` |
| targetContainerName | Storage container name for the target stage | `eq-sample-1-target` |
| storageConnectionSecret | Kubernetes secret holding the storage connection string(s) for this stage — see [Step8a](#step8a-configure-storage-secrets) | `producer-file-dp-secret` |

**AWS S3** (only when `cloudProviderType: aws`)

| Parameter | Purpose | Example |
|-----------|---------|---------|
| awsEndpointUrl | Custom S3 endpoint URL, if not using the default AWS endpoint | `""` (leave empty to use the AWS default) |
| awsRegion | AWS region for the S3 bucket(s) | `us-east-1` |
| awsAccessSecret | Kubernetes secret holding AWS access credentials | `aws-access-secret` |

**Kafka Connectivity**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| bootstrapServer | Kafka bootstrap server address for this stage | `dpn-kafka.ns-dpn-01.svc.cluster.local:9092` |
| mapperTopicName | Kafka topic name for the mapper stage | `dpn-producer-eq-sample-1-raw` |
| targetTopicName | Kafka topic name for the target stage | `dpn-producer-eq-sample-1-target` |

Kafka authentication (SASL/TLS/OAuth) is configured separately from topic naming — see [Step8b: Configure Kafka Security (SASL/TLS)](#step8b-configure-kafka-security-sasltls).

**Scheduling & Scaling**

`SCHEDULER_BACKEND`, `EXECUTION_MODE`, `scheduleInterval`, `PIPELINE_CONTROL_TOPIC`, and `PIPELINE_STATUS_TOPIC` also live in this values.yaml — see [Step6: Configure Scheduling](#step6-configure-scheduling) for the full parameter set and behavior. `replicaCount` and the `hpa.*` block are covered in [Step5: Configure Horizontal Pod Autoscaler (HPA)](#step5-configure-horizontal-pod-autoscaler-hpa).

**Observability**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| STATSD_HOST | StatsD host for metrics emission (leave empty to disable) | `""` |
| STATSD_PORT | StatsD port | `8125` |
| SERVICE_NAME | Service name reported to tracing/metrics backends | `dpn data pipeline` |
| SERVICE_VERSION | Service version reported to tracing/metrics backends | `1.0.0` |
| OTEL_EXPORTER_OTLP_ENDPOINT | OTel collector's OTLP endpoint. Defaults to the HTTPS endpoint on port `4318` | `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4318` |
| OTEL_EXPORTER_OTLP_INSECURE | Whether the OTLP endpoint above is called over plaintext. Defaults to `false` (HTTPS, port `4318`) | `false` |
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

The values.yaml file created in Step 1 for a specific data product running in a specific environment must be modified as follows, for both the producer adaptor and schema mapper, using **topic** based integration pathway. As with the file pathway, most parameters are shared across both stages; where a parameter applies to only one stage this is called out explicitly.

> **Note:** `srcTopicName` and `srcGroupId` apply to the **adaptor only** — it consumes from the upstream source topic. `mapperTopicName` reuses the same name across stages but the role flips: it is the adaptor's *output* and the schema mapper's *input*. `targetTopicName` is the schema mapper's output only.

**Identity & Image**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| name | Helm release / resource name for this deployment instance | `producer-topic-adaptor-example` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| acrName | Azure Container Registry name to pull images from (when `cloudProviderType: azure`) | `""` (leave empty if not applicable) |
| imageName | Image name in the DSI registry | `{image name of adaptor or schema_mapper}` |
| imageTag | Image tag to deploy | `latest` |
| productType | Product type name — alphanumeric and hyphens only | `eq-sample-1` |
| PRODUCT_NAME | Runtime env var alias of `productType` — same value, consumed by application code rather than Helm templating (see [Step1](#step1-setup-a-new-data-product-from-blueprint)) | `eq-sample-1` |
| orgName | Organisation name abbreviation (no spaces) | `orga` |
| schemaType | Schema type | `eq` / `eqbd` / `dl` / `ssh` |

> **Note:** a manual reference `values.yaml` for this pathway's adaptor may set only `PRODUCT_NAME` and omit `productType`/`cloudProviderType` outright. Confirm whether those are injected by the CI pipeline in your environment before assuming they can be dropped.

**Kafka Connectivity**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| bootstrapServer | Kafka bootstrap server address for this stage | `dpn-kafka.ns-dpn-01.svc.cluster.local:9092` |
| srcTopicName | Kafka topic name for the adaptor input stage (**adaptor only**) | `dpn-producer-eq-sample-1-src` |
| mapperTopicName | Kafka topic name for the adaptor-out / mapper-in stage | `dpn-producer-eq-sample-1-raw` |
| targetTopicName | Kafka topic name for the mapper-out / target-in stage (**schema mapper only**) | `dpn-producer-orga-eq-eq-sample-1-target` {Automatically created} |
| srcGroupId | Kafka consumer group for the adaptor's source topic (**adaptor only**) | `producer-topic-adaptor-eq-sample-1` |
| consumerRetryDelaySecs | Delay, in seconds, before retrying a failed consume | `5` |
| TOPIC_TASK_TIMEOUT_SECS | Timeout, in seconds, for processing a single topic message/task | `60` |
| DRAIN_IDLE_SECS | Idle time, in seconds, with no new messages before the consumer stops draining the topic | `15` |

Kafka authentication (SASL/TLS/OAuth) is configured separately from topic naming — see [Step8b: Configure Kafka Security (SASL/TLS)](#step8b-configure-kafka-security-sasltls).

**Scheduling & Scaling**

`SCHEDULER_BACKEND`, `EXECUTION_MODE`, and `replicaCount` also live in this values.yaml — see [Step6: Configure Scheduling](#step6-configure-scheduling) and [Step5: Configure Horizontal Pod Autoscaler (HPA)](#step5-configure-horizontal-pod-autoscaler-hpa) for the full parameter sets.

**Observability**

Most of the observability block documented for the file pathway (`SERVICE_NAME` / `SERVICE_VERSION`, `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_INSECURE`, `ENVIRONMENT`) applies here unchanged — see the Observability table under [Step3a](#step3a-set-up-producer-helm-charts-for-file-based-pathways).

> **Note:** the topic pathway's reference `values.yaml` sets the StatsD port via the Helm value `statsdPort` (e.g. `8125`) rather than the `STATSD_HOST` / `STATSD_PORT` env vars used on the file pathway, and does not set a StatsD host equivalent. Confirm which of the two your chart version actually consumes before copying values across pathways.

## Step4: Setup Consumer Helm Charts

### Step4a: Setup Consumer Helm Charts For File Based Integration Pathway

The values.yaml file created in Step 2 for all data products running in a specific environment must be modified as follows, for both the consumer extractor and schema mapper using **file** based integration pathway

**Identity & Image**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| name | Helm release / resource name for this deployment instance | `consumer-file-extractor` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| acrName | Azure Container Registry name to pull images from (when `cloudProviderType: azure`) | `""` (leave empty if not applicable) |
| imageName | Image name in the DSI registry | `{image name of extractor or consumer_mapper}` |
| imageTag | Image tag to deploy | `latest` |

**Storage**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| srcContainerName | Source storage container name | `dp-consumer-stage` |
| mapperContainerName | Storage container name for the mapper stage | `dp-consumer-trfm` |
| targetContainerName | Storage container name for the target stage | `dp-consumer-target` |
| storageConnectionSecret | Kubernetes secret holding the storage connection string(s) for this stage — see [Step8a](#step8a-configure-storage-secrets) | `consumer-file-dp-secret` |

**AWS S3** (only when `cloudProviderType: aws`)

| Parameter | Purpose | Example |
|-----------|---------|---------|
| awsEndpointUrl | Custom S3 endpoint URL, if not using the default AWS endpoint | `""` (leave empty to use the AWS default) |
| awsRegion | AWS region for the S3 bucket(s) | `us-east-1` |
| awsAccessSecret | Kubernetes secret holding AWS access credentials | `aws-access-secret` |

**Kafka Connectivity**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| bootstrapServer | Kafka bootstrap server address for this stage | `dpn-kafka-target.ns-dpn-01.svc.cluster.local:9092` |
| mapperTopicName | Kafka topic name for the extractor out and mapper in stage | `dp-consumer-file-trfm` |
| targetTopicName | Kafka topic name for the mapper out and target in stage | `dp-consumer-file-target` |
| DRAIN_IDLE_SECS | Idle time, in seconds, with no new messages before the consumer stops draining the topic | `15` |
| topicTaskTimeoutSecs | Timeout, in seconds, for processing a single topic message/task. Note the reference `values.yaml` for this pathway uses this lower/camel-case name rather than the `TOPIC_TASK_TIMEOUT_SECS` env var seen on the topic pathway — confirm which your chart version reads before copying values across pathways | `60` |

Kafka authentication (SASL/TLS/OAuth) is configured separately from topic naming — see [Step8b: Configure Kafka Security (SASL/TLS)](#step8b-configure-kafka-security-sasltls).

**Scheduling & Scaling**

`SCHEDULER_BACKEND`, `EXECUTION_MODE`, `scheduleInterval`, `PIPELINE_CONTROL_TOPIC`, and `PIPELINE_STATUS_TOPIC` also live in this values.yaml — see [Step6: Configure Scheduling](#step6-configure-scheduling) for the full parameter set and behavior. `replicaCount` and the `hpa.*` block are covered in [Step5: Configure Horizontal Pod Autoscaler (HPA)](#step5-configure-horizontal-pod-autoscaler-hpa).

**Observability**

`SERVICE_NAME` / `SERVICE_VERSION`, `PRODUCT_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_INSECURE`, and `ENVIRONMENT` apply here as documented in the Observability table under [Step3a](#step3a-set-up-producer-helm-charts-for-file-based-pathways).

> **Note:** the file-based consumer's reference `values.yaml` sets only `STATSD_PORT` (no `STATSD_HOST` equivalent).

### Step4b: Setup Consumer Helm Charts For Topic Based Integration Pathway

The values.yaml file created in Step 2 for all data products running in a specific environment must be modified as follows, for both the consumer extractor and schema mapper using **topic** based integration pathway

**Identity & Image**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| name | Helm release / resource name for this deployment instance | `dpn-consumer-topic-eq-neso-oil-adaptor` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| imageName | Image name in the DSI registry | `{image name of extractor or consumer_mapper}` |

**Kafka Connectivity**

| Parameter | Purpose | Example |
|-----------|---------|---------|
| bootstrapServer | Kafka bootstrap server address for this stage | `dpn-kafka-target.ns-dpn-01.svc.cluster.local:9092` |
| srcTopicName | Kafka topic name for the extractor in stage | `dp-consumer-topic-stage` |
| srcGroupId | Kafka consumer group for the extractor's source topic | `consumer_topic_eqbd_pg_gas_test` |
| mapperTopicName | Kafka topic name for the extractor out and mapper in stage | `dp-consumer-topic-trfm` |
| targetTopicName | Kafka topic name for the mapper out and target in stage | Not Required, Auto Created from metadata |
| consumerRetryDelaySecs | Delay, in seconds, before retrying a failed consume | `5` |
| TOPIC_TASK_TIMEOUT_SECS | Timeout, in seconds, for processing a single topic message/task | `60` |
| DRAIN_IDLE_SECS | Idle time, in seconds, with no new messages before the consumer stops draining the topic | `15` |

Kafka authentication (SASL/TLS/OAuth) is configured separately from topic naming — see [Step8b: Configure Kafka Security (SASL/TLS)](#step8b-configure-kafka-security-sasltls).

**Scheduling & Scaling**

`PRODUCT_NAME`, `SCHEDULER_BACKEND`, `EXECUTION_MODE`, `scheduleInterval`, `PIPELINE_CONTROL_TOPIC`, and `PIPELINE_STATUS_TOPIC` also live in this values.yaml — see [Step6: Configure Scheduling](#step6-configure-scheduling) for the full parameter set and behavior. `replicaCount` and the `hpa.*` block are covered in [Step5: Configure Horizontal Pod Autoscaler (HPA)](#step5-configure-horizontal-pod-autoscaler-hpa).

**Observability**

`SERVICE_NAME` / `SERVICE_VERSION`, `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_INSECURE`, and `ENVIRONMENT` apply here as documented in the Observability table under [Step3a](#step3a-set-up-producer-helm-charts-for-file-based-pathways).

> **Note:** as with the topic-based producer, the reference `values.yaml` here sets the StatsD port via the Helm value `statsdPort` (e.g. `8125`) rather than `STATSD_HOST` / `STATSD_PORT`, and does not set a StatsD host equivalent.

DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

> **Naming conventions**

Organisations must adopt the following naming convention

> - Storage container names, Kafka topic names, Kafka consumer group IDs, and product type names must use only alphanumeric characters and hyphens (`-`). No other special characters (including underscores) are permitted.
> - Organisation names must be abbreviated without spaces.
> - Schema type must match the blueprint schema type exactly: `eq`, `eqbd`, `dl`, or `ssh`.

## Step5: Configure Horizontal Pod Autoscaler (HPA)

Each adaptor, schema_mapper, and extractor Deployment can scale horizontally based on load, rather than running a fixed `replicaCount`. This requires the Kubernetes **metrics-server** to be running in the AKS cluster (standard on AKS by default).

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

> **Note:** when `hpa.enabled: true`, the chart's `replicaCount` value is treated only as the **initial** replica count at first deploy — the HPA controller owns the replica count from that point on. Do not rely on `replicaCount` to reflect the running pod count once HPA is active; check `kubectl get hpa` instead.

> **Note:** `hpa.enabled` defaults to `false`. Leave it disabled while `SCHEDULER_BACKEND: interval` is in use (see [Step6](#step6-configure-scheduling)) — interval-based scheduling does not partition work across replicas, so scaling out under that backend does not safely distribute load. Only enable HPA once the stage's trigger/partitioning model actually supports concurrent replicas (e.g. `kafka-trigger` consumption over a partitioned topic).

Recommended starting point: enable HPA on `adaptor` and `schema_mapper` stages, which see variable load depending on file/message volume; leave `extractor` at a fixed `replicaCount` initially unless consumer-side volume is also expected to vary significantly, then revisit.

## Step6: Configure Scheduling

Each data pipeline stage (adaptor, schema mapper, extractor) is triggered in one of two ways: **Automated Scheduling** or **Manual Scheduling**. Which one applies is controlled by the `SCHEDULER_BACKEND` parameter in that stage's `values.yaml`.

#### Option A: Helm Configure Scheduling Using Airflow

Under automated scheduler, the pipeline stage is started by a software trigger rather than by an operator. The trigger mechanism is a pair of shared Kafka topics:

### Scheduler Backend Options

| Value | Description |
|---------|---------|
| `kafka-trigger` | Event-driven execution. The pipeline waits for a trigger message on the configured Kafka control topic before starting a run. Recommended for Kubernetes deployments and orchestrated workflows controlled via Apache Airflow. DSI uses this configuration to automate the pipeline runs |
| `interval` | Schedule-based execution. The pipeline runs repeatedly according to the configured `scheduleInterval` without airflow |

There are other options available i.e. standalone but not exercised as part of DSI package.

### Behavior

- With **`SCHEDULER_BACKEND=kafka-trigger`**, a message published to `PIPELINE_CONTROL_TOPIC` starts a run, and the pipeline reports progress to `PIPELINE_STATUS_TOPIC`.This message is pushed via Airflow.
- With **`SCHEDULER_BACKEND=interval`**, the pipeline runs automatically at the configured `scheduleInterval` when `EXECUTION_MODE=automatic`.There is no intervention of Airflow based scheduling


| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Set to `kafka-trigger` to enable  Airflow triggered scheduling | `kafka-trigger` |
| PIPELINE_CONTROL_TOPIC | Kafka topic the pipeline stage listens on for a start signal | `dpn-pipeline-control` |
| PIPELINE_STATUS_TOPIC | Kafka topic the pipeline stage publishes run status/progress to | `dpn-pipeline-status` |
| EXECUTION_MODE | `automatic` — the stage self-schedules on `scheduleInterval`| `automatic` |
| scheduleInterval | Polling interval in seconds. Only used when `EXECUTION_MODE: automatic` | `60` |

A message published to `PIPELINE_CONTROL_TOPIC` starts a run; the pipeline stage reports progress back on `PIPELINE_STATUS_TOPIC`. No operator action is required once this is configured — this is why it's referred to as automated.

#### Option B: Helm Configure Scheduling Without Airflow

Manual scheduler requires Organisations to start pipeline manually and monitor the execution

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Set to `airflow` to hand scheduling control to Airflow instead of the Kafka control topic | `airflow` |

## Step7: Onboard a New Data Product on Airflow Scheduler

Scheduling configuration on Airflow is **not created automatically** — a Direct Acyclic Graph (DAG) must be added alongside every new data product using `SCHEDULER_BACKEND: airflow`, in addition to the steps in [Producer Setup](#step1-setup-a-new-data-product-from-blueprint).

```text
Root-Repository
  └── charts
        └── airflow/
              ├── values-<env>-dpn01.yaml   <- Environment-specific Airflow overrides
              └── dags/
                    └── {product_type}.py   <- One DAG per data product
```

Every existing DAG under `charts/airflow/dags/` is a copy of the same template — a four-task chain (`trigger_adaptor` → `wait_adaptor_done` → `trigger_schema_mapper` → `wait_schema_mapper_done`) driving the already-running adaptor/schema_mapper pods over Kafka. The `file`-pathway reference DAG (`dpn_producer_file_bp_natural_gas.py`) documents this explicitly in its own docstring and isolates everything that changes per product into one block:

```python
# ── Product identity ──────────────────────────────────────────────────────────
# These are the only three lines that change when you copy this DAG for another product.
PRODUCT         = "bp-natural-gas"
PIPELINE_TYPE   = "file"
PIPELINE_ROLE   = "producer"

BOOTSTRAP_SERVER = "dpn-kafka-src:9092"
SCHEDULE         = '*/3 * * * *'
```

**Cron Expression Format**

The SCHEDULE field above uses a cron scheduler expression format. The cron expression is evaluated in the following way.

```text
* * * * *
│ │ │ │ │
│ │ │ │ └── Day of Week (0-7) (Sunday = 0 or 7)
│ │ │ └──── Month (1-12)
│ │ └────── Day of Month (1-31)
│ └──────── Hour (0-23)
└────────── Minute (0-59)
```

**Example Cron Expression**

```text
*/3 * * * *
│   │ │ │ │
│   │ │ │ └── Every day of the week
│   │ │ └──── Every month
│   │ └────── Every day of the month
│   └──────── Every hour
└──────────── Every 3 minutes
```

To onboard a new product:

- Copy `dpn_producer_file_bp_natural_gas.py` (recommended, over a `topic`-pathway DAG — see the note below) and rename the file to `dpn_producer_{pathway}_{product_type}.py`, following the existing naming convention.

- Update the **Product identity** block: `PRODUCT` to the new `product_type`, `PIPELINE_TYPE` to `file` or `topic` as appropriate, and `BOOTSTRAP_SERVER`/`SCHEDULE` if they differ from the default.

- Update the DAG definition's `dag_id` and `tags` to match the new product (e.g. `dag_id="producer_file_<product_type>"`, `tags=["dpn", "producer", "file", "<product_type>", "kafka-trigger"]`).

- Nothing else needs to change — the four-task chain, the `PipelineStatusSensor`, and the trigger-publishing logic are all generic and read `PRODUCT`/`PIPELINE_TYPE`/`PIPELINE_ROLE` rather than hardcoding product-specific behaviour.

- Set `SCHEDULER_BACKEND: airflow` on the product's `values.yaml` to match.

> **Operational notes:**
> - The `kafka-trigger` backend now auto-creates the shared `dpn-pipeline-control`/`dpn-pipeline-status` topics on first use if they don't already exist, avoiding a race against topic auto-creation on a freshly provisioned broker.
> - Every trigger/status log line now carries a consistent `component.name` attribute (e.g. `producer-file-adaptor`), making it easier to filter one pipeline stage's Airflow-side logs from another downstream in the OTel/Kibana pipeline.
> - The Airflow init job now idempotently creates a custom `DagOperator` role (trigger/pause/view on DAGs, DAG Runs, and Task Instances — no delete, no Connections/Variables/Pools/Config access), mapped from the Keycloak **group** `dpn-operators` (Keycloak group membership, not a realm role name, is what FAB reads from the OAuth userinfo `groups` claim). This gives day-to-day pipeline operators Airflow access without the broader built-in `Op` role.
> - The Airflow webserver now terminates TLS itself rather than relying on an in-front oauth2-proxy: it reads a real `kubernetes.io/tls` certificate/key pair from a `dpn-health-tls` Secret (SAN covering `*.ns-dpn-01.svc.cluster.local`), and its Service/LoadBalancer port has moved from `80` to `8080` (`https`). Update any bookmarked/firewalled Airflow UI URL accordingly, and provision `dpn-health-tls` before upgrading. The `AIRFLOW_OIDC_CLIENT_SECRET` used for Keycloak SSO now also comes from `dpn-keycloak-secrets`/`KC_SERVICE_CLIENT_SECRET`, matching the Kafka client secret change in [Step8b](#step8b-configure-kafka-security-sasltls).

## Step8: Configure Secrets

DSI Data Pipeline uses Kubernetes secrets by design, as this is a Bring-Your-Own (BYO) component. Storage credentials and Kafka authentication material are two separate secret concerns, covered in Step8a and Step8b respectively.

### Step8a: Configure Storage Secrets

Two secret objects are created for storage access — one for Producer and one for Consumer.

> - Producer secret name: `producer-<processType>-dp-secret`
> - Consumer secret name: `consumer-<processType>-dp-secret`
> - `<processType>` is `file` for the file-based pathway, or `topic` for the topic-based pathway. Future values may include `rest`, etc.

**Producer Secrets**

The producer secrets contain the storage account connection strings and SAS tokens for each stage. The connection string format is:

```text
https://<storage-account>.blob.core.windows.net/?<sas-token>
```

The secret object `producer-<processType>-dp-secret` contains the following. If the same storage account is used for all stages, the same connection string value may be used for all three:

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Blob Storage connection string for the source storage account |
| MAPPER_CONNECTION_STRING | Blob Storage connection string for the mapper storage account |
| TARGET_CONNECTION_STRING | Blob Storage connection string for the target storage account |

Create the producer secret using the following command:

```bash
kubectl create secret generic producer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=MAPPER_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob mapper connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```

**Consumer Secrets**

The secret object `consumer-<processType>-dp-secret` contains the following. If the same storage account is used for all stages, the same connection string value may be used for all three:

| Variable | Description |
|----------|-------------|
| SRC_CONNECTION_STRING | Blob Storage connection string for the consumer source storage account |
| MAPPER_CONNECTION_STRING | Blob Storage connection string for the consumer mapper storage account |
| TARGET_CONNECTION_STRING | Blob Storage connection string for the consumer target storage account |

Create the consumer secret using the following command:

```bash
kubectl create secret generic consumer-file-dp-secret \
  --from-literal=SRC_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob source connection string>' | base64)" \
  --from-literal=MAPPER_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob mapper connection string>' | base64)" \
  --from-literal=TARGET_CONNECTION_STRING="$(echo -n 'BlobEndpoint=<your blob target connection string>' | base64)" \
  -n <your namespace>
```

### Step8b: Configure Kafka Security (SASL/TLS)

Every stage that connects to Kafka — producer adaptor/schema mapper and consumer extractor/schema mapper alike — authenticates using SASL over TLS, with OAuth2 client-credentials issued by Keycloak. These are set directly in each stage's `values.yaml`, alongside `bootstrapServer` (see [Step3a](#step3a-set-up-producer-helm-charts-for-file-based-pathways)):

| Parameter | Purpose | Example |
|-----------|---------|---------|
| KAFKA_SECURITY_PROTOCOL | Transport security for the Kafka connection | `SASL_SSL` (set to `SSL` or `PLAINTEXT` to opt out) |
| KAFKA_SASL_MECHANISM | SASL mechanism | `OAUTHBEARER` (OAuth2 client-credentials via Keycloak) |
| KAFKA_OAUTH_CLIENT_ID | Keycloak service-account client ID | `dpn-service-client` |
| KAFKA_OAUTH_TOKEN_ENDPOINT_URL | Keycloak realm token endpoint | `https://dpn-keycloak.<namespace>.svc.cluster.local:8443/realms/dpn-realm/protocol/openid-connect/token` |
| KAFKA_SSL_CA_LOCATION | Path of a plain CA certificate PEM mounted inside the pod, alongside the existing `truststore.jks` mount | `/etc/secrets/ca.crt` |
| kafkaTlsSecretName | Kubernetes secret providing the `dpn-tls` volume, now mounted at both `/etc/secrets/truststore.jks` (subPath `truststore.jks`) and `/etc/secrets/ca.crt` (subPath `ca.crt`) — the secret must carry both keys | `dpn-tls` |
| kafkaOauthSecretName | Kubernetes secret providing the OAuth2 client credentials (`KC_SERVICE_CLIENT_SECRET`) | `dpn-keycloak-secrets` |

> **Note:** the OAuth2 client secret and the truststore password now come from **two separate secrets**: `kafkaOauthSecretName` (default `dpn-keycloak-secrets`) supplies `KC_SERVICE_CLIENT_SECRET` — the previous key name, `KAFKA_OAUTH_CLIENT_SECRET`, has been retired — while the `TRUSTSTORE_PASSWORD` env var (used to open the PKCS12 `truststore.jks`) is always read from a fixed `kafka-secrets` secret's `KC_HTTPS_TRUST_STORE_PASSWORD` key, regardless of `kafkaOauthSecretName`. This replaces the old `UNIVERSAL_DPN_CERT_PASSWORD` key, which was actually the keystore-password family and only happened to share a value with the truststore password. Exact secret key names and the OAuth token exchange flow are documented in the chart's own `README.md` under "Kafka Authentication" — refer there before provisioning `kafkaTlsSecretName` / `kafkaOauthSecretName` for a new environment.

---

## Step9: Configure DPN Data Store

The DPN Data Store consists of two sub-components:

- **Storage Blob / S3** — File storage for pipeline artefacts
- **Kafka Streaming Service** — Event streaming between DPN components

### Step9a: Storage Blob / S3 Configuration

Storage Blob / S3 is the integration layer between the organisation's internal data source, the Federator Gateway, Data Pipelines, and the data destination.

The file-based integration pathway requires a set of storage containers (buckets) to be defined upfront, based on the data product template in use. The following naming convention is recommended when provisioning containers:

| Process | Source Container Name | Target Container Name |
|---------|-----------------------|-----------------------|
| adaptor | `{product_type}-stage` | `{product_type}-raw` |
| producer-mapper | `{product_type}-raw` | `{product_type}-target` |
| extractor | `dp-consumer-stage` | `dp-consumer-trfm` |
| consumer-mapper | `dp-consumer-trfm` | `dp-consumer-target` |

```text
Example container names (product_type = eq-sample-1):

  eq-sample-1-stage
  eq-sample-1-raw
  eq-sample-1-target
  dp-consumer-stage
  dp-consumer-trfm
  dp-consumer-target
```

> **Note:** Each storage container is mapped to a single data product type on the producer side. One data product type carries a single version of the file at any given time (e.g. the `eq-sample-1-raw` container contains `sample_1_v1.xml` only, until a version revision changes it to `sample_1_v2.xml`).

> **Note:** Storage containers are accessed asynchronously by the Federator Gateway and the organisation's data source and destination to pick up and deposit files.

---

### Step9b: Configure Streaming Service (Kafka)

The DPN Streaming Service uses Kafka to emit events between DPN components, including the Data Pipeline adaptor, mapper, extractor, Federator Gateway, and organisation data source/destination endpoints.

The DPN data pipeline processes files by pushing streaming messages onto predefined Kafka topics. The proposed topic names are listed below. Organisations may customise the naming convention if required, but any topic name changes must be reflected in the CD pipeline configuration.

For file based integration pathway, the following convention is recommended

| Process | Source Topic Name | Target Topic Name | Bootstrap Server |
|---------|-------------------|-------------------|------------------|
| adaptor | N/A | `dpn-producer-{product_type}-raw` | `dpn-kafka-src:9092` |
| producer-mapper | `dpn-producer-{product_type}-raw` | `dpn-producer-{product_type}-target` | `dpn-kafka-src:9092` |
| extractor | N/A | `dp-consumer-topic-trfm` | `dpn-kafka-target:9092` |
| consumer-mapper | `dp-consumer-topic-trfm` | `dp-consumer-topic-target` | `dpn-kafka-target:9092` |

For streaming based integration pathway, the following convention is recommended

| Process | Source Topic Name | Target Topic Name | Bootstrap Server |
|---------|-------------------|-------------------|------------------|
| adaptor | `dpn-producer-{product_type}-stage` | `dpn-producer-{product_type}-raw` | `dpn-kafka-src:9092` |
| producer-mapper | `dpn-producer-{product_type}-raw` | `dpn-producer-{orgname}-{schema_type}-{product_type}-target` | `dpn-kafka-src:9092` |
| extractor | `dp-consumer-topic-stage` | `dp-consumer-topic-trfm` | `dpn-kafka-target:9092` |
| consumer-mapper | `dp-consumer-topic-trfm` | Auto created based on data product name in meta data | `dpn-kafka-target:9092` |


where **`product_type`** is the name of the data product name such as `eq-sample-1` as described in previous sections.

These topics must be pre-created via the Kafka UI before the `dpn-data-pipeline` CI and CD tasks are executed.

The Kafka message structure used by the DSI Data Pipeline follows the convention below. This enables the Federator Server to locate and retrieve the file from the specified storage location during file transfer:

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

> **Note:** Valid values for `sourceType` are `AZURE`, `GCP`, and `S3`. 

---

## Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 31-July-2026 | DSI Assurance | Final | V1.0.0 |
