# 02 - Configuration Parameters

This section defines the configuration parameters used during infrastructure deployment.


## Purpose

This document consolidates common OpenTofu variable patterns used during deployment.

Parameter keys in your repository may differ. Treat the examples below as a reference model and map them to your `variables.tf`.

The values defined in sections 1-8 should be placed in `infrastructure/opentofu/environments/<env>.tfvars` file that specify environment-specific parameters. See section 10 for details

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

application_bucket_name = "<app-bucket-name>"
data_bucket_name        = "<data-bucket-name>"

data_bucket_force_destroy  = <true-or-false>
data_bucket_noncurrent_version_expiration_days = <retention-days>

domain_name      = "<app-hostname.example.com>"
ingress_hostname = "<app-hostname>"
route53_zone_id  = "<R53-id>"

endpoint_private_access = <true-or-false>
endpoint_public_access  = <true-or-false>

application_namespace        = "<app-namespace>"
alb_controller_chart_version = "<version>" #example: "1.14.0"
alb_controller_image_tag     = "<tag>" #example: "v2.14.0"
```


## 4. EKS Parameters

Use the following parameters to configure the EKS cluster and node pools.

```hcl
enable_kubernetes_platform = <true-or-false>

eks_authentication_mode = "<auth-mode>" #example: "API_AND_CONFIG_MAP"
eks_bootstrap_cluster_creator_admin_permissions = <true-or-false>

enable_cloudwatch_observability = <true-or-false>
enable_efs_csi_driver           = <true-or-false>

eks_access_entries = {
  admin = {
    principal_arn     = "<principal-arn>"
    policy_arn        = "<policy-arn>y"
    access_scope_type = "<acces-scope>" #example: "cluster"
  }

  devops = {
    principal_arn     = "<principal-arn>"
    policy_arn        = "<policy-arn>y"
    access_scope_type = "<acces-scope>" #example: "cluster"
  }

  developer = {
    principal_arn     = "<principal-arn>"
    policy_arn        = "<policy-arn>y"
    access_scope_type = "<acces-scope>" #example: "namespace"
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
## 5. Database Parameters

Use the folowing parameters to configure application database

```hcl
db_name                  = "<db-name>"
db_engine_version        = "<eng-version>" #example: "16.3"
db_instance_class        = "<db-size>"
db_allocated_storage     = <db-storage-in-GB>
db_max_allocated_storage = <db-max-storage-in-GB>
db_admin_username   = "<db-admin-username>"
backup_retention_days    = <db-retention>

db_admin_secret_name = "<path-to-secret>"
```


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


## 12. Validation Checklist Before Apply

Review the following checks to confirm the configuration is ready for execution.

- Confirm no placeholder tokens remain in tfvars (for example `<env>`, `<aws-region>`, `{instance}`).
- Confirm resource names are globally valid where required (especially storage account naming rules).
- Confirm `aws-region` matches the intended AWS region for all deployed services.
- Run `tofu validate` and fix any errors before the first `tofu plan`.

---

Continue with [03-installation-process.md](03-installation-process.md)