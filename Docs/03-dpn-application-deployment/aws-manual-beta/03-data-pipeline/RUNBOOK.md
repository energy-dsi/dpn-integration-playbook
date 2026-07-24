# DPN Data Pipeline — Airflow Orchestration (03-data-pipeline)

This component covers **Airflow only** — the orchestration layer for the DPN data pipelines,
running in namespace `ns-dpn-01`: the webserver, scheduler, worker, triggerer, and its Postgres
metadata database. It does **not** include Kafka/Zookeeper, the Kafka UI, or any
producer/consumer/adaptor/mapper/extractor pods — those are the actual data-moving workloads and
live in `04-federator-gateway`, built and applied by a different agent/runbook. It also does not
include Redis: although Airflow's CeleryExecutor uses `dpn-airflow-redis` as its message broker,
per this reorg's component grouping Redis belongs to `04-federator-gateway`.

The 6 Airflow DAGs bundled here talk to the federator-gateway pods **over Kafka messages** (a
trigger/status topic handshake), not via `KubernetesPodOperator` — Airflow never creates pods for
those pipelines itself. That means Airflow can be deployed and pass its own healthcheck
independently of whether `04-federator-gateway` exists yet, but the DAGs won't do anything useful
(their triggers will have no Kafka broker/pods to talk to) until federator-gateway is deployed too.

## 1. Prerequisites

- **`00-shared-prerequisites`** must be applied first — namespace `ns-dpn-01`, the `efs-sc`
  StorageClass, the shared `federator-server` ServiceAccount, and any AWS-native prerequisites
  (EFS CSI driver, aws-load-balancer-controller, EFS filesystem) all come from there. Nothing in
  this component creates them.
- **`01-vault-certificate-manager`** — or at minimum the `ghcr-pull-secret` Secret in `ns-dpn-01`
  — must be applied first. Every Deployment in this component pulls its image via
  `imagePullSecrets: [ghcr-pull-secret]`; without it every pod here sits in `ImagePullBackOff`.
  (`ghcr-pull-secret` itself is not created by this component — it's a template you'd normally
  find alongside the other manifests, but ownership/creation is handled upstream, so it is
  intentionally not duplicated in this folder.)
- **Soft dependency — `04-federator-gateway`**: provides `dpn-airflow-redis` (the Celery broker)
  and the Kafka backbone the DAGs trigger against. Airflow's own pods and healthcheck do not
  require it to be up, but without it the Celery worker/scheduler/triggerer will be unable to
  reach their broker, and the DAGs will have nothing to talk to.
- **Soft dependency — `02-health-monitor`**: some Airflow pods carry OTEL/CloudWatch
  auto-instrumentation annotations for observability; if an OTEL collector endpoint is wired up
  cluster-wide it typically lives in `ns-dpn-health-01` via a cross-namespace Service DNS name.
  Not required for Airflow to function — purely for centralized tracing/metrics.

## 2. Configuration

Before applying `manifests/secret-airflow-secrets.yaml`, fill in three values (it ships as a template
with placeholders — do not commit real values):

| Key | What it is | How to generate |
|---|---|---|
| `FERNET_KEY` | Encrypts Airflow connection passwords/variables at rest in the metadata DB | `python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` |
| `WEB_SECRET_KEY` | Flask session secret for the webserver | any long random string, e.g. `head -c32 /dev/urandom \| base64` |
| `POSTGRES_PASSWORD` | Password for the `airflow` role in the bundled Postgres | choose a strong password; must match what Postgres is initialized with |

The namespace in every manifest in this component is `ns-dpn-01` — this is a fixed requirement for
this cluster and should not be changed.

## 3. Installation

### 3.1 Deploy Airflow

```bash
NS=ns-dpn-01

# Config must exist before pods start
kubectl apply -n $NS -f manifests/configmap-airflow-config.yaml
kubectl apply -n $NS -f manifests/configmap-airflow-dags.yaml

# Fill in manifests/secret-airflow-secrets.yaml with real values first (see section 2), then:
kubectl apply -n $NS -f manifests/secret-airflow-secrets.yaml

# Postgres storage
kubectl apply -n $NS -f manifests/storage-postgres-pvc.yaml

# Workloads, then networking
kubectl apply -n $NS -f manifests/deployment-airflow-postgres.yaml
kubectl apply -n $NS -f manifests/deployment-airflow-scheduler.yaml
kubectl apply -n $NS -f manifests/deployment-airflow-triggerer.yaml
kubectl apply -n $NS -f manifests/deployment-airflow-webserver.yaml
kubectl apply -n $NS -f manifests/deployment-airflow-worker.yaml
kubectl apply -n $NS -f manifests/service-airflow-postgres.yaml
kubectl apply -n $NS -f manifests/service-airflow-webserver.yaml
kubectl apply -n $NS -f manifests/service-airflow-webserver-external.yaml
```

