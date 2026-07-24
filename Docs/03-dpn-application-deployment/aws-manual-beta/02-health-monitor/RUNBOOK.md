# DPN Health-Monitoring Stack — AWS EKS Deployment Runbook

This component (`02-health-monitor`) deploys the DPN health-monitoring/observability
stack — Kafka, OpenSearch, an OpenTelemetry Collector, Prometheus+Thanos, Data Prepper,
Jaeger, Perses, and an Nginx observability proxy — into namespace `ns-dpn-health-01` on
an AWS EKS cluster. It is a raw-manifest deployment (no Helm release, no CI/CD pipeline):
every file here is applied directly with `kubectl apply -f`, in the numbered order
documented below.

Deploy this component **after** `00-shared-prerequisites`, and after
`01-vault-certificate-manager` has created namespace `ns-dpn-01` and its
`ghcr-pull-secret` — `scripts/01-prereqs.sh` copies that secret into
`ns-dpn-health-01` and will fail if it doesn't exist yet. The Nginx proxy
(`manifests/09-nginx-proxy.yaml`) also references two Services that live in
`ns-dpn-01` (owned by the `03-data-pipeline` / `04-federator-gateway` components) — see
section 3.10 for why that is only a soft dependency.

## 1. Prerequisites

- `kubectl` configured against the target cluster (e.g. via `aws eks update-kubeconfig`).
- The AWS CLI configured with credentials that can create IAM roles/policies (for
  `scripts/10-iam-thanos-irsa.sh`) and, separately, an identity that can run
  `kubectl` against the cluster.
- Namespace `ns-dpn-01` already exists and already has a working `ghcr-pull-secret`
  (created by the `00-shared-prerequisites` / `01-vault-certificate-manager` components).
- A working `efs-sc` StorageClass (EFS CSI driver installed and healthy). `gp2`'s
  in-tree `kubernetes.io/aws-ebs` provisioner was removed from Kubernetes in 1.27+; if no
  EBS CSI driver replaces it, every PVC on it sits `Pending` forever. Every manifest here
  uses `efs-sc` for exactly this reason — confirm your cluster has a working EFS (or EBS
  CSI, if you switch back) StorageClass before applying.
- Public registries (Docker Hub, Quay) reachable directly from your cluster's nodes.
  Every image in these manifests other than otel-collector
  (`ghcr.io/energy-dsi/opentelemetry-collector-contrib:0.95.0`, pulled via
  `ghcr-pull-secret`) is public and needs no private mirror.
- Sufficient node CPU/memory headroom — no autoscaler is assumed. Check headroom with the
  command in section 3.11 ("Capacity") before applying anything, and again before scaling
  replicas up.

An IAM identity with `iam:CreateRole` / `iam:PutRolePolicy` is required to run
`scripts/10-iam-thanos-irsa.sh` (step 3.5 below). If your account blocks
`iam:CreateUser` via SCP but allows `iam:CreateRole`, that's itself the signal that IRSA
— not a static-key Secret — is the account's sanctioned pattern.

## 2. Configuration

Before applying anything, replace the placeholder tokens below with values for your
cluster/account. They appear in the files noted:

| Placeholder | Where it appears | What to put there |
|---|---|---|
| `<AWS_REGION>` | `manifests/05-prometheus-thanos.yaml`, `scripts/10-iam-thanos-irsa.sh` | The AWS region your EKS cluster runs in, e.g. `eu-west-2`. |
| `<EKS_CLUSTER_NAME>` | `manifests/04-otel-collector.yaml`, `manifests/05-prometheus-thanos.yaml`, `scripts/10-iam-thanos-irsa.sh` | Your EKS cluster's name, e.g. `eks-dpn-prod-eu-west-2`. |
| `<THANOS_IRSA_ROLE_ARN>` | `manifests/05-prometheus-thanos.yaml` | The IAM role ARN printed by `scripts/10-iam-thanos-irsa.sh` (step 3.5). |
| `<THANOS_S3_BUCKET>` | `manifests/05-prometheus-thanos.yaml` | The S3 bucket you pass as `S3_BUCKET` to `scripts/10-iam-thanos-irsa.sh` — must already exist and belong to you. |

