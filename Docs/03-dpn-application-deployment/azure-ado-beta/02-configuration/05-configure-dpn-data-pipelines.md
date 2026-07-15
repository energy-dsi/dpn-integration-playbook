# DPN Data Pipeline Configuration

---

## Table of Contents

- [Overview](#overview)
- [Data Pipeline Blueprints](#data-pipeline-blueprints)
- [Step1: Setup a New Data Product From Blueprint](#step1-setup-a-new-data-product-from-blueprint)
- [Step2: Setup Data Consumers From Blueprint](#step2-setup-data-consumers-from-blueprint)
- [Step3: Setup Producer Helm Charts](#step3-setup-producer-helm-charts)
- [Step4: Setup Consumer Helm Charts](#step4-setup-consumer-helm-charts)
- [Step5: Configure Horizontal Pod Autoscaler (HPA)](#step5-configure-horizontal-pod-autoscaler-hpa)
- [Step6: Configure Scheduling](#step6-configure-scheduling)
  - [Option A: Helm Configure Automated Scheduling Using Airflow](#option-a-helm-configure-automated-scheduling-using-airflow)
  - [Option B: Helm Configure Manual Scheduling Without Airflow](#option-b-helm-configure-manual-scheduling-without-airflow)
- [Step7: Onboard a New Data Product on Airflow Scheduler](#step7-onboard-a-new-data-product-on-airflow-scheduler)
- [Step8: Configure Secrets](#step8-configure-secrets)
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

1. Define the **`product_type`** name — the identifier for the data product being published. Each product type must conform to one of the schema types available in the blueprints.
2. Define the **`process_type`** - file/topic for the data product.
3. Copy the relevant schema folder (e.g. `eq`, `eqbd`, `dl`, or `ssh`) from `Root-Repository/blueprints/producer/file/{schema_type}` to `Root-Repository/producer/file/{schema_type}` if **process_type is file**.
4. Copy the relevant schema folder (e.g. `eq`, `eqbd`, `dl`, or `ssh`) from `Root-Repository/blueprints/producer/topic/{schema_type}` to `Root-Repository/producer/topic/{schema_type}` if **process_type is topic**.
5. Rename the copied `{schema_type}` folder to `{product_type}` (e.g. rename `eq` to `eq-dp-01`). Only hyphens are permitted as special characters; **all other special characters are disallowed**.
6. Ensure the `product_type` value is passed consistently during the CI pipeline run.

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

> **Note:** The `values.yaml` file can be replicated for multiple environments or DPN deployments (e.g. `values-<env>-dpn01.yaml`, `values-<env>-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section.

## Step3: Setup Producer Helm Charts

The values.yaml file created in Step 1 for a specific data product running in a specific environment must be modified as follows, for both the producer adaptor and schema mapper.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| imageName | Image name in the DSI registry | `{image name of adaptor or schema_mapper}` |
| productType | Product type name — alphanumeric and hyphens only | `eq-sample-1` |
| srcContainerName | Source storage container name | `eq-sample-1-stage` |
| mapperTopicName | Kafka topic name for the mapper stage | `dpn-producer-eq-sample-1-raw` |
| mapperContainerName | Storage container name for the mapper stage | `eq-sample-1-raw` |
| targetTopicName | Kafka topic name for the target stage | `dpn-producer-eq-sample-1-target` |
| targetContainerName | Storage container name for the target stage | `eq-sample-1-target` |
| orgName | Organisation name abbreviation (no spaces) | `orga` |
| schemaType | Schema type | `eq` / `eqbd` / `dl` / `ssh` |

## Step4: Setup Consumer Helm Charts

The values.yaml file created in Step 2 for all data products running in a specific environment must be modified as follows, for both the consumer extractor and schema mapper.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| namespace | Name of the Kubernetes namespace | `ns-dpn-01` |
| cloudProviderType | Cloud provider to run on | `azure` / `aws` / `gcp` |
| imageName | Image name in the DSI registry | `{image name of extractor or consumer_mapper}` |
| srcContainerName | Source storage container name | `dp-consumer-stage` |
| mapperTopicName | Kafka topic name for the mapper stage | `dpn-consumer-trfm` |
| mapperContainerName | Storage container name for the mapper stage | `dp-consumer-trfm` |
| targetTopicName | Kafka topic name for the target stage | `dpn-consumer-target` |
| targetContainerName | Storage container name for the target stage | `dp-consumer-target` |


DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

> **Naming conventions**

Organisations must adopt the following naming convention

> - Storage container names, Kafka topic names, and product type names must use only alphanumeric characters and hyphens (`-`). No other special characters are permitted.
> - Organisation names must be abbreviated without spaces.
> - Schema type must match the blueprint schema type exactly: `eq`, `eqbd`, `dl`, or `ssh`.

## Step5: Configure Horizontal Pod Autoscaler (HPA)

Each adaptor, schema_mapper, and extractor Deployment can scale horizontally based on load, rather than running a fixed `replicaCount`. This requires the Kubernetes **metrics-server** to be running in the AKS cluster (standard on AKS by default).

| Parameter | Purpose | Example |
|-----------|---------|---------|
| hpa.enabled | Enables the Horizontal Pod Autoscaler for this stage | `true` |
| hpa.minReplicas | Minimum pod count, including at idle | `1` |
| hpa.maxReplicas | Maximum pod count under peak load | `5` |
| hpa.targetCPUUtilizationPercentage | Average CPU utilisation (as % of requested CPU) that triggers scale-out | `70` |
| hpa.targetMemoryUtilizationPercentage | Average memory utilisation (as % of requested memory) that triggers scale-out | `80` |

> **Note:** when `hpa.enabled: true`, the chart's `replicaCount` value is treated only as the **initial** replica count at first deploy — the HPA controller owns the replica count from that point on. Do not rely on `replicaCount` to reflect the running pod count once HPA is active; check `kubectl get hpa` instead.

Recommended starting point: enable HPA on `adaptor` and `schema_mapper` stages, which see variable load depending on file/message volume; leave `extractor` at a fixed `replicaCount` initially unless consumer-side volume is also expected to vary significantly, then revisit.

## Step6: Configure Scheduling

Each data pipeline stage (adaptor, schema mapper, extractor) is triggered in one of two ways: **Automated Scheduling** or **Manual Scheduling**. Which one applies is controlled by the `SCHEDULER_BACKEND` parameter in that stage's `values.yaml`.

#### Option A: Helm Configure Automated Scheduling Using Airflow

Under automated scheduler, the pipeline stage is started by a software trigger rather than by an operator. The trigger mechanism is a pair of shared Kafka topics. 

The scheduler configuration is present under the same values.yaml files defined in step 3 and 4. These configurations to be reviewed for the data product pipeline Producer and Consumer.

The following parameters to be reviewed by Organisation if they want to use a separate scheduler or scheduling configuration other than automated.

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Set to `kafka-trigger` to enable software-triggered scheduling | `kafka-trigger` |
| PIPELINE_CONTROL_TOPIC | Kafka topic the pipeline stage listens on for a start signal | `dpn-pipeline-control` |
| PIPELINE_STATUS_TOPIC | Kafka topic the pipeline stage publishes run status/progress to | `dpn-pipeline-status` |
| EXECUTION_MODE | `automatic` — the stage self-schedules on `scheduleInterval` — or `manual` — the stage only runs when a message arrives on `PIPELINE_CONTROL_TOPIC` | `automatic` / `manual` |
| scheduleInterval | Polling interval in seconds. Only used when `EXECUTION_MODE: automatic` | `60` |

A message published to `PIPELINE_CONTROL_TOPIC` starts a run; the pipeline stage reports progress back on `PIPELINE_STATUS_TOPIC`. No operator action is required once this is configured — this is why it's referred to as automated.

#### Option B: Helm Configure Manual Scheduling Without Airflow

Manual scheduler requires Organisations to start pipeline manually and monitor the execution

| Parameter | Purpose | Example |
|-----------|---------|---------|
| SCHEDULER_BACKEND | Set to `airflow` to hand scheduling control to Airflow instead of the Kafka control topic | `airflow` |

## Step7: Onboard a New Data Product on Airflow Scheduler

Scheduling configuration on Airflow is **not created automatically** — a Direct Acyclic Graph (DAG) must be added alongside every new data product using `SCHEDULER_BACKEND: airflow`, in addition to the steps in [Producer Setup](#producer-setup).

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

To onboard a new product:

- Copy `dpn_producer_file_bp_natural_gas.py` (recommended, over a `topic`-pathway DAG — see the note below) and rename the file to `dpn_producer_{pathway}_{product_type}.py`, following the existing naming convention.

- Update the **Product identity** block: `PRODUCT` to the new `product_type`, `PIPELINE_TYPE` to `file` or `topic` as appropriate, and `BOOTSTRAP_SERVER`/`SCHEDULE` if they differ from the default.

- Update the DAG definition's `dag_id` and `tags` to match the new product (e.g. `dag_id="producer_file_<product_type>"`, `tags=["dpn", "producer", "file", "<product_type>", "kafka-trigger"]`).

- Nothing else needs to change — the four-task chain, the `PipelineStatusSensor`, and the trigger-publishing logic are all generic and read `PRODUCT`/`PIPELINE_TYPE`/`PIPELINE_ROLE` rather than hardcoding product-specific behaviour.

- Set `SCHEDULER_BACKEND: airflow` on the product's `values.yaml` to match.

## Step8: Configure Secrets

DSI Data Pipeline uses Kubernetes secrets by design, as this is a Bring-Your-Own (BYO) component. Two secret objects are created — one for Producer and one for Consumer.

> - Producer secret name: `producer-<processType>-dp-secret`
> - Consumer secret name: `consumer-<processType>-dp-secret`
> - `<processType>` is `file` for the file-based pathway in MVP. Future values may include `rest`, `topic`, etc.

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

| Process | Source Topic Name | Target Topic Name | Bootstrap Server |
|---------|-------------------|-------------------|------------------|
| adaptor | N/A | `dpn-producer-{product_type}-raw` | `dpn-kafka-src:9092` |
| producer-mapper | `dpn-producer-{product_type}-raw` | `dpn-producer-{product_type}-target` | `dpn-kafka-src:9092` |
| extractor | N/A | `dpn-consumer-trfm` | `dpn-kafka-target:9092` |
| consumer-mapper | `dpn-consumer-trfm` | `dpn-consumer-target` | `dpn-kafka-target:9092` |

where **`product_type`** is a value such as `eq-sample-1` as described in previous sections.

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
