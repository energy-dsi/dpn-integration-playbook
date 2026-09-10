# 00 — Shared Prerequisites

Foundation resources every other component in this repo depends on: the two
namespaces, the shared EFS StorageClass, and the shared ServiceAccount. Apply
this component **first**, before any of `01-vault-certificate-manager`,
`02-health-monitor`, `03-data-pipeline`, or `04-federator-gateway`.

**No GitHub Actions workflow provisions this cluster bootstrap step** — it
remains a one-time manual `kubectl apply` regardless of whether the
components deployed on top of it use the automated pipeline or not. What
*is* new is how the pipeline authenticates to this AWS account — set that up
first, below, before touching any of the manual steps in this file.

## 0. One-time: GitHub Actions AWS Access

Every DPN component's CD workflow in `dpn-containerised-deployment-service`
authenticates to AWS the same way, via the shared `cloud-login` composite
action's `aws` branch — a two-step OIDC role chain, not a stored AWS access
key:

1. The runner's GitHub OIDC token first assumes a fixed **hub role**,
   `arn:aws:iam::950639282434:role/oidc_github_runner_hub` — this hub
   account and role are centrally managed (by the DSI/NESO platform team),
   not something your organisation creates.
2. The hub role then **role-chains** into an **admin role in your own AWS
   account**, named `oidc_github_runner_admin` — this is the one role your
   organisation must create, once, before any pipeline can deploy into your
   airgapped AWS environment.

Create that role in your target AWS account with a trust policy allowing
the hub role to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::950639282434:role/oidc_github_runner_hub"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Attach whatever permissions the role needs to deploy DPN — at minimum EKS
cluster access (`eks:DescribeCluster` and the ability to authenticate via
`aws eks update-kubeconfig`) plus IAM/S3/EFS permissions for whichever
components' prerequisites you provision this way (e.g. the health-monitor's
Thanos IRSA role, the federator gateway's S3 buckets — see those components'
sections below). Confirm the exact scope required with your platform/security
team rather than granting broad account-admin access.

Once this role exists, every `workflow_dispatch` with `cloud: aws` against
this account authenticates automatically — there's no per-workflow secret to
configure, matching how `cloud: azure` works via its own OIDC federated
credential (see the Azure playbook's prerequisites for the equivalent on
that side).

> **Populate the AWS Helm values before relying on the pipeline.** The
> workflow mechanism (workflow files, `cloud-login`, per-environment config
> JSON) is fully built for `cloud: aws` today. However, as of this writing
> every component's `values/aws/<environment>-<cluster>.yaml` file in
> `dpn-containerised-deployment-service` is a placeholder stub ("Azure is
> the only cloud deployed today") — the actual AWS-specific Helm values
> (storage class, service annotations, IAM role ARNs, etc.) haven't been
> populated yet. Before triggering any component's CD workflow against your
> AWS airgapped environment, adapt that component's `values/azure/*.yaml` as
> a starting template into its `values/aws/*.yaml` counterpart. Each
> component section below calls out the AWS-specific values it actually
> needs.

## 1. Prerequisites

- An EKS cluster you have `kubectl` admin access to.
- The **AWS EFS CSI driver** installed on the cluster (as an EKS add-on or
  Helm chart), with an EFS filesystem created and mount targets in the
  subnets your worker nodes run in.
- AWS CLI configured with credentials that can create IAM/S3/EFS resources
  used later by other components (only needed later — not by this step).
- `kubectl`, `aws` CLI, and `jq` installed locally.

```bash
aws eks update-kubeconfig --name <YOUR_EKS_CLUSTER_NAME> --region <AWS_REGION>
kubectl get nodes
```

## 2. Configuration

Edit one file before applying anything:

- `manifests/01-storageclass-efs.yaml` — replace `<EFS_FILESYSTEM_ID>` with
  your EFS filesystem's ID (e.g. `fs-0123456789abcdef0`).

`manifests/00-namespaces.yaml` and `manifests/02-serviceaccount-federator-server.yaml`
can be applied as-is. The `federator-server` ServiceAccount's `role-arn`
annotation is a placeholder and has no functional effect unless you later
move workloads to IRSA — see the comment in that file.

## 3. Installation

```bash
kubectl apply -f manifests/00-namespaces.yaml
kubectl apply -f manifests/01-storageclass-efs.yaml
kubectl apply -f manifests/02-serviceaccount-federator-server.yaml
```

Create the image-pull secret used by every component (imperatively — do not
store real credentials in a file). Requires a GitHub personal access token
with `read:packages` scope for the container registry your images live in:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<GH_USER> \
  --docker-password=<GH_PAT_read:packages> \
  -n ns-dpn-01

# 02-health-monitor's prereqs script copies this same secret into
# ns-dpn-health-01 for you — you do not need to create it twice.
```

### Post-configuration

None — this component has no runtime initialization step. Proceed to
`01-vault-certificate-manager`.

### Healthcheck

```bash
kubectl get namespace ns-dpn-01 ns-dpn-health-01
kubectl get storageclass efs-sc
kubectl get sa federator-server -n ns-dpn-01
kubectl get secret ghcr-pull-secret -n ns-dpn-01

# Confirm EFS actually provisions volumes before relying on it:
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-sc-smoke-test
  namespace: ns-dpn-01
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: efs-sc
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc efs-sc-smoke-test -n ns-dpn-01 -w   # expect STATUS: Bound
kubectl delete pvc efs-sc-smoke-test -n ns-dpn-01
```

Expected result: both namespaces `Active`, `efs-sc` StorageClass present, the
`federator-server` ServiceAccount and `ghcr-pull-secret` exist in `ns-dpn-01`,
and the smoke-test PVC reaches `Bound` within a minute or two.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| PVC stuck in `Pending` | EFS CSI driver not installed, or `<EFS_FILESYSTEM_ID>` wrong/unreachable | `kubectl get pods -n kube-system \| grep efs-csi`; confirm filesystem ID and that its mount targets are reachable from the worker node subnets/security groups |
| `kubectl create secret ... ghcr-pull-secret` succeeds but pods later show `ImagePullBackOff` | PAT lacks `read:packages`, or PAT expired | Regenerate the PAT with `read:packages` scope and re-run the `kubectl create secret` command (add `--dry-run=client -o yaml \| kubectl apply -f -` to update in place) |
| `namespace already exists` warnings | Harmless — manifests are idempotent | No action needed |