Namespace `ns-dpn-health-01` (and cross-references to `ns-dpn-01`) are intentionally
fixed values, not placeholders — do not rename them.

Nothing else in this directory needs editing before a first apply; `scripts/10-iam-thanos-irsa.sh`
prints the exact values to paste into `manifests/05-prometheus-thanos.yaml`.

## 3. Installation

Every later stage depends on an earlier one being genuinely healthy, not just applied —
verify before moving on. All commands below assume your working directory is
`02-health-monitor/`.

### 3.1 Prerequisites script

```bash
./scripts/01-prereqs.sh
```

Creates the namespace, copies `ghcr-pull-secret` from `ns-dpn-01`, checks StorageClasses,
prompts a node-health check, and reports CPU headroom. Read its output before continuing.

### 3.2 Deploy Kafka + Zookeeper + Kafka UI

```bash
kubectl apply -f manifests/02-kafka-stack.yaml
```

Verify:

```bash
kubectl get pods -n ns-dpn-health-01 -l app=dpn-kafka-health
kubectl logs deployment/dpn-kafka-health -n ns-dpn-health-01 | grep "Ready to serve"
kubectl get endpoints dpn-kafka-health -n ns-dpn-health-01   # expect :9092 and :9093
```

This and 3.3 are the two genuine hard blockers — nothing else deploys usefully without
them.

### 3.3 Deploy OpenSearch

```bash
kubectl apply -f manifests/03-opensearch.yaml
```

Verify:

```bash
kubectl run curl-test --image=curlimages/curl:8.8.0 --restart=Never -n ns-dpn-health-01 \
  --command -- curl -s http://dpn-opensearch-health:9200/_cluster/health
# expect "status":"green"; then: kubectl delete pod curl-test -n ns-dpn-health-01
```

### 3.4 Deploy the OTel Collector

Needs Kafka (3.2) up first.

```bash
kubectl apply -f manifests/04-otel-collector.yaml
```

Verify:

```bash
kubectl get pods -n ns-dpn-health-01 -l app=dpn-otel-collector       # expect 3/3 Running
kubectl get pdb dpn-otel-collector -n ns-dpn-health-01               # expect ALLOWED DISRUPTIONS >= 1
kubectl logs deployment/dpn-otel-collector -n ns-dpn-health-01
# expect "Everything is ready. Begin running and processing data." and periodic
# LogsExporter lines, zero restarts. See section 3.11 if not.
```

### 3.5 Create the Thanos IRSA role

```bash
CLUSTER_NAME=<your-cluster> S3_BUCKET=<your-bucket> ./scripts/10-iam-thanos-irsa.sh
```

Paste the printed role ARN into `<THANOS_IRSA_ROLE_ARN>` and the bucket name into
`<THANOS_S3_BUCKET>` in `manifests/05-prometheus-thanos.yaml` before continuing.

### 3.6 Deploy Prometheus + Thanos sidecar + Thanos Query

Depends on 3.5's IAM role existing first.

```bash
kubectl apply -f manifests/05-prometheus-thanos.yaml
```

Verify:

```bash
kubectl get pods -n ns-dpn-health-01 -l app=dpn-prometheus-health   # expect 2/2
kubectl logs deployment/dpn-thanos-query-health -n ns-dpn-health-01
# expect: "adding new sidecar with [storeEndpoints ...] address=dpn-thanos-sidecar-health:10901"
```

### 3.7 Deploy Data Prepper

Needs Kafka (3.2) and OpenSearch (3.3) up.

```bash
kubectl apply -f manifests/06-data-prepper.yaml
```

Verify:

```bash
kubectl logs deployment/dpn-data-prepper-health -n ns-dpn-health-01
# expect "Started Kafka source for topic otel-logs/otel-metrics/otel-traces" and
# "Assigned partition ..." — its consumers auto-create the 3 topics on first connect
```

### 3.8 Deploy Jaeger (ingester + query)

Needs Kafka (3.2) and OpenSearch (3.3) up.

```bash
kubectl apply -f manifests/07-jaeger.yaml
```

Verify:

