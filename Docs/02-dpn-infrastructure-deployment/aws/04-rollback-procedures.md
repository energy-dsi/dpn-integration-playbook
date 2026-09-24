# 04 - Rollback Procedures

This section explains how to roll back failed or partial infrastructure deployments.

## Table of Contents

- [Purpose](#purpose)
- [1. Rollback Principles](#1-rollback-principles)
- [2. Immediate Safety Actions](#2-immediate-safety-actions)
- [3. Module-Level Rollback](#3-module-level-rollback)
- [4. Commit-Based Rollback (Recommended for Bad IaC Changes)](#4-commit-based-rollback-recommended-for-bad-iac-changes)
- [5. Common Issues](#5-common-issues)
  - [Issue: OpenTofu State Lock](#issue-opentofu-state-lock)
  - [Issue: EKS Deployment Fails](#issue-eks-deployment-fails)
  - [Issue: S3 Bucket Already Exists](#issue-s3-bucket-already-exists)
  - [Issue: Nodes Not Joining Cluster](#issue-nodes-not-joining-cluster)
  - [Issue: Pods Crash After Observability Is Enabled](#issue-pods-crash-after-observability-is-enabled)
  - [Issue: Persistent Volume Claim Remains Pending](#issue-persistent-volume-claim-remains-pending)
  - [Issue: ECR Image Pull Fails](#issue-ecr-image-pull-fails)
  - [Issue: External Secret Not Syncing](#issue-external-secret-not-syncing)
  - [Issue: Workload Cannot Assume Its IRSA Role](#issue-workload-cannot-assume-its-irsa-role)
  - [Issue: Load Balancer Controller Does Not Create the Load Balancer](#issue-load-balancer-controller-does-not-create-the-load-balancer)
  - [Issue: Load Balancer Accepts No Connections](#issue-load-balancer-accepts-no-connections)
  - [Issue: Session Manager Cannot Reach the Management Host](#issue-session-manager-cannot-reach-the-management-host)
  - [Issue: kubectl Is Unauthorised From the Management Host](#issue-kubectl-is-unauthorised-from-the-management-host)
- [6. Full Environment Rollback (Last Resort)](#6-full-environment-rollback-last-resort)
- [7. Post-Rollback Validation](#7-post-rollback-validation)
- [8. Rollback Checklist](#8-rollback-checklist)

## Purpose

This document provides rollback and recovery actions for failed or partially successful deployments.

---

## 1. Rollback Principles

Use the following principles to guide safe and controlled rollback decisions.

- Prefer OpenTofu-managed rollback over manual deletion.
- Roll back only the failed module first; avoid broad destructive actions.
- Capture current state and plan output before remediation.
- Use maintenance windows for production rollback.

---

## 2. Immediate Safety Actions

Take the following immediate actions as soon as a deployment issue is detected.

- Pause further pipeline or manual applies.
- Export current OpenTofu state snapshot.
- Save current `tofu plan` output for audit trail.

```bash
cd infrastructure/Tofu
tofu state pull > opentofu.tfstate.rollback.backup
tofu plan -var-file="environments/<env>.tfvars" -out=tfplan-investigation
```

## 3. Module-Level Rollback

Use the following approach to roll back a single affected module.

If a specific module introduces invalid resources, perform a targeted destroy for that module only.

```bash
tofu plan \
  -var-file="environments/<env>.tfvars" \
  -destroy \
  -target=module.<module_name> \
  -out=tfplan-rollback-module

tofu apply tfplan-rollback-module
```

Re-apply with corrected parameters:

```bash
tofu plan -var-file="environments/<env>.tfvars" -target=module.<module_name> -out=tfplan-redeploy-module
tofu apply tfplan-redeploy-module
```

## 4. Commit-Based Rollback (Recommended for Bad IaC Changes)

Use this rollback path when the failure is caused by a recent code/configuration commit.

If you revert to the previous known-good commit (or revert commit) and run the deployment pipeline again with `apply`, OpenTofu reconciles resources back to that previous desired state.

Typical flow:

1. Identify the commit that introduced the issue.
2. Revert it in source control (or restore the previous known-good commit).
3. Push the change and trigger the infrastructure pipeline.
4. Run pipeline `plan` first, then `apply` after review/approval.

Example (Git):

```bash
git log --oneline
git revert <bad-commit-sha>
git push
```

Important:

- `tofu apply` does not "undo" by itself; it applies the current code in the repo.
- To roll back infrastructure behavior, the desired state in Git must first be rolled back.
- Always review the rollback `plan` output before `apply`.

---

## 5. Common Issues

Review the following common issues and their suggested remediation steps.

### Issue: OpenTofu State Lock

Symptom: `Error acquiring state lock`

- Check if another pipeline is running
- Use force unlock option (with caution)
- Verify DynamoDB table exists and is accessible

Use the following commands if OpenTofu reports a locked state file.

```bash
tofu force-unlock <LOCK-ID>
```

### Issue: EKS Deployment Fails

Use the following checks when EKS deployment fails because of quota or timeout issues.

Symptom: `InsufficientQuota` or timeout errors

AWS Service Quota Exceeded (Infrastructure Level)
- EC2 Fleet Requests Quota (Most Common)
- Network Interface (ENI) or Security Group Limits

Scenario B: Kubernetes ResourceQuotas (Cluster Level)
- Pods Exceed Namespace Quota Limits
- Missing CPU / Memory Limit Definitions

Mitigation:
- Request quota increase.
- Temporarily reduce node count / VM SKU.

### Issue: S3 Bucket Already Exists

If you get an error that the bucket name is taken:

Error: Error creating S3 bucket: BucketAlreadyOwnedByYou
1. Update tfstate_bucket_name in environments/<env>.tfvars
2. Use a globally unique name (S3 bucket names must be globally unique)


### Issue: Nodes Not Joining Cluster

Use the following checks from the management host.

```bash
# Check node status
kubectl get nodes -o wide

# Describe node for events
kubectl describe node {node-name}

# Check node logs
aws ssm start-session --target {instance-id}
tail -f /var/log/cloud-init-output.log
```

### Issue: Pods Crash After Observability Is Enabled

Symptom: workloads fail once the CloudWatch Observability add-on is enabled. The recognisable case is Kafka or Zookeeper, where the init container fails before the broker starts.

Unless the configuration says otherwise the add-on monitors all services, so the operator annotates every workload for auto-instrumentation. Two failures follow from that, and they do not look alike.

- The Python init container mounts a `urllib3` build that requires Python 3.10 or later. Images that run Python 3.9 for their `dub` and `cub` tooling fail on that mount, and the pod crash-loops.
- Images that patch the standard library through `gevent` clash with the injected SDK's own exporter threads. The pod stays `Running` while threads inside it die, application threads included, so nothing crash-loops and the workload is not obviously broken. A crash-loop is therefore not the full extent of the problem.

Check and correct in this order.

- Confirm the failure follows the add-on rather than the workload: for a crash-loop, that it is in the init container rather than the broker; for a running pod, that the failing threads belong to the instrumentation.
- Set `auto_monitor_all_services` to false and name only the deployments confirmed to start with an agent in `auto_monitor_selected_deployments`. Where monitoring all services is required, add the affected deployments to `auto_monitor_excluded_deployments` as `<namespace>/<deployment-name>` instead. See [02-configuration-parameters.md](02-configuration-parameters.md).
- Confirm the pod template is not setting `instrumentation.opentelemetry.io/inject-<language>` to true itself. An annotation on the template takes precedence over both maps, so a deployment that requests injection is instrumented whichever way the parameters are set, and the fix is in its manifest. A pod can carry both `instrumentation.opentelemetry.io/inject-<language>` and `cloudwatch.aws.amazon.com/auto-annotate-<language>`, set in the manifest or added by the add-on; the `inject-<language>` key is the one the operator acts on.

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> -c <init-container-name>
```

### Issue: Persistent Volume Claim Remains Pending

Symptom: a claim stays `Pending` with no error naming a cause, and the pod using it stays unscheduled.

Three separate causes present identically from a pending claim. Check them in order.

- No CSI driver for the storage the claim requests. Confirm the driver pods are running and that `enable_ebs_csi_driver` is set.
- A StorageClass naming a provisioner that is not installed. A `gp2` class still naming the removed in-tree provisioner never binds, so the class must name `ebs.csi.aws.com`.
- No default StorageClass on the cluster. A claim that omits `storageClassName` stays `Pending` indefinitely where no class is marked default.

```bash
kubectl describe pvc <claim-name> -n <namespace>
kubectl get storageclass
kubectl get pods -n kube-system | grep csi
```

A StorageClass is not created by this deployment. Where none exists, apply one before retrying the claim.

### Issue: ECR Image Pull Fails

Symptom: a pod stays in `ImagePullBackOff` and its events name the registry rather than the image.

A pull is three separate calls, and each one can fail on its own. Check them in order.

- The node role carries `ecr:GetAuthorizationToken` and `ecr:BatchGetImage`, usually through the read-only container registry managed policy. Without the first, no pull on the node succeeds.
- All three endpoints a pull uses are present. The registry API endpoint authorises the pull, the registry Docker endpoint serves the image manifest, and the layers themselves are fetched from object storage through the gateway endpoint. Where the gateway endpoint is missing the pull authorises and then stalls on the layers, which is the failure most easily mistaken for a bad image.
- The image URI and tag resolve. A tag that was never pushed produces the same pod state as a permissions failure.

```bash
kubectl describe pod <pod-name> -n <namespace>
aws ecr describe-images --repository-name <repository-name> --image-ids imageTag=<tag>
aws ec2 describe-vpc-endpoints --query "VpcEndpoints[].ServiceName"
```

### Issue: External Secret Not Syncing

Symptom: the secrets operator logs a sync error and the Kubernetes Secret is never created.

This deployment creates the IAM role the operator assumes, not the operator itself. Install and upgrade it separately, and read its own logs for this failure rather than any deployment output. A failed role assumption and a blocked network call produce the same log line, so separate the two before changing any policy.

- The operator assumes its role the same way any workload does, so rule the token exchange out first. See [Issue: Workload Cannot Assume Its IRSA Role](#issue-workload-cannot-assume-its-irsa-role).
- The role's policy allows `secretsmanager:GetSecretValue` on the secret path the manifest requests.
- This deployment creates no interface endpoint for Secrets Manager, so the call leaves the VPC through the NAT gateway rather than staying on the AWS network. Where outbound traffic from the node subnets is filtered by destination, the Secrets Manager API hostname for the region has to be permitted, or the call is dropped and the operator reports the same sync error it reports for a permissions failure.

```bash
kubectl get externalsecret -A
kubectl logs -n <namespace> deploy/<operator-deployment-name>
kubectl describe serviceaccount <service-account> -n <namespace>
```

### Issue: Workload Cannot Assume Its IRSA Role

Symptom: an AWS API call from a pod returns a 403 while the role, its policy and its annotation all look correct.

The first cause below is the most common and it leaves the role looking untouched rather than broken, so check it before reading any policy.

- Static AWS credentials in the pod's environment take precedence over the projected service account token. Where they are present the role is never assumed, its last-used timestamp stays empty, and no change to the role has any effect. The fix is removing the credentials from the workload, not annotating it again. See [02-configuration-parameters.md](02-configuration-parameters.md).
- The pod was admitted before the annotation was added. The role ARN and the token path are injected into the pod at admission, so a pod that predates the annotation carries neither and cannot assume the role however correct the annotation now looks. Restart the workload and confirm the injected variables appear.
- The OIDC provider ARN in the trust policy matches the cluster's own provider. A role copied between clusters carries the wrong one.
- The trust policy condition matches the namespace and service account exactly rather than by pattern, so a name that is close but not identical fails the exchange with the same 403.

```bash
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.containers[*].env[*].name}'
kubectl describe serviceaccount <service-account> -n <namespace>
aws iam get-role --role-name <role-name> --query "Role.RoleLastUsed"
```

### Issue: Load Balancer Controller Does Not Create the Load Balancer

Symptom: a Service of type `LoadBalancer` stays with no external address and no load balancer is created.

The controller reports this in its own logs rather than on the Service, so read the logs before changing the manifest.

- The controller pods are `Running` in the namespace the deployment was configured with.
- The controller's role trust policy names the namespace the controller actually runs in. Where the two differ the controller holds no AWS permissions, and every reconcile fails without the Service showing an error. See [02-configuration-parameters.md](02-configuration-parameters.md).
- The role's policy allows the load balancing actions and the EC2 actions the controller needs. It does not only read: it creates and tags a security group for the load balancer, so a describe-only policy fails partway through.
- The Service carries the `service.beta.kubernetes.io/aws-load-balancer-*` annotations for the type, scheme and subnets intended. The controller acts on the annotations, not on defaults.

```bash
kubectl get svc <service-name> -n <namespace>
kubectl describe svc <service-name> -n <namespace>
kubectl logs -n <namespace> deploy/aws-load-balancer-controller
```

### Issue: Load Balancer Accepts No Connections

Symptom: connections to the load balancer are refused, reset or time out while the pods behind it are `Running`.

A network load balancer operates at layer 4 and returns no HTTP status of its own, so any status code the client receives came from the pod and the load balancer is working. That distinction narrows this to two causes.

- Target health. An unhealthy target is withdrawn from rotation, and a target group with none healthy refuses every connection.
- The node security group admits the load balancer's backend security group on the target port range. Without that rule the connection times out rather than being refused.
- Where `enable_vpc_flow_logs` is set, the flow logs name the rejecting hop directly, rather than leaving it to be inferred from whether the client saw a timeout or a refusal.

```bash
aws elbv2 describe-load-balancers
aws elbv2 describe-target-groups --load-balancer-arn <load-balancer-arn>
aws elbv2 describe-target-health --target-group-arn <target-group-arn>
kubectl get endpointslices -n <namespace> -l kubernetes.io/service-name=<service-name>
```

### Issue: Session Manager Cannot Reach the Management Host

Symptom: the session request is rejected, or the host does not appear in the managed instance inventory.

A rejection on the caller's side and a host that never registered read identically from the command line. The inventory check below separates them: a host that is absent from it is not a permissions problem.

- The instance role carries the managed instance core policy. Without it the host never registers and cannot be targeted at all.
- All three Systems Manager endpoints are present. The agent registers through one of them and carries the session over the other two, so a partial set leaves a host that appears in the inventory but refuses every session.
- The engineer's own identity is allowed to start a session.

```bash
aws ssm describe-instance-information
aws ec2 describe-vpc-endpoints --query "VpcEndpoints[].ServiceName"
aws sts get-caller-identity
```

### Issue: kubectl Is Unauthorised From the Management Host

Symptom: the session connects, the caller identity resolves, and every `kubectl` call returns forbidden or unauthorised.

A working session proves the network path only. Cluster authorisation is separate and is granted to an identity rather than to the host.

- The management host's instance role holds no EKS permissions in this deployment. A kubeconfig written while the instance role is the active identity cannot authenticate to the cluster, so assume a human role on the host before writing it.
- The identity holds an EKS access entry, or an entry in the `aws-auth` ConfigMap on a cluster still using it.
- The access entry's scope matches the call. A namespace-scoped entry returns forbidden on any cluster-wide read, which reads as no access at all rather than as a scope limit.

```bash
aws sts get-caller-identity
aws eks list-access-entries --cluster-name <cluster-name>
aws eks list-associated-access-policies --cluster-name <cluster-name> --principal-arn <principal-arn>
kubectl auth can-i --list
```

## 6. Full Environment Rollback (Last Resort)

Use the following steps only when targeted rollback is not sufficient.

Use only when module rollback is not sufficient.

```bash
tofu plan -destroy -var-file="environments/<env>.tfvars" -out=tfplan-destroy-all
tofu apply tfplan-destroy-all
```

## 7. Post-Rollback Validation

Perform the following checks to confirm the environment is stable after rollback.

- Validate resource inventory in affected resource groups.
- Confirm OpenTofu state is consistent.
- Re-run plan and verify no unexpected drift.

```bash
aws resource-explorer-2 search --query-string "arn" --query "Resources[*].Arn" --output text
tofu plan -var-file="environments/<env>.tfvars"
```

## 8. Rollback Checklist

Use the following checklist to confirm all rollback activities have been completed.

- Captured state backup before rollback
- Identified root cause and impacted module
- Executed least-destructive rollback path
- Revalidated networking, identity, and critical data services
- Logged actions and outcomes for post-incident review

---

Continue with [05-uninstall-decommissioning.md](05-uninstall-decommissioning.md)