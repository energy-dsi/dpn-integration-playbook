# DPN Rollback and Recovery Process

---

## Table of Contents

- [Overview](#overview)
- [Rollback Strategy](#rollback-strategy)
- [Rollback Scenarios](#rollback-scenarios)
- [Part 1 — DPN Federator Gateway Rollback](#part-1--dpn-federator-gateway-rollback)
  - [Rollback During CI Pipeline Failure](#rollback-during-ci-pipeline-failure)
  - [Rollback During CD Pipeline Failure](#rollback-during-cd-pipeline-failure)
  - [Helm Release Rollback](#helm-release-rollback)
  - [Container Image Rollback](#container-image-rollback)
  - [Rollback Kafka Topics](#rollback-kafka-topics)
- [Part 2 — DPN Federator Certificate Manager Rollback](#part-2--dpn-federator-certificate-manager-rollback)
  - [Rollback During Certificate Manager CI Pipeline Failure](#rollback-during-certificate-manager-ci-pipeline-failure)
  - [Rollback During Certificate Manager CD Pipeline Failure](#rollback-during-certificate-manager-cd-pipeline-failure)
  - [Vault Certificate Bundle Rollback](#vault-certificate-bundle-rollback)
  - [P12 Keystore Recovery](#p12-keystore-recovery)
  - [Certificate Renewal Job Recovery](#certificate-renewal-job-recovery)
- [Part 3 — DPN Data Pipeline Rollback](#part-3--dpn-data-pipeline-rollback)
  - [Rollback Data Pipeline Containers](#rollback-data-pipeline-containers)
  - [Rollback Kafka Topics for Data Pipelines](#rollback-kafka-topics-for-data-pipelines)
  - [Rollback Storage Processing Jobs](#rollback-storage-processing-jobs)
- [Post-Rollback Verification](#post-rollback-verification)
- [Disaster Recovery Considerations](#disaster-recovery-considerations)
- [Review Notes](#review-notes)

---

## Overview

This document describes the rollback and recovery procedures for **DPN deployments** in the event of a failed installation or unsuccessful deployment.

The rollback procedures apply to deployments performed using:

- **AWS CodePipeline**
- **AWS CodeBuild**
- **Amazon Elastic Container Registry (ECR)**
- **AAmazon Elastic Kubernetes Service (EKS)**
- **Helm-based deployments**

The objective of the rollback procedure is to restore the platform to the **last known stable state** with minimal service disruption.

---

## Rollback Strategy

The DPN deployment rollback strategy follows the layered architecture of the deployment:

| Layer | Rollback Method |
|-------|----------------|
| CI Pipeline | Re-run pipeline with previous commit or tag |
| Container Registry | Deploy previous container image tag |
| Helm Deployment | Use Helm rollback to previous revision |
| Kubernetes Deployment | Restart or redeploy pods |
| Vault Secrets | Reload certificate bundle from previous known-good state |
| Kafka Topics | Recreate or purge incorrect messages if required |

Rollback operations should always be performed in the following order:

1. Stop the failed pipeline execution
2. Identify the last successful deployment revision
3. Roll back the Helm release to the previous stable revision
4. Verify container and service status
5. Validate Kafka topics and application logs

---

## Rollback Scenarios

Rollback procedures may be required under the following scenarios:

| Scenario | Description |
|----------|-------------|
| CI Pipeline Failure | Image build failed or artefact corrupted |
| CD Pipeline Failure | Deployment failed during Helm installation |
| Container Startup Failure | Pods crash or enter CrashLoopBackOff after deployment |
| Certificate Sync Failure | P12 keystore not generated or corrupted |
| Vault Configuration Error | Incorrect certificate bundle loaded into Vault |
| Kafka Processing Failure | Topics not created or data pipeline failing |
| Configuration Error | Incorrect secrets, environment variables, or certificates |

---

## Part 1 — DPN Federator Gateway Rollback

The Federator Gateway deployment includes the following services:

| Component | Purpose |
|-----------|---------|
| Zookeeper Source | Coordination service for source Kafka cluster |
| Zookeeper Target | Coordination service for target Kafka cluster |
| Kafka Source | Source Kafka cluster |
| Kafka Target | Target Kafka cluster |
| Kafka UI | Kafka monitoring interface |
| Redis | Stores Kafka offsets and token cache |
| Federator Server | Sends data via gRPC |
| Federator Client | Receives data and writes to Kafka |

---

### Rollback During CI Pipeline Failure

If the **CI pipeline fails**, no deployment rollback is required because no containers have been deployed.

Recommended actions:

1. Review CI pipeline logs in AWS CodeBuild.
2. Fix any build or dependency issues (refer to the [Troubleshooting](03-installation-process.md#troubleshooting) section).
3. Re-run the CI pipeline.

Verify whether new container images were pushed before the failure:

```bash
aws ecr describe-repositories
```

```bash
aws ecr list-images --repository-name <repository-name> --query 'imageIds[*].imageTag'
```

If no new images were pushed, the previous deployment remains intact and no further rollback action is required.

---

### Rollback During CD Pipeline Failure

If the **CD pipeline fails during deployment**, Kubernetes resources may be partially deployed.

1. Identify the current Helm release:

```bash
helm list -n <namespace>
```

2. Check the Helm revision history:

```bash
helm history dpn-platform -n <namespace>
```

3. Identify the last successful revision from the history output, then proceed with a Helm release rollback as described in the next step.

---

### Helm Release Rollback

Use Helm rollback to restore the previous working revision:

```bash
helm rollback dpn-platform <revision-number> -n <namespace>
```

Example:

```bash
helm rollback dpn-platform 2 -n ns-dpn
```

Verify that all pods return to a `Running` state after rollback:

```bash
kubectl get pods -n <namespace>
```

---

### Container Image Rollback

If the failure is caused by a faulty container image, redeploy using the previous known-good image tag.

1. Identify the previous image tag in Amazon ECR:

```bash
aws ecr list-images --repository-name dpn-federator --query 'imageIds[*].imageTag'
```

2. Update the Helm values file to reference the previous tag:

```yaml
image:
  repository: <account-id>.dkr.ecr.<region>.amazonaws.com/dpn-federator
  tag: <previous-tag>
```

3. Re-run the CD pipeline with the updated image tag.

---

### Rollback Kafka Topics

If Kafka topics were incorrectly created or contain corrupted messages:

1. Access the Kafka UI:

```
http://kafka-ui:8085
```

2. Identify and delete the incorrect topics.

3. Recreate the topics using the Kafka topic creation pipeline, or manually via the Kafka UI.

> **Note:** Kafka UI is only accessible from inside the AWS network (VPC) via a bastion host or Amazon EC2 instance specified in the prerequisites.

---

## Part 2 — DPN Federator Certificate Manager Rollback

The Federator Certificate Manager is responsible for issuing, renewing, and synchronising mTLS certificates used by the Federator Gateway. It has the following dependencies:

- HashiCorp Vault — stores the key pair, CA chain, and signed certificate
- Shared file storage — holds the generated P12 keystore and truststore files at `/tls`
- Federator Gateway — consumes the P12 files for mTLS communication

A certificate manager failure can prevent the Federator Gateway from establishing secure connections. Follow the procedures below to restore the certificate manager to a working state.

---

### Rollback During Certificate Manager CI Pipeline Failure

If the **Certificate Manager CI pipeline fails**, no deployment rollback is required because no containers have been deployed.

Recommended actions:

1. Review the CI pipeline logs in Azure DevOps.
2. Fix any build or image issues.
3. Re-run the CI pipeline using the `certificate-manager-ci.yaml` pipeline.

Verify the image registry for successful image push:

```bash
aws ecr describe-repositories
```

```bash
aws ecr list-images --repository-name dpn-federator-certificate-manager --query 'imageIds[*].imageTag'
```

---

### Rollback During Certificate Manager CD Pipeline Failure

If the **Certificate Manager CD pipeline fails**, restore the previous working deployment using Helm.

1. List current Helm releases:

```bash
helm list -n <namespace>
```

2. Review the revision history for the certificate manager release:

```bash
helm history dpn-certificate-manager -n <namespace>
```

3. Roll back to the last successful revision:

```bash
helm rollback dpn-certificate-manager <revision-number> -n <namespace>
```

4. Verify that the certificate manager and Vault pods are in a `Running` state:

```bash
kubectl get pods -n <namespace>
```

5. Confirm the P12 keystore and truststore files are present at the shared storage location:

```bash
kubectl -n <namespace> exec <pod-name> -- ls /tls
```

---

### Vault Certificate Bundle Rollback

If an incorrect certificate bundle was loaded into the Vault (for example, mismatched key pair and certificate chain), the Vault secrets must be corrected by reloading the previous valid bundle.

> **Warning:** An incorrect or mismatched bundle will cause the certificate sync job to fail with a `KeyStoreCreationException`. Confirm the bundle integrity before reloading.

1. Verify the Vault is unsealed and accessible:

```bash
kubectl -n <namespace> exec vault-x -- vault status -format=json
```

2. If required, unseal the Vault:

```bash
kubectl -n <namespace> exec vault-x -- vault operator unseal <unseal_key>
```
3. Cleanup the vault contents, by logging into its UI and deleting the below files one by one. Confirm acceptance of delete when prompted.

- pki-client/node-net/client/keypair
- pki-client/node-net/client/certificate
- pki-client/node-net/client/ca-chain
- pki-client/node-net/client/keystore.password
- pki-client/node-net/client/truststore.password

4. Cleanup the below files from the file share (common storage),

- /tls/keystore.p12
- /tls/truststore.p12
- /tls/keystore.password
- /tls/truststore.password

by executing below command on the certificate manager pod:

```bash
kubectl -n <namespace> exec certificate-manager-x -- rm /tls/*
```

5. Reload the correct key pair:

```bash
kubectl -n <namespace> exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/keypair \
  privateKey="$(cat <orgname>.key)" \
  publicKey="$(openssl rsa -in <orgname>.key -pubout 2>/dev/null)"
```

6. Reload the correct CA chain:

```bash
kubectl -n <namespace> exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/ca-chain \
  chain="$(cat ca-chain.crt)"
```

7. Reload the correct signed certificate:

```bash
kubectl -n <namespace> exec vault-x -- env VAULT_TOKEN=<RootToken> vault kv put pki-client/node-net/client/certificate \
  certificate="$(cat certificate.crt)"
```

8. Restart the certificate manager pod to trigger a fresh synchronisation:

```bash
kubectl -n <namespace> delete po/<pod-id>
```

9. Monitor the logs and confirm the sync job completes without errors:

```bash
kubectl logs <certificate-manager-pod> -n <namespace>
```

---

### P12 Keystore Recovery

If the P12 keystore or truststore files at the `/tls` shared storage location are missing or corrupted:

1. Confirm the current state of the `/tls` directory:

```bash
kubectl -n <namespace> exec <pod-name> -- ls /tls
```

2. If files are absent or incomplete, restart both the Vault pod and the certificate manager pod to force regeneration:

```bash
kubectl -n <namespace> delete po/<vault-pod-id>
kubectl -n <namespace> delete po/<certificate-manager-pod-id>
```

3. Allow the certificate sync job to complete and verify the `/tls` directory again:

```bash
kubectl -n <namespace> exec <pod-name> -- ls /tls
```

4. Once the P12 files are confirmed present, restart the Federator Gateway pods so they pick up the regenerated certificates:

```bash
kubectl rollout restart deployment/federator-server -n <namespace>
kubectl rollout restart deployment/federator-client -n <namespace>
```

---

### Certificate Renewal Job Recovery

If the certificate renewal job is failing after the pods have been restarted following a prolonged outage, the stored certificates may have expired.

1. Check the certificate manager logs for renewal errors:

```bash
kubectl logs <certificate-manager-pod> -n <namespace>
```

2. If the renewal frequency threshold (`cert.renewalRateMs`) has been exceeded, the existing certificate bundle can no longer be renewed automatically. In this case, raise a new CSR request with DSI DSM to obtain a fresh certificate bundle.

3. Once the new bundle is received, reload the certificate bundle into Vault following the steps in [Vault Certificate Bundle Rollback](#vault-certificate-bundle-rollback).

> **Note:** If the certificate sync job fails with `KeyStoreException: Certificate chain is not valid`, verify that the CA chain, intermediate CA, signed certificate, and key pair stored in Vault all correspond to the same CSR and root CA. If there is a mismatch, request a new certificate bundle from DSI DSM.

---

## Part 3 — DPN Data Pipeline Rollback

The Data Pipeline deployment includes the following components per schema type:

| Component | Mode |
|-----------|------|
| Adaptor | Producer |
| Mapper | Producer |
| Extractor | Consumer |
| Mapper | Consumer |

---

### Rollback Data Pipeline Containers

If a data pipeline container fails after deployment:

1. Identify failing pods:

```bash
kubectl get pods -n <namespace>
```

2. Review pod logs to identify the root cause:

```bash
kubectl logs <pod-name> -n <namespace>
```

3. Roll back the Helm deployment or redeploy using the previous container image tag.

```bash
helm rollback <data-pipeline-release> <revision-number> -n <namespace>
```

---

### Rollback Kafka Topics for Data Pipelines

Kafka topics may contain invalid data as a result of a failed pipeline run.

Possible recovery actions depending on the failure:

- **Delete invalid messages** — use the Kafka UI to inspect and remove messages from the affected topic
- **Recreate the topic** — delete and recreate the topic if the topic configuration is incorrect
- **Restart the consumer pipeline** — redeploy the consumer containers to resume processing from the last committed offset

Access the Kafka UI to verify message flows:

```
http://kafka-ui:8085
```

---

### Rollback Storage Processing Jobs

If a file processing job fails:

1. Delete the failed Kubernetes job:

```bash
kubectl delete job <job-name> -n <namespace>
```

2. Re-trigger the adaptor CD pipeline to restart the file ingestion process from the beginning.

---

## Post-Rollback Verification

After performing any rollback procedure, verify overall system health using the following checks.

Check that all pods are in a `Running` state:

```bash
kubectl get pods -n <namespace>
```

Check that all services are exposed:

```bash
kubectl get svc -n <namespace>
```

Check that all deployments are healthy (`READY` should match `DESIRED`):

```bash
kubectl get deployments -n <namespace>
```

Verify pod logs are clean:

```bash
kubectl logs <pod-name> -n <namespace>
```

Confirm P12 keystore and truststore files are present (Certificate Manager):

```bash
kubectl -n <namespace> exec <pod-name> -- ls /tls
```

Verify Kafka cluster topics and message flows via the Kafka UI:

```
http://kafka-ui:8085
```

---

## Disaster Recovery Considerations

For critical deployment failures, the following recovery actions may be required:

- Restore Kubernetes deployments from the previous Helm revision
- Rebuild container images from the last stable tagged Git commit
- Reload the certificate bundle into Vault from a secure offline copy
- Restore Kafka topics if data corruption occurs
- Restart CI/CD pipelines with a corrected configuration

Organisations should maintain the following to ensure rollback operations can be performed quickly and safely:

- Versioned Helm charts with revision history retained
- Versioned container images in ACR with previous tags preserved
- Tagged Git releases for all components
- A securely stored copy of the certificate bundle (key pair, CA chain, signed certificate) outside of the cluster

---

## Review Notes

| Review Date | Last Reviewed By | Status | Semver Version (Major.Minor.Patch) |
|-------------|------------------|--------|-------------------------------------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