```bash
kubectl get pods -n ns-dpn-health-01 -l app.kubernetes.io/name=jaeger   # expect 4/4 Running (2 query + 2 ingester)
kubectl get pdb dpn-jaeger-health -n ns-dpn-health-01                  # expect ALLOWED DISRUPTIONS >= 1
```

### 3.9 Deploy Perses

```bash
kubectl apply -f manifests/08-perses.yaml
```

Verify:

```bash
curl -o /dev/null -w '%{http_code}' http://dpn-perses-health:8083   # expect 200
```

### 3.10 Deploy the Nginx observability proxy

Creates the Basic-Auth Secret first, then the proxy itself. The proxy fronts every
Service deployed in 3.2–3.9, plus two Services in `ns-dpn-01`
(`dpn-kafka-ui.ns-dpn-01.svc.cluster.local:8086` and
`dpn-airflow-webserver.ns-dpn-01.svc.cluster.local:8080`, owned by the
`03-data-pipeline` / `04-federator-gateway` components). Because every `proxy_pass` in
`manifests/09-nginx-proxy.yaml` uses the `set $var` + variable pattern, nginx defers DNS
resolution to request time rather than resolving hostnames at config-parse time — so if
those two ns-dpn-01 backends (or any other backend, e.g. OpenSearch Dashboards, which is
out of scope here) aren't up yet, that `location` degrades to a `502` at request time
instead of preventing the whole proxy from starting. It is safe to apply this step before
those components exist.

```bash
./scripts/11-nginx-basic-auth.sh
kubectl apply -f manifests/09-nginx-proxy.yaml
```

Verify:

```bash
curl -o /dev/null -w '%{http_code}' http://dpn-nginx-observability-health:9081/         # expect 401
curl -u <user>:<password> -o /dev/null -w '%{http_code}' \
  http://dpn-nginx-observability-health:9081/-/healthy                                  # expect 200
```

### 3.11 Capacity

If any pod sits `Pending` with `Insufficient cpu`, check headroom and trim requests:

```bash
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "NODE $n"; kubectl describe node "$n" | grep -A5 "Allocated resources"
done
```

If a Deployment you just patched (resources/affinity/image) has both old and new pods
stuck, force the stale ReplicaSet out of the way — Kubernetes won't retire it until the
replacement passes health checks, which can't happen if resources don't fit anywhere:

```bash
kubectl get rs -n ns-dpn-health-01 | grep <deployment-name>
kubectl scale rs <stale-rs-name> -n ns-dpn-health-01 --replicas=0
```

otel-collector and Jaeger run at higher-availability replica counts than the rest of the
stack: otel-collector `replicas: 3` with a `maxUnavailable: 1` PodDisruptionBudget and
`topologySpreadConstraints`; jaeger-ingester and jaeger-query `replicas: 2` each, sharing
one `maxUnavailable: 1` PodDisruptionBudget (`dpn-jaeger-health`, selecting
`app.kubernetes.io/name=jaeger`), plus `topologySpreadConstraints` per component. Re-check
headroom before applying if your cluster is tight.

