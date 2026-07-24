#!/bin/sh
# Prerequisites — run BEFORE any manifest in this directory.
# Execute on a host that has kubectl configured against the target cluster
# (e.g. via `aws eks update-kubeconfig`), with a namespace named
# ns-dpn-health-01 already existing and a namespace ns-dpn-01 that already
# has a working ghcr-pull-secret (adjust the source namespace/secret name
# below if your source differs). ns-dpn-01 and its ghcr-pull-secret are
# created by the 00-shared-prerequisites and 01-vault-certificate-manager
# components, which must be deployed before this one.
set -eu

NAMESPACE="ns-dpn-health-01"
SOURCE_NAMESPACE="ns-dpn-01"

echo "=== Ensure namespace exists ==="
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

echo "=== Copy ghcr-pull-secret from $SOURCE_NAMESPACE into $NAMESPACE ==="
# Do NOT hand-author this secret's content — copy the real one so the
# credential inside it isn't duplicated by hand or drifted from the source.
kubectl get secret ghcr-pull-secret -n "$SOURCE_NAMESPACE" -o json \
  | jq '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: "'"$NAMESPACE"'"}}' \
  | kubectl apply -f -

echo "=== Verify StorageClasses ==="
# efs-sc must exist and actually work (EFS CSI driver installed and healthy).
# gp2 (in-tree kubernetes.io/aws-ebs provisioner) is known-broken on
# Kubernetes 1.27+ with no EBS CSI driver installed — every manifest in this
# directory uses efs-sc for exactly this reason. If your cluster instead has
# a working EBS CSI driver and a gp2/gp3 StorageClass, you may switch, but
# verify first: create a throwaway PVC and confirm it reaches Bound before
# trusting it under load.
kubectl get storageclass

echo "=== Check node health before deploying ==="
# Confirm your nodes can actually assign pod IPs before applying anything
# PVC-bearing — a node with broken VPC-CNI networking (e.g. subnet-level IP
# exhaustion) will strand pods in ContainerCreating, and WaitForFirstConsumer
# PVCs pin themselves permanently to whatever node they first attempt
# scheduling on, even on failure. Test for it directly:
#   kubectl run net-test --image=nginx:1.27-alpine --restart=Never -n ns-dpn-health-01
#   kubectl get pod net-test -n ns-dpn-health-01 -o wide   # note NODE
#   kubectl describe pod net-test -n ns-dpn-health-01 | grep -i "FailedCreatePodSandBox"
#   kubectl delete pod net-test -n ns-dpn-health-01
# If a node shows this symptom, exclude it via nodeAffinity in the affected
# manifest(s) — see RUNBOOK.md Troubleshooting for an example. Manifests in
# this directory ship with no such exclusion; add one only if your cluster
# actually needs it.
echo "See comments in this script — verify node health before assuming your"
echo "cluster needs any node-exclusion workaround."

echo "=== Check available CPU headroom before deploying ==="
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- $n ---"
  kubectl describe node "$n" | grep -A5 "Allocated resources"
done
echo "If headroom is tight, trim resources.requests.cpu in each manifest"
echo "before applying — see RUNBOOK.md 'Capacity' section."

echo "Prereqs complete."