All manifests for this component live flat in `manifests/`, so once secrets are filled in you can
also just run `kubectl apply -n $NS -f manifests/` — every file in that directory belongs to this
component and is safe to apply together.

Notes:
- `manifests/deployment-airflow-postgres.yaml` runs Postgres against an EFS-backed PVC. Its
  `securityContext.runAsUser`/`runAsGroup`/`fsGroup` (currently `1005`) is CLUSTER-SPECIFIC — it
  must match the EFS access-point's POSIX uid for this cluster's filesystem. If this is a genuinely
  new EFS filesystem (not the same one production points at), resolve the access-point uid first
  and patch the Deployment:
  ```bash
  AP=$(kubectl get pv $(kubectl get pvc dpn-airflow-postgres-pvc -n $NS \
       -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}' | awk -F':' '{print $NF}')
  aws efs describe-access-points --access-point-id "$AP" --query 'AccessPoints[].PosixUser'
  # then kubectl patch deploy dpn-airflow-postgres -n $NS ... with the returned uid/gid
  ```
  Against the same filesystem as an existing deployment, the access point already exists and this
  is a no-op.
- The Airflow metadata DB schema is not created automatically by these manifests — run
  `airflow db migrate` once Postgres and the webserver image are reachable, e.g.:
  ```bash
  kubectl -n $NS exec deploy/dpn-airflow-webserver -c dpn-airflow-webserver -- airflow db migrate
  ```

### 3.2 Post-configuration — create the admin user

```bash
kubectl -n $NS exec deploy/dpn-airflow-webserver -c dpn-airflow-webserver -- \
  airflow users create --username admin --password '<choose-a-password>' \
  --firstname Admin --lastname User --role Admin --email admin@example.com
```

### 3.3 Healthcheck

```bash
kubectl get pods -n $NS -l 'app in (dpn-airflow-webserver,dpn-airflow-scheduler,dpn-airflow-worker,dpn-airflow-triggerer,dpn-airflow-postgres)'
kubectl -n $NS exec deploy/dpn-airflow-webserver -c dpn-airflow-webserver -- curl -s http://localhost:8080/health
```

The webserver healthcheck should pass independently of whether `04-federator-gateway` (Kafka,
Redis, and the pipeline pods) is deployed. The Celery worker/scheduler/triggerer pods, however,
depend on reaching `dpn-airflow-redis` (broker) — expect `CrashLoopBackOff` or repeated
broker-connection retries on those three Deployments until `04-federator-gateway` is applied.

DAG-level verification (once federator-gateway is also up): unpause a DAG in the Airflow UI
(`dpn-airflow-webserver-external`, an internal NLB) or via CLI, trigger a run, and confirm its
`trigger_*` / `wait_*_done` tasks succeed — this exercises the Kafka trigger/status handshake
against the federator-gateway pods end to end.

### 3.4 Troubleshooting

| Symptom | Fix |
|---|---|
| `ImagePullBackOff` on any `dpn-airflow-*` pod | confirm `ghcr-pull-secret` exists in `ns-dpn-01` (from `01-vault-certificate-manager`) and the image tag matches `ghcr.io/energy-dsi/dpn-airflow:1.0.0` |
| Postgres `Init:Error` — `chown: Operation not permitted` | `runAsUser`/`runAsGroup`/`fsGroup` don't match this cluster's EFS access-point uid — see the note in 3.1 |
| Postgres PVC stuck `Pending` | `efs-sc` StorageClass or the EFS CSI driver is missing — both come from `00-shared-prerequisites` |
| Scheduler/worker/triggerer `CrashLoopBackOff` on Celery broker connection | `dpn-airflow-redis` (owned by `04-federator-gateway`) isn't deployed yet — expected until that component is applied |
| Webserver up but DAGs' `trigger_*` tasks fail/timeout | the Kafka brokers and pipeline pods (`04-federator-gateway`) aren't up, or the `dpn-pipeline-control`/`dpn-pipeline-status` topics don't exist yet |
| `airflow users create` fails with a DB error | run `airflow db migrate` first (see 3.1) and confirm the webserver pod is `Running` |
| Admin user create says user already exists | idempotent — safe to ignore, or use `airflow users list` to confirm |