### 3.12 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pod `ContainerCreating` forever, event says `failed to assign an IP address to container` | A node has broken VPC-CNI pod networking (e.g. subnet-level IP exhaustion) | Confirm which node with `kubectl describe pod <pod> -n ns-dpn-health-01 \| grep -i FailedCreatePodSandBox`, then add a `nodeAffinity` exclusion to the affected Deployment's `spec.template.spec` (none of the manifests here ship with one by default — this was removed as cluster-specific). Example:<br>`affinity:`<br>`  nodeAffinity:`<br>`    requiredDuringSchedulingIgnoredDuringExecution:`<br>`      nodeSelectorTerms:`<br>`        - matchExpressions:`<br>`            - key: kubernetes.io/hostname`<br>`              operator: NotIn`<br>`              values:`<br>`                - <your-broken-node-hostname>`<br>A `preferred` anti-affinity is not a safe substitute — the scheduler's CPU-headroom scoring can still pick a broken node over a healthy one. |
| PVC stuck `Pending` even on a StorageClass that should work | `WaitForFirstConsumer` PVCs pin themselves permanently to whichever node they first attempt scheduling on (via the `volume.kubernetes.io/selected-node` annotation), even on failure — if that node is broken, the PVC is stuck | `kubectl describe pvc <name>`, confirm the annotation; delete and recreate the PVC (and the pod using it) after any needed nodeAffinity exclusion is in place — a plain re-apply does not clear that annotation |
| A non-application pod crashes with an error that makes no sense for its image (e.g. a Python/Node/Java stack trace from a container that shouldn't run any of those runtimes) | Your cluster's OTel auto-instrumentation mutating webhook injected a shim it never expected | Confirm the 8 opt-out annotations (`instrumentation.opentelemetry.io/inject-*` and `cloudwatch.aws.amazon.com/auto-annotate-*`, all `"false"`) are present in that pod template. Zookeeper, Kafka, Kafka UI, otel-collector, data-prepper, jaeger-ingester, Prometheus, and Thanos keep all eight set to `"false"` for exactly this reason (JVM-based OpenSearch and jaeger-query are the deliberate exception, set `"true"`, since the Java auto-instrumentation agent doesn't hit the Python-shim problem). If your cluster has no such webhook, these annotations are no-ops either way. |
| otel-collector crash-loops, liveness probe keeps killing it, no useful error in `kubectl logs` | The real error is delayed past the liveness probe's kill window | Temporarily remove the probes to let it survive long enough to log its real error:<br>`kubectl patch deployment dpn-otel-collector -n ns-dpn-health-01 --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/livenessProbe"},{"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}]'`<br>then `kubectl logs deployment/dpn-otel-collector -n ns-dpn-health-01 --previous` on the next restart. A common cause is a stale Kafka broker port/`protocol_version` baked into the ConfigMap — `manifests/04-otel-collector.yaml` here already ships the correct port (`9092`) and `protocol_version` (`3.5.0`). Restore the probes once healthy (re-`kubectl apply -f manifests/04-otel-collector.yaml`). |
| nginx proxy won't start: `host not found in upstream "..." in nginx.conf` | A literal hostname was used in `proxy_pass` instead of the `set $var` + variable pattern, so nginx tried to resolve it at config-parse time | `manifests/09-nginx-proxy.yaml` as shipped already uses the variable pattern (see section 3.10) — if you've edited it back to a literal `proxy_pass http://hostname:port;`, that's the regression to look for |
| On Windows/Git-Bash, an `aws` command with `file:///tmp/...` fails with "No such file or directory" even though the file demonstrably exists | `aws.exe` is a native Windows binary; Git-Bash's MSYS layer mangles leading-`/` paths passed to it | Pass JSON inline as a string argument instead of via `file://` (see `scripts/10-iam-thanos-irsa.sh`, which already does this) |
| SSM/kubectl session fails with an expired-credential or `TargetNotConnected` error | Temporary STS credentials are short-lived by design | Get a fresh set of credentials. If a bastion `aws ssm start-session` fails but the instance is confirmed `Online` via `aws ssm describe-instance-information`, it's usually transient (agent check-in gap) or a local prerequisite (`session-manager-plugin` not installed) — retry |

#### What this directory does NOT include

- **`ghcr-pull-secret` content** — copied at runtime by `scripts/01-prereqs.sh` from an
  existing working namespace, never hand-authored or checked in.
- **The Thanos S3 bucket and IAM role** — created at runtime by
  `scripts/10-iam-thanos-irsa.sh`; the bucket must already exist and belong to you.
- **The Nginx Basic-Auth password** — generated fresh at runtime by
  `scripts/11-nginx-basic-auth.sh`; never checked in.
- **OpenSearch Dashboards, Airflow, and a second Kafka UI** — the nginx proxy config
  references these (matching the upstream chart) but they are out of scope of this
  directory; those `location` blocks will 502 harmlessly until/unless you deploy them
  separately.
- **An internal AWS Load Balancer for the Nginx proxy** — it's ClusterIP-only here.
  Reach it via `kubectl port-forward` or an SSM tunnel. Exposing it via an internal NLB
  is a separate decision (check whether the AWS Load Balancer Controller is installed
  on your cluster first).
