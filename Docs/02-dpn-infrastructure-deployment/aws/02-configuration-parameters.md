# 02 - Configuration Parameters

This section defines the configuration parameters used during infrastructure deployment.

## Table of Contents

- [Purpose](#purpose)
- [Environment tfvars File (Required)](#environment-tfvars-file-required)
  - [Repository Structure for Infrastructure](#repository-structure-for-infrastructure)
- [1. Core Environment Parameters](#1-core-environment-parameters)
- [2. Networking and Subnet Parameters](#2-networking-and-subnet-parameters)
- [3. Application Parameters](#3-application-parameters)
- [4. EKS Parameters](#4-eks-parameters)
  - [4.1 Kubernetes Platform Resources](#41-kubernetes-platform-resources)
  - [4.2 Block Storage](#42-block-storage)
  - [4.3 Auto-Instrumentation](#43-auto-instrumentation)
- [5. Database Parameters](#5-database-parameters)
- [6. Security Parameters](#6-security-parameters)
  - [6.1 WAF Parameters](#61-waf-parameters)
  - [6.2 Other Security Settings](#62-other-security-settings)
- [7. Service Account Settings](#7-service-account-settings)
  - [7.1 File Scan Service](#71-file-scan-service)
- [8. Tags](#8-tags)
- [9. Backend configuration](#9-backend-configuration)
- [10. Validation Checklist Before Apply](#10-validation-checklist-before-apply)

## Purpose

This document consolidates common OpenTofu variable patterns used during deployment.

Parameter keys in your repository may differ. Treat the examples below as a reference model and map them to your `variables.tf`.

The values defined in sections 1-8 should be placed in `infrastructure/opentofu/environments/<env>.tfvars` file that specify environment-specific parameters. See [Environment tfvars File (Required)](#environment-tfvars-file-required) for details.

Values from section 9 should be placed in `infrastructure/opentofu/backend/<env>.hcl` file that specify backend (to be used at init)

## Environment tfvars File (Required)

Create `infrastructure/opentofu/environments/<env>.tfvars` before running the installation steps.

Use a fuller common structure similar to the repository environment files.

Why this `.tfvars` structure is used:

- It centralizes all environment-specific values in one file so the same OpenTofu code can be reused across dev/test/preprod.
- It keeps naming patterns consistent (`<env>-<region>-01`), which avoids drift between modules, pipelines, and resource groups.
- It captures security defaults expected by this platform (private endpoints, restricted network access, diagnostics enabled).
- It ensures pipeline runs are predictable because `tofu plan/apply` always resolves the same variable keys.
- It makes environment promotion easier (copy baseline, then change only approved values).

Important:

- `.tfvars` defines **application/infrastructure resource values**.
- OpenTofu backend/state settings are handled separately by bootstrap + pipeline backend configuration.


### Repository Structure for Infrastructure

Use a clear and discoverable common structure for pipeline organisation.
The example below is a common pattern based on the current repository layout.

Reference repository:

- https://github.com/energy-dsi/dpn-infrastructure-aws

---

## 1. Core Environment Parameters

Use the following core parameters to define the base deployment environment.

```hcl
project_name = "<project-name>" #example: dpn
environment  = "<env>"
aws_region   = "<aws-region>"

cluster_name       = "eks-<project-name>-<env>-<cluster-number>-<aws-region>"
kubernetes_version = "<kubernetes-version>" #1.35 recommended

vpc_cidr = "<vpc-cidr>"

azs = [
  "<az-1>",
  "<az-2>"
]
```

The solution can be deployed to 2 or more AZs.

## 2. Networking and Subnet Parameters

Use the following example subnet structure to model network segmentation. Ensure, that the number of subnet CIDRs mathes the number of AZs used in the deployment

```hcl
subnet_cidrs = {
  public = [
    "<CIDR-public-1>",
    "<CIDR-public-2>"
  ]

  mgmt = [
    "<CIDR-mgmt-1>",
    "<CIDR-mgmt-2>"
  ]

  data = [
    "<CIDR-app-1>",
    "<CIDR-app-2>"
  ]

  app = [
    "<CIDR-app-1>",
    "<CIDR-app-2>"
  ]
}
```

Use the following variables to control which networking resources to create

```hcl
use_existing_vpc = <true-or-false>
existing_vpc_id  = "<vpc-id>" #empty if use_existing_vpc=false

create_igw      =  <true-or-false>
create_nat      =  <true-or-false>
create_nlb_eips =  <true-or-false>
```

Transit gateway must exist at the moment of deployment. Use transit_gateway_id to point to the correct one.

```hcl
transit_gateway_id = "<tgw-id>"
```

## 3. Application Parameters

Use the following parameters to configure the application parameters

```hcl
enable_s3_malware_protection = <true-or-false>

enable_management_host_backend_access = <true-or-false>
management_host_ami_id                = "<ami-id>"

application_bucket_name = "<app-bucket-name>"
data_bucket_name        = "<data-bucket-name>"

data_bucket_force_destroy  = <true-or-false>
data_bucket_noncurrent_version_expiration_days = <retention-days>

domain_name      = "<app-hostname.example.com>"
ingress_hostname = "<app-hostname>"
route53_zone_id  = "<R53-id>"

endpoint_private_access = <true-or-false>
endpoint_public_access  = <true-or-false>

application_namespace              = "<app-namespace>"
load_balancer_controller_namespace = "<namespace>" #example: "kube-system"
alb_controller_chart_version       = "<version>" #example: "1.14.0"
alb_controller_image_tag           = "<tag>" #example: "v2.14.0"
```

Set `load_balancer_controller_namespace` to the namespace the AWS Load Balancer Controller already runs in, and confirm it against the cluster before the first apply. Treat it as a value to be discovered rather than chosen.

- One value feeds both the IRSA trust policy and the Kubernetes service account, so the two cannot drift apart.
- Changing it on a cluster with a live controller replaces the trust policy, and the controller loses its AWS permissions until the value matches the cluster again.

Pin the management host image with `management_host_ami_id`. Left to resolve dynamically, an unrelated apply can rebuild the management host when the upstream image is refreshed.

- Changing the value replaces the instance. Plan it as a rebuild.
- Track the deprecation date of the pinned image and update the pin deliberately.

## 4. EKS Parameters

Use the following parameters to configure the EKS cluster and node pools.

```hcl
enable_kubernetes_platform = <true-or-false>

eks_authentication_mode = "<auth-mode>" #example: "API_AND_CONFIG_MAP"
eks_bootstrap_cluster_creator_admin_permissions = <true-or-false>

enable_cloudwatch_observability        = <true-or-false>
cloudwatch_observability_addon_version = "<version>"
enable_ebs_csi_driver                  = <true-or-false>
ebs_csi_driver_version                 = "<version>"

eks_access_entries = {
  admin = {
    principal_arn     = "<principal-arn>"
    policy_arn        = "<policy-arn>"
    access_scope_type = "<access-scope>" #example: "cluster"
  }

  devops = {
    principal_arn     = "<principal-arn>"
    policy_arn        = "<policy-arn>"
    access_scope_type = "<access-scope>" #example: "cluster"
  }

  developer = {
    principal_arn     = "<principal-arn>"
    policy_arn        = "<policy-arn>"
    access_scope_type = "<access-scope>" #example: "namespace"
    namespaces        = [<list-of-namespaces>]
  }
}

system_node_group_instance_types = ["<instance-size>"]
system_node_group_desired_size   = <desired-size>
system_node_group_min_size       = <min-size>
system_node_group_max_size       = <max-size>

workload_node_group_instance_types = ["<instance-size>"]
workload_node_group_desired_size   = <desired-size>
workload_node_group_min_size       = <min-size>
workload_node_group_max_size       = <max-size>
```

### 4.1 Kubernetes Platform Resources

`enable_kubernetes_platform` controls whether the deployment manages Kubernetes and Helm resources alongside the AWS resources.

- With this enabled, a plan instantiates the Helm and Kubernetes providers, and both must reach the EKS API endpoint. Where that endpoint is private, run plan and apply from the management host or through a network tunnel to the endpoint rather than from a workstation.
- A workstation run against a private endpoint appears as a hang rather than a permissions error, because the private endpoint addresses resolve in public DNS.
- Enabling this on a cluster where the load balancer controller and its namespace already exist requires importing those objects into state first. See [03-installation-process.md](03-installation-process.md).

### 4.2 Block Storage

`enable_ebs_csi_driver` and `ebs_csi_driver_version` add the Amazon EBS CSI driver to the cluster as an EKS add-on.

- The driver provisions nothing on its own. A StorageClass naming the driver is a separate and required step, and this deployment does not create it — apply the class against the cluster after the deployment completes and before any workload claims block storage.
- Pin the version. An unpinned create takes whatever version AWS defaults to on the day, so clusters built weeks apart end up on different versions.
- The version is an in-place add-on update rather than a replacement. Setting it to the version already installed produces no change.
- A pinned version can fail the create on a newer Kubernetes release. This is intended: the deployment fails visibly rather than installing a different version.
- Block storage is the only storage this deployment provides, and it attaches to one node at a time. There is no shared file system and no parameter to add one, so a workload that needs several pods writing to the same volume has nothing to claim here — see [05-uninstall-decommissioning.md](05-uninstall-decommissioning.md) if an earlier release left a file system behind.

### 4.3 Auto-Instrumentation

Use the following parameters to control which deployments the CloudWatch Observability add-on auto-instruments.

```hcl
auto_monitor_all_services = <true-or-false>

auto_monitor_selected_deployments = {
  python = [
    "<namespace>/<deployment-name>"
  ]
}

auto_monitor_excluded_deployments = {
  python = [
    "<namespace>/<deployment-name>"
  ]
}
```

- `auto_monitor_all_services` – whether every workload behind a Service is instrumented. Set it explicitly. An add-on installed with no configuration for this key takes the chart's own default, which is on in the commercial regions, and the resolved value is not visible in the chart values or in the add-on configuration.
- `auto_monitor_selected_deployments` – the deployments to instrument while monitoring all services is off.
- `auto_monitor_excluded_deployments` – the deployments to leave alone where monitoring all services is on.
- Entries in both maps take the form `<namespace>/<deployment-name>`. A bare deployment name is accepted by the add-on schema and silently matches nothing.
- Both maps are keyed by language, so another runtime takes the same shape under its own key.
- Emptying a map does not remove a selection or an exclusion already applied — edit the list instead.

An annotation on the pod template takes precedence over both maps. A deployment whose template sets `instrumentation.opentelemetry.io/inject-<language>` to true is instrumented whether or not it appears in either map, so a workload that cannot carry an agent needs the annotation set to false in its own manifest.

`cloudwatch_observability_addon_version` pins the add-on. An unpinned create takes whatever version AWS defaults to on the day, which is how instrumentation reaches a cluster without being chosen. Confirm a workload starts with an agent before selecting it. See [04-rollback-procedures.md](04-rollback-procedures.md).

## 5. Database Parameters

This deployment creates no managed database, so there are no database parameters to set here.

The authentication service (Keycloak) ships a bundled PostgreSQL container on a persistent volume and is deployed that way by default. A managed database can be used for Keycloak instead, by setting `postgres.enabled` to false and pointing `KC_DB_URL` and `KC_DB_USERNAME` at an external endpoint. These are application values rather than infrastructure parameters, and are covered in [DPN Authentication Service (Keycloak) Configuration](../../03-dpn-application-deployment/aws-gha-beta/02-configuration/02-configure-dpn-authentication-service.md).

Where a managed database is chosen, the deploying organisation provisions it themselves.

The DynamoDB table created during bootstrap holds the OpenTofu state lock only. It stores no application data.


## 6. Security Parameters

### 6.1 WAF Parameters

This is an example configuration for WAF. Adjust the parameters to match the desired security posture. 

```hcl
enable_waf     = <true-or-false>
waf_rate_limit = 2000

blocked_country_codes = [
  "KP",
  "IR",
  "SY"
]

waf_allowed_http_methods = [
  "GET",
  "POST",
  "PUT",
  "PATCH",
  "DELETE",
  "HEAD",
  "OPTIONS"
]

waf_blocked_user_agent_regexes = [
  "(?i).*sqlmap.*",
  "(?i).*nikto.*",
  "(?i).*nmap.*",
  "(?i).*masscan.*",
  "(?i).*acunetix.*",
  "(?i).*dirbuster.*",
  "(?i).*zaproxy.*"
]
```


### 6.2 Other Security Settings

```hcl
enable_guardduty                   = <true-or-false>
enable_security_hub                = <true-or-false>
enable_cloudtrail                  = <true-or-false>
enable_aws_config                  = <true-or-false>
enable_session_manager_preferences = <true-or-false>

enable_vpc_endpoints                 = <true-or-false>
enable_restrictive_endpoint_policies = <true-or-false>

enable_vpc_flow_logs            = <true-or-false>
enable_network_firewall_logging = <true-or-false>
enable_waf_logging              = <true-or-false>

create_log_s3_buckets = <true-or-false>
```

This is an example egress configuration. Adjust it to match your desired security posture

```hcl
allowed_egress_fqdns = [
  ".amazonaws.com",
  ".ecr.amazonaws.com",
  ".ecr.aws",
  ".eks.amazonaws.com",
  ".compute.amazonaws.com",
  "packages.us-east-1.amazonaws.com"
]
```

## 7. Service Account Settings

```hcl
irsa_service_accounts = {
  external-secrets = {
    namespace       = "<namespace>"
    service_account = "<service-account>"

    policy_json = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:*:<aws-account-id>:secret:<secret-path>*"
    }
  ]
}
POLICY
  }
}
```

A workload that reads AWS credentials from environment variables uses those in preference to its IRSA role, so the role appears unused. This is the most common reason IRSA appears not to be working.

### 7.1 File Scan Service

Use the following parameters to create the IRSA role used by the file scan service and to declare the buckets it consumes.

```hcl
enable_file_scan_service_irsa  = <true-or-false>
file_scan_service_namespace    = "<namespace>"
file_scan_service_account_name = "<service-account>"

consumer_buckets = {
  stage = "<bucket-name>"
}
```

- The role is inert until the Kubernetes service account carries the role ARN annotation and the namespace exists. This deployment creates the infrastructure half only.
- Consumer bucket names carry `prevent_destroy`, so renaming one produces a failed plan rather than a rename. Choose the names once.

The application half of the file scan service is covered in [Configure DPN File Scan Service](../../03-dpn-application-deployment/aws-gha-beta/02-configuration/08-configure-dpn-file-scan-service.md) and [File Scan Service Installation Process](../../03-dpn-application-deployment/aws-gha-beta/03-installation/08-dpn-file-scan-service-installation-process.md).

## 8. Tags

Use the following parameters to control resources tagging. Add additonal tags if necessary.

```hcl
tags = {
  project      = "<project-name>"
  environment  = "<env>"
  managed_by   = "opentofu"
  data_class   = "participant"
  architecture = "dpn-eks"
}
```

## 9. Backend configuration

Use the following backend template to connect OpenTofu to remote state storage. This configuration should be placed in backend\env.hcl file (to be used at init).

kms_key_id should be used only if encryption is enabled. Make sure that the role that is used for OpenTofu deployments has permissions to use this key.

```hcl
bucket         = "<YOUR-TF-STATE-BUCKET>"
key            = "<YOUR-TF-STATE-FILE-IN-BUCKET>"
region         = "<YOUR-REGION>"
dynamodb_table = "<YOUR-DYNAMODB-TABLE-WITH-TF-STATE>"
encrypt        = <true-or-false>
kms_key_id = "<YOUR-KMS-KEY-ID>"
```

Backend note: keep backend/state storage values aligned with your bootstrap output and pipeline variables.


## 10. Validation Checklist Before Apply

Review the following checks to confirm the configuration is ready for execution.

- Confirm no placeholder tokens remain in tfvars (for example `<env>`, `<aws-region>`, `{instance}`).
- Confirm resource names are globally valid where required (especially storage account naming rules).
- Confirm `aws-region` matches the intended AWS region for all deployed services.
- Run `tofu validate` and fix any errors before the first `tofu plan`.

---

Continue with [03-installation-process.md](03-installation-process.md)