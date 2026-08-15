# 04-federator-gateway — Disaster Recovery Runbook

This component is the Kafka backbone plus the "federator" data-movement pods, as scoped by the
client's component split: **federator server and client, Redis, Kafka src and target, Zookeeper
source and target** (plus Kafka UI for operability). Concretely that means two independent
single-broker Kafka/Zookeeper clusters (`src` and `target`), Kafka UI, Redis, and the
producer/consumer "adaptor/mapper/extractor" pods that run under the shared `federator-server`
ServiceAccount and physically move data between the two clusters (and to/from S3 for the
file-based pipelines). These pods are triggered by Kafka control-topic messages published by the
Airflow DAGs that live in `03-data-pipeline` — Airflow itself is out of scope here.

Everything under `manifests/` and `scripts/` in this folder is flat by design (no `deployments/`,
`services/`, `secrets/`, `iam/` subfolders) to match the layout used by the other 4 components.

## 1. Prerequisites

- `00-shared-prerequisites` has been applied (namespace `ns-dpn-01`, `federator-server`
  ServiceAccount, `ghcr-pull-secret`, StorageClass, etc.) — this component does **not** create
  the namespace or the ServiceAccount, only consumes them.
- AWS CLI credentials available locally with permission to create/inspect S3 buckets and IAM
  policies (an account-admin-ish identity for bootstrap — NOT the pipeline's own scoped IAM user,
  which doesn't exist yet at this point).
- `kubectl` reaching the target cluster.
- Soft dependency: `02-health-monitor` should ideally be up first, since these pods emit OTEL
  traces to `dpn-otel-collector.ns-dpn-health-01.svc.cluster.local:4317`. Not a hard blocker —
  pods will run fine without it, traces just won't land anywhere.

## 2. Configuration

Replace every placeholder below before applying anything. `ns-dpn-01` is fixed and must NOT be
changed.

| Placeholder | Meaning | Example |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | AWS account that owns the S3 buckets / IAM policy | `123456789012` |
| `<AWS_REGION>` | AWS region for S3 + the IAM policy | `eu-west-2` |
| `<S3_IAM_USER_NAME>` | IAM user the `S3Access` policy is attached to | `dpn01devuser` |
| `<S3_BUCKET_PREFIX>` | Prefix for the account-scoped "application" bucket, used consistently in `scripts/bootstrap-aws-resources.sh`, `scripts/s3-access-policy.json`, and every `S3_BUCKET_NAME` env var that references it | `dpn-dev-<AWS_ACCOUNT_ID>-<AWS_REGION>` (bucket becomes `<S3_BUCKET_PREFIX>-application`) |
| `<AWS_ACCESS_KEY_ID>` / `<AWS_SECRET_ACCESS_KEY>` | Credentials for the `aws-access-secret` Secret | — |

Other S3 bucket names (`bp-natural-gas-stage/raw/target`, `dp-consumer-stage/trfm/target`) are
kept as literal, descriptive defaults — they aren't secret, just names — and don't need
substitution.

**AWS credentials for `aws-access-secret`**: do not reuse broad account credentials. Create a
dedicated, least-privilege IAM user scoped to exactly the `S3Access` policy in
`scripts/s3-access-policy.json` (this is what `scripts/bootstrap-aws-resources.sh` provisions and
attaches to `<S3_IAM_USER_NAME>`), then generate an access key for that user and use it below.
`manifests/secret-aws-access-template.yaml` is a template only — the recommended path is to
create the Secret imperatively (section 3.2) so real key material never touches a file on disk.

## 3. Installation

### 3.1 Provision AWS resources (S3 + IAM)

```bash
export AWS_REGION=<AWS_REGION>
export AWS_ACCOUNT_ID=<AWS_ACCOUNT_ID>
export S3_IAM_USER=<S3_IAM_USER_NAME>
export S3_BUCKET_PREFIX=<S3_BUCKET_PREFIX>
sh scripts/bootstrap-aws-resources.sh
```

This creates all 7 required S3 buckets (the 6 descriptively-named ones plus
`${S3_BUCKET_PREFIX}-application`) and the `S3Access` IAM policy, then attaches the policy to
`S3_IAM_USER`. Idempotent — safe to re-run.

> **Bug fix applied in this reorg**: the original bootstrap script only created 6 buckets, but 4
> Deployments (`consumer-file-extractor`, `consumer-file-mapper`,
> `producer-file-adaptor-bp-natural-gas`, `producer-file-mapper-bp-natural-gas`) reference a 7th
> bucket via `S3_BUCKET_NAME` (`<S3_BUCKET_PREFIX>-application`). That bucket was never created,
> which would have produced `NoSuchBucket` on a fresh deploy. It's now the 7th entry in the
> `BUCKETS` array in `scripts/bootstrap-aws-resources.sh` and in the `S3ListAccess` resource list
> in `scripts/s3-access-policy.json`.

### 3.2 Create the `aws-access-secret` Secret

Recommended — imperative creation, no real credentials ever written to disk or git:

```bash
kubectl -n ns-dpn-01 create secret generic aws-access-secret \
  --from-literal=AWS_ACCESS_KEY_ID="$(printf '%s' '<your-access-key-id>' | base64 -w0)" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(printf '%s' '<your-secret-access-key>' | base64 -w0)"
```

The file-pipeline pods self-decode these values with `base64.b64decode()` before use, so the
stored value must be the base64 **encoding** of the real key/secret, not the raw string — hence
the extra `base64 -w0` above. Getting this wrong produces
`binascii.Error: Invalid base64-encoded string` (see Troubleshooting).

`manifests/secret-aws-access-template.yaml` exists only as a reference template (placeholders in
`stringData`, never real values) — apply it only if you intentionally want a placeholder Secret in
place before filling it in some other way; the imperative command above is the recommended path
and is what this runbook assumes.

### 3.3 Deploy Kafka + Zookeeper + Kafka UI + Redis

```bash
NS=ns-dpn-01
kubectl apply -n $NS -f manifests/deployment-zookeeper-src.yaml -f manifests/deployment-zookeeper-target.yaml
kubectl apply -n $NS -f manifests/deployment-kafka-src.yaml -f manifests/deployment-kafka-target.yaml
kubectl apply -n $NS -f manifests/deployment-kafka-ui.yaml -f manifests/deployment-redis.yaml
kubectl apply -n $NS \
  -f manifests/service-zookeeper-src.yaml -f manifests/service-zookeeper-target.yaml \
  -f manifests/service-kafka-src.yaml -f manifests/service-kafka-src-lb.yaml \
  -f manifests/service-kafka-target.yaml -f manifests/service-kafka-target-lb.yaml \
  -f manifests/service-kafka-ui.yaml -f manifests/service-kafka-ui-lb.yaml \
  -f manifests/service-redis.yaml
```

Zookeeper must be up before Kafka (Kafka references it in `KAFKA_ZOOKEEPER_CONNECT`); applying in
the order above and letting Kafka's `Recreate` strategy retry is sufficient — no explicit wait is
required, but `kubectl rollout status deploy/dpn-zookeeper-src -n $NS` etc. is a good gate if
scripting this.

### 3.4 Deploy federator server/client pods (producer/consumer, topic/file)

```bash
NS=ns-dpn-01
kubectl apply -n $NS \
  -f manifests/deployment-consumer-topic-extractor.yaml -f manifests/deployment-consumer-topic-mapper.yaml \
  -f manifests/deployment-consumer-file-extractor.yaml -f manifests/deployment-consumer-file-mapper.yaml \
  -f manifests/deployment-producer-file-adaptor-bp-natural-gas.yaml -f manifests/deployment-producer-file-mapper-bp-natural-gas.yaml \
  -f manifests/deployment-producer-topic-adaptor-eqbd-pg-gas.yaml -f manifests/deployment-producer-topic-mapper-eqbd-pg-gas.yaml \
  -f manifests/deployment-producer-topic-adaptor-eq-neso-oil.yaml -f manifests/deployment-producer-topic-mapper-eq-neso-oil.yaml
```

These are the pods the client's "federator server and client" language refers to — they run
under `serviceAccountName: federator-server` and move data between the source and target Kafka
clusters (and S3, for the file pipelines). Note: `dpn-producer-topic-{adaptor,mapper}-eq-neso-oil`
apply with `replicas: 0` intentionally (disabled pipeline, matching upstream live state) — scale up
manually if/when that pipeline is needed. None of these pods have their own ClusterIP Service —
they're workers, not servers reached by other components.

> **Upstream fix synced in**: `manifests/deployment-consumer-file-mapper.yaml`'s
> `SCHEDULER_BACKEND` is `kafka-trigger`, matching every other pipeline component.
> It was previously left on `manual`, which meant it never subscribed to the Kafka
> trigger topic and silently stalled every file moved into `dp-consumer-trfm`. If
> you're comparing against an older copy of this bundle, make sure this value isn't
> still `manual`.

### 3.5 Post-configuration — create Kafka topics

Full authoritative topic list (captured from the original bundle's live-cluster audit). Producer-topic
pipelines' **target** topics are auto-created by the mapper pods on first run — everything below
must be created explicitly (auto-create-on-subscribe is not relied on).

```bash
NS=ns-dpn-01
# Control/status topics — both brokers
for T in dpn-pipeline-control dpn-pipeline-status; do
  for B in dpn-kafka-src dpn-kafka-target; do
    kubectl exec -n $NS deploy/$B -c kafka -- kafka-topics --bootstrap-server localhost:9092 \
      --create --if-not-exists --topic $T --partitions 1 --replication-factor 1
  done
done
# SOURCE broker (dpn-kafka-src) — file + producer-topic pipelines
for T in dpn-producer-bp-natural-gas-raw \
         dpn-producer-eqbd-pg-gas-stage dpn-producer-eqbd-pg-gas-raw; do
  kubectl exec -n $NS deploy/dpn-kafka-src -c kafka -- kafka-topics --bootstrap-server localhost:9092 \
    --create --if-not-exists --topic $T --partitions 1 --replication-factor 1
done
# TARGET broker (dpn-kafka-target) — consumer-topic + consumer-file control topics
for T in dp-consumer-topic-stage dpn-consumer-topic-trfm dpn-consumer-trfm dpn-consumer-target; do
  kubectl exec -n $NS deploy/dpn-kafka-target -c kafka -- kafka-topics --bootstrap-server localhost:9092 \
    --create --if-not-exists --topic $T --partitions 1 --replication-factor 1
done
# eq-neso-oil topics — only needed if/when scaling that pipeline up from 0 replicas:
#   dpn-producer-eq-neso-oil-stage, dpn-producer-eq-neso-oil-raw (on dpn-kafka-src)
```

> **Bug fix applied in this reorg**: `deployment-consumer-topic-extractor.yaml` and
> `deployment-consumer-topic-mapper.yaml` are meant to consume the SAME topic in a pipeline
> stage. The source repo had them disagree — the extractor used `dp-consumer-topic-stage` (no
> "n") while the mapper used `dpn-consumer-topic-stage` (with an "n"). Both are now standardized
> on `dp-consumer-topic-stage`, matching the topic-creation list above.

### 3.6 Healthcheck

```bash
NS=ns-dpn-01
kubectl get pods -n $NS -o wide | grep -E 'kafka|zookeeper|redis|consumer|producer'
kubectl exec -n $NS deploy/dpn-kafka-src    -c kafka -- kafka-consumer-groups --bootstrap-server localhost:9092 --list
kubectl exec -n $NS deploy/dpn-kafka-target -c kafka -- kafka-consumer-groups --bootstrap-server localhost:9092 --list
# S3 access (should list cleanly, empty is fine — AccessDenied means an IAM policy problem):
for b in bp-natural-gas-stage bp-natural-gas-raw bp-natural-gas-target \
         dp-consumer-stage dp-consumer-trfm dp-consumer-target \
         "<S3_BUCKET_PREFIX>-application"; do
  aws s3 ls "s3://$b/" --region <AWS_REGION> || echo "ACCESS PROBLEM: $b"
done
```

### 3.7 Troubleshooting

| Symptom | Fix |
|---|---|
| `AccessDenied` against S3 (file-pipeline pods) | `<S3_IAM_USER_NAME>`'s `S3Access` IAM policy missing/reverted, or the bucket isn't in `S3ListAccess` — re-run `scripts/bootstrap-aws-resources.sh` (3.1) |
| S3 `NoSuchBucket` on the account-scoped bucket | you're on an un-patched copy without the 7th-bucket fix — confirm `scripts/bootstrap-aws-resources.sh` includes `${S3_BUCKET_PREFIX}-application` in `BUCKETS` |
| `binascii.Error: Invalid base64-encoded string` | `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in `aws-access-secret` must be **base64-encoded** — the app self-decodes them (see 3.2) |
| `KafkaException UNKNOWN_TOPIC` | a required topic wasn't created — re-run 3.5's full list, checking you targeted the correct broker (src vs target) |
| consumer-topic pods stuck / never receive messages | topic name mismatch between extractor and mapper — confirm both reference `dp-consumer-topic-stage` (the bug fixed in this pass) |
| `ImagePullBackOff` on kafka/zookeeper | must be `confluentinc/cp-kafka:7.5.3` / `confluentinc/cp-zookeeper:7.5.3` — no `dpn-kafka`/`dpn-zookeeper` custom images exist |
| `ImagePullBackOff` on producer/consumer pods | check `ghcr-pull-secret` exists in `ns-dpn-01` (owned by `00-shared-prerequisites`) and the image tag is `1.0.0` |
| `serviceaccount "federator-server" not found` | apply `00-shared-prerequisites` first — this component does not create that ServiceAccount |
| Kafka/ZK `CrashLoopBackOff` — `TypeError: … for \|` | ADOT Python auto-instrumentation got injected; these Deployments already set `instrumentation.opentelemetry.io/inject-*: "false"` — check nothing else on the cluster is overriding that |
| Rollout hangs, old+new pod both `Pending` | single-replica rollout deadlock under tight CPU — delete the stale old ReplicaSet |
