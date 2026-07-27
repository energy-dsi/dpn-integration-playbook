# 02 - Configuration Parameters

This section defines the configuration parameters used during infrastructure deployment.

## Table of Contents

- [Purpose](#purpose)
- [1. Core Environment Parameters](#1-core-environment-parameters)
- [2. Subnet Parameters](#2-subnet-parameters)
- [3. Key Vault Parameters](#3-key-vault-parameters)
- [4. ACR Parameters](#4-acr-parameters)
- [5. AKS Parameters](#5-aks-parameters)
- [6. Storage Parameters](#6-storage-parameters)
  - [6.1 Application Storage Account](#61-application-storage-account)
  - [6.2 State Storage Account (OpenTofu Backend)](#62-state-storage-account-opentofu-backend)
  - [6.3 Observability Logging Storage Account](#63-observability-logging-storage-account)
- [7. File Scanning Service Parameters](#7-file-scanning-service-parameters)
  - [7.1 Event Grid Parameters](#71-event-grid-parameters)
  - [7.2 Service Bus Parameters](#72-service-bus-parameters)
  - [7.3 File Scanning Storage Account Parameters](#73-file-scanning-storage-account-parameters)
    - [File Scanning Service Principal – Role Assignment Summary](#file-scanning-service-principal--role-assignment-summary)
- [8. Backend Configuration Template](#8-backend-configuration-template)
- [9. VM Parameters](#9-vm-parameters)
- [10. Environment tfvars File (Required)](#10-environment-tfvars-file-required)
- [11. Azure DevOps Configuration for Infrastructure Deployment](#11-azure-devops-configuration-for-infrastructure-deployment)
  - [Service Connection Setup](#service-connection-setup)
  - [Service Principal Configuration (Template)](#service-principal-configuration-template)
  - [Self-Hosted Agent Pool Configuration](#self-hosted-agent-pool-configuration)
  - [Repository Structure for Infrastructure](#repository-structure-for-infrastructure)
  - [Variable Group and Key Vault Usage](#variable-group-and-key-vault-usage)
  - [Deployment Connectivity Flow](#deployment-connectivity-flow)
- [12. Validation Checklist Before Apply](#12-validation-checklist-before-apply)

## Purpose

This document consolidates common OpenTofu variable patterns used during deployment.

Parameter keys in your repository may differ. Treat the examples below as a reference model and map them to your `variables.tf`.

---

## 1. Core Environment Parameters

Use the following core parameters to define the base deployment environment.

```hcl
subscription_id          = "YOUR-SUBSCRIPTION-ID"
vnet_name                = "vnet-dpn-<env>-<region>-01"
vnet_resource_group_name = "rg-dpn-<env>-<region>-01"
location                 = "<azure-region>"
location_short           = "<region-short-code>"
environment              = "<env>"
instance_number          = "01"
```

## 2. Subnet Parameters

Use the following example subnet structure to model network segmentation.

```hcl
subnets = {
  snet-aks-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/27"   # 32 addresses
    create_nsg                        = true
    nsg_name                          = "nsg-aks-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  snet-keyvault-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/29"   # 8 addresses
    create_nsg                        = true
    nsg_name                          = "nsg-keyvault-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  snet-acr-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/29"   # 8 addresses
    create_nsg                        = true
    nsg_name                          = "nsg-acr-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  snet-loganalytics-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/29"   # 8 addresses
    create_nsg                        = true
    nsg_name                          = "nsg-loganalytics-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  snet-devstorage-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/29"   # 8 addresses for developer storage
    create_nsg                        = true
    nsg_name                          = "nsg-devstorage-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  snet-vm-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/28"   # 16 addresses for Windows VMs
    create_nsg                        = true
    nsg_name                          = "nsg-vm-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  snet-evgt-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/29"   # 8 addresses for Event Grid private endpoint
    create_nsg                        = true
    nsg_name                          = "nsg-evgt-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  snet-sb-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/29"   # 8 addresses for Service Bus private endpoint
    create_nsg                        = true
    nsg_name                          = "nsg-sb-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  snet-stfs-dpn-<env>-<region>-01 = {
    address_prefix                    = "10.x.x.x/29"   # 8 addresses for file scanning service storage private endpoint
    create_nsg                        = true
    nsg_name                          = "nsg-stfs-dpn-<env>-<region>-01"
    nsg_rules                         = {}
    delegation                        = null
    default_outbound_access_enabled   = true
    private_endpoint_network_policies = "Enabled"
  }
  # snet-tfstate-dpn-<env>-<region>-01 subnet is managed by the bootstrap pipeline and excluded from OpenTofu
}
```

## 3. Key Vault Parameters

Use the following parameters to configure Azure Key Vault for the environment.

```hcl
keyvault_name                            = "kv-dpn-<env>-<region>-01"
keyvault_resource_group_name             = "rg-kv-dpn-<env>-<region>-01"
keyvault_public_network_access_enabled   = false
keyvault_sku_name                        = "standard"
keyvault_soft_delete_retention_days      = 90
keyvault_purge_protection_enabled        = true
keyvault_enabled_for_disk_encryption     = true
keyvault_enabled_for_deployment          = true
keyvault_enabled_for_template_deployment = true
keyvault_rbac_authorization_enabled      = true
keyvault_network_acls_bypass             = "AzureServices"
keyvault_network_acls_default_action     = "Deny"
keyvault_network_acls_enabled            = true
keyvault_allowed_ip_ranges               = []
keyvault_allowed_subnet_ids              = []
keyvault_admin_object_ids                = []
keyvault_secrets_officer_object_ids      = ["<pipeline-spn-object-id>"]
keyvault_secrets_user_object_ids         = ["<dev-team-spn-object-id>"]
keyvault_initial_secrets                 = {}
keyvault_initial_keys                    = {}
```

## 4. ACR Parameters

Use the following parameters to configure Azure Container Registry.

```hcl
acr_name                          = "acrdpn<env><region>01"
acr_resource_group_name           = "rg-acr-dpn-<env>-<region>-01"
acr_public_network_access_enabled = false
acr_sku                           = "Premium"
acr_admin_enabled                 = false
acr_anonymous_pull_enabled        = false
acr_zone_redundancy_enabled       = true
acr_network_rules_enabled         = true
acr_network_rule_default_action   = "Deny"
acr_allowed_ip_ranges             = []
acr_retention_policy_enabled      = true
acr_retention_policy_days         = 7
acr_trust_policy_enabled          = false
acr_encryption_enabled            = false
acr_key_vault_key_id              = ""
acr_create_scope_maps             = false
acr_webhooks                      = {}
acr_georeplications               = {}
acr_enable_diagnostic_settings    = true
```

## 5. AKS Parameters

Use the following parameters to configure the AKS cluster and node pools.

```hcl
aks_name                = "aks-dpn-<env>-<region>-01"
aks_resource_group_name = "rg-aks-dpn-<env>-<region>-01"
aks_node_resource_group = "rg-aks-dpn-<env>-<region>-01-nodes"
aks_vnet_subnet_name    = "snet-aks-dpn-<env>-<region>-01"
aks_kubernetes_version  = "1.33"
aks_private_dns_zone_id = "<private-dns-zone-resource-id>"
aks_admin_group         = ["<admin-group-object-id>"]

# Node pool
aks_vm_size                   = "Standard_D16lds_v6"
aks_node_count                = 3
aks_enable_auto_scaling       = true
aks_min_count                 = 3
aks_max_count                 = 6
aks_default_node_pool_name    = "default"
aks_node_pool_zones           = []
aks_max_surge                 = "10%"
aks_drain_timeout_in_minutes  = 0
aks_node_soak_duration_in_minutes = 0

# Workload node pool
aks_enable_workload_node_pool                    = false
aks_workload_node_pool_count                     = 3
aks_workload_node_pool_vm_size                   = "Standard_D16lds_v6"
aks_workload_node_pool_name                      = "workload"
aks_workload_node_pool_taints                    = []
aks_workload_node_pool_host_encryption_enabled   = true
aks_workload_node_pool_label_key                 = "workload"
aks_workload_node_pool_label_value               = "true"
aks_workload_node_pool_zones                     = []

# Upgrades
aks_sku_tier                  = "Standard"
aks_automatic_upgrade_channel = "stable"
aks_node_os_upgrade_channel   = "NodeImage"

# Security
aks_azure_policy_enabled      = true
aks_local_account_disabled    = true
aks_oidc_issuer_enabled       = true
aks_workload_identity_enabled = true
aks_host_encryption_enabled   = true
aks_azure_rbac_enabled        = true
aks_secret_rotation_enabled   = true
aks_secret_rotation_interval  = "2m"

# Networking
aks_network_plugin      = "azure"
aks_network_plugin_mode = "overlay"
aks_network_policy      = "calico"
aks_load_balancer_sku   = "standard"
aks_service_cidr        = "10.0.0.0/16"
aks_dns_service_ip      = "10.0.0.10"

# Private cluster
aks_private_cluster_enabled = true

# Identity
aks_identity_type                = "UserAssigned"
aks_user_assigned_identity_type  = "UserAssigned"
aks_acr_pull_role_name           = "AcrPull"

# Service mesh (Istio)
aks_service_mesh_mode      = "Istio"
aks_service_mesh_revisions = ["asm-1-27"]

# Diagnostics
aks_enable_diagnostic_settings           = true
aks_diagnostic_all_metrics_category      = "AllMetrics"
aks_diagnostic_all_logs_category_group   = "allLogs"
aks_http_application_routing_enabled     = false
```

## 6. Storage Parameters

Use two storage account patterns:

- **State storage account**: hosts OpenTofu state (backend)
- **Application storage account**: used by workloads

### 6.1 Application Storage Account 

```hcl
storage_account_name                    = "stdpn<env><region>01"
storage_resource_group_name             = "rg-storage-dpn-<env>-<region>-01"
storage_account_tier                    = "Standard"
storage_account_replication_type        = "RAGRS"
storage_account_kind                    = "StorageV2"
storage_access_tier                     = "Hot"
storage_public_network_access_enabled   = false
storage_allow_nested_items_to_be_public = false
storage_min_tls_version                 = "TLS1_2"
storage_enable_https_traffic_only       = true
storage_shared_access_key_enabled       = true
storage_is_hns_enabled                  = false
storage_large_file_share_enabled        = false
storage_versioning_enabled              = true
storage_blob_retention_days             = 7
storage_container_retention_days        = 7
storage_network_rules_default_action    = "Deny"
storage_network_rules_bypass            = ["AzureServices"]
storage_create_blob_endpoint            = true
storage_create_queue_endpoint           = false
storage_create_table_endpoint           = false
enable_diagnostic_settings              = true
storage_file_share_name                 = "fsdpn<env><region>01"
storage_file_share_quota_gb             = 1
storage_create_file_endpoint            = true
team_spn_object_id                      = "<dev-team-spn-object-id>"
private_dns_zone_resource_group         = "rg-pdns-prd-<region>-01"
connectivity_subscription_id            = "<connectivity-subscription-id>"
additional_blob_contributor_principal_ids = []  # e.g. grant `Storage Blob Data Contributor` to another service's SPN that needs cross-account access — see 7.3 for the File Scanning Service example
```

### 6.2 State Storage Account (OpenTofu Backend)

This backend block is pipeline/bootstrap-driven. Keep values aligned with bootstrap outputs and pipeline variables (`BACKEND_RESOURCE_GROUP`, `BACKEND_STORAGE_ACCOUNT`, `BACKEND_KEY`).
Current bootstrap implementation uses `Standard_RAGRS` for the backend storage account.

```hcl
state_storage_account_name       = "sttf<project><env><region>01"
state_storage_resource_group     = "rg-tfstate-<env>-<region>-01"
state_storage_account_tier       = "Standard"
state_storage_replication_type   = "RAGRS"
state_container_name             = "tfstate"
state_key                        = "dpn-{env}.opentofu.tfstate"
```

### 6.3 Observability Logging Storage Account

This is a dedicated storage account used to centralize observability logging/diagnostic export, kept separate from the application, developer, and file scanning storage accounts.

```hcl
observability_logging_storage_account_name                  = "stobsdpn<env><region>01"
observability_logging_storage_resource_group_name           = "rg-obs-dpn-<env>-<region>-01"
observability_logging_storage_subnet_name                   = "snet-stfs-dpn-<env>-<region>-01"  # confirm whether your environment should use a dedicated subnet instead
observability_logging_storage_account_tier                  = "Standard"
observability_logging_storage_replication_type              = "LRS"
observability_logging_storage_account_kind                  = "StorageV2"
observability_logging_storage_access_tier                   = "Hot"
observability_logging_storage_public_network_access_enabled = false
observability_logging_storage_min_tls_version                = "TLS1_2"
observability_logging_storage_versioning_enabled             = true
observability_logging_storage_blob_retention_days            = 7
observability_logging_storage_container_retention_days       = 7
observability_logging_storage_create_blob_endpoint           = true
observability_logging_storage_file_share_name                = ""    # set to enable an Azure Files share
observability_logging_storage_file_share_quota_gb            = 1
observability_logging_storage_create_file_endpoint           = false
observability_logging_storage_enable_diagnostic_settings     = true
observability_logging_storage_dev_team_spn_object_id         = "<dev-team-spn-object-id>"
observability_logging_storage_data_receiver_principal_ids    = []  # e.g. ["<log-consumer-spn-object-id>"] to grant Storage Blob Data Reader
observability_logging_storage_data_contributor_principal_ids = []  # e.g. ["<log-shipper-spn-object-id>"] to grant Storage Blob Data Contributor
```

Notes:

- Leave `observability_logging_storage_file_share_name` empty unless the observability workload requires an Azure Files share in addition to blob storage.
- `observability_logging_storage_create_file_endpoint` only takes effect when a file share name is also set.
- `observability_logging_storage_data_receiver_principal_ids` / `observability_logging_storage_data_contributor_principal_ids` default to `[]`; populate them once the log shipper/consumer service principal object IDs are known for the target environment.

## 7. File Scanning Service Parameters

The File Scanning Service is made up of three components: an Event Grid topic, a Service Bus namespace, and a dedicated storage account. Each has its own private endpoint and subnet (see Section 2).

### 7.1 Event Grid Parameters

```hcl
event_grid_topic_name                    = "evgt-dpn-<env>-<region>-01"
event_grid_resource_group_name           = "rg-evgt-dpn-<env>-<region>-01"
event_grid_subnet_name                   = "snet-evgt-dpn-<env>-<region>-01"
event_grid_local_auth_enabled            = false
event_grid_public_network_access_enabled = true
event_grid_enable_diagnostic_settings    = true
event_grid_data_receiver_principal_ids   = ["<file-scanning-service-spn-object-id>"]
event_grid_data_sender_principal_ids     = ["<file-scanning-service-spn-object-id>"]
event_grid_contributor_principal_ids     = ["<dev-team-spn-object-id>"]
```

Notes:

- `local_auth_enabled = false` disables topic access/SAS keys; access is via Azure AD role assignments only.
- Unlike Service Bus and the file scanning storage account (both private-endpoint only), the Event Grid topic in this reference deployment is created with `public_network_access_enabled = true` **in addition to** its private endpoint. Confirm this is the intended posture for your environment; if not required, set this to `false` and rely on the private endpoint only.

### 7.2 Service Bus Parameters

```hcl
service_bus_namespace_name                = "sb-dpn-<env>-<region>-01"
service_bus_resource_group_name           = "rg-sb-dpn-<env>-<region>-01"
service_bus_subnet_name                   = "snet-sb-dpn-<env>-<region>-01"
service_bus_sku                           = "Premium"
service_bus_capacity                      = 1
service_bus_premium_messaging_partitions  = 1
service_bus_public_network_access_enabled = false
service_bus_local_auth_enabled            = false
service_bus_minimum_tls_version           = "1.2"
service_bus_trusted_services_allowed      = false
service_bus_enable_diagnostic_settings    = true
service_bus_queues                        = {
  # Example queue definition
  # file-scan-requests = {
  #   max_size_in_megabytes = 1024
  #   default_message_ttl   = "P14D"
  #   lock_duration         = "PT1M"
  # }
}
service_bus_data_receiver_principal_ids = ["<file-scanning-service-spn-object-id>"]
service_bus_data_sender_principal_ids   = ["<file-scanning-service-spn-object-id>"]
service_bus_data_owner_principal_ids    = ["<dev-team-spn-object-id>"]
```

Notes:

- `service_bus_sku = "Premium"` is required to support the private endpoint; do not downgrade the SKU without also removing the private endpoint.
- Leave `service_bus_queues = {}` if queues are provisioned separately (for example, via application deployment).
- `service_bus_data_receiver_principal_ids` grants `Azure Service Bus Data Receiver` to the file scanning service principal. This is one of the three role assignments the file scanning service principal needs across components — see [7.3](#73-file-scanning-storage-account-parameters) for the other two.

### 7.3 File Scanning Storage Account Parameters

```hcl
file_scanning_service_storage_account_name                    = "stfss<env><region>01"
file_scanning_service_storage_resource_group_name             = "rg-stfs-dpn-<env>-<region>-01"
file_scanning_service_storage_subnet_name                     = "snet-stfs-dpn-<env>-<region>-01"
file_scanning_service_storage_account_tier                    = "Standard"
file_scanning_service_storage_replication_type                = "LRS"
file_scanning_service_storage_account_kind                    = "StorageV2"
file_scanning_service_storage_access_tier                     = "Hot"
file_scanning_service_storage_public_network_access_enabled   = false
file_scanning_service_storage_min_tls_version                 = "TLS1_2"
file_scanning_service_storage_versioning_enabled               = true
file_scanning_service_storage_blob_retention_days              = 7
file_scanning_service_storage_container_retention_days         = 7
file_scanning_service_storage_create_blob_endpoint             = true
file_scanning_service_storage_file_share_name                  = ""    # set to enable an Azure Files share
file_scanning_service_storage_file_share_quota_gb               = 1
file_scanning_service_storage_create_file_endpoint              = false
file_scanning_service_storage_enable_diagnostic_settings        = true
file_scanning_service_storage_dev_team_spn_object_id             = "<dev-team-spn-object-id>"
file_scanning_service_storage_data_receiver_principal_ids        = ["<file-scanning-service-spn-object-id>"]
file_scanning_service_storage_data_contributor_principal_ids     = ["<file-scanning-publisher-spn-object-id>"]

# Cross-account grant: also give the file scanning service principal access to the
# EXISTING developer/application storage account (Section 6.1), not just the new one above.
additional_blob_contributor_principal_ids = ["<file-scanning-service-spn-object-id>"]
```

Notes:

- Leave `file_scanning_service_storage_file_share_name` empty unless the file scanning workload requires an Azure Files share in addition to blob storage.
- `file_scanning_service_storage_create_file_endpoint` only takes effect when a file share name is also set.
- `additional_blob_contributor_principal_ids` is a parameter of the **existing** developer/application storage module (Section 6.1), not the new file scanning storage account. It grants `Storage Blob Data Contributor` on the existing storage account to the file scanning service principal, alongside its own permissions on the new storage account.

#### File Scanning Service Principal – Role Assignment Summary

The file scanning service principal needs the following three role assignments, one per component, using the same principal ID across all three:

| Component | Role | Variable |
|---|---|---|
| Service Bus namespace | `Azure Service Bus Data Receiver` | `service_bus_data_receiver_principal_ids` |
| New file scanning storage account | `Storage Blob Data Reader` | `file_scanning_service_storage_data_receiver_principal_ids` |
| Existing developer/application storage account | `Storage Blob Data Contributor` | `additional_blob_contributor_principal_ids` (Section 6.1) |

The file scanning service principal's object ID is different for each environment (dev/test/preprod/prod) — it is a distinct SPN per environment, not one ID reused everywhere. Obtain and confirm the correct object ID for the target environment before running `apply`; do not copy the dev value into another environment's tfvars.

## 8. Backend Configuration Template

Use the following backend template to connect OpenTofu to remote state storage.

```hcl
resource_group_name  = "<bootstrap-rg>"
storage_account_name = "<state-storage-account>"
container_name       = "tfstate"
key                  = "dpn-{env}.opentofu.tfstate"
```

Backend note: keep backend/state storage values aligned with your bootstrap output and pipeline variables.

## 9. VM Parameters

Use the following VM parameter block for the required management / jump VM.

```hcl
vm_name                                 = "vm-dpn-<env>-<region>-01"
vm_resource_group_name                  = "rg-vm-dpn-<env>-<region>-01"
vm_size                                 = "Standard_D2lds_v6"
vm_computer_name                        = "dpn-<env>-vm01"
vm_admin_username                       = "azureuser"
vm_admin_password                       = null
vm_admin_password_secret_name           = "vm-dpn-<env>-<region>-01-admin-password"
vm_subnet_name                          = "snet-vm-dpn-<env>-<region>-01"
vm_private_ip_allocation                = "Dynamic"
vm_private_ip_address                   = null
vm_create_nsg                           = true
vm_os_disk_caching                      = "ReadWrite"
vm_os_disk_storage_account_type         = "Premium_LRS"
vm_os_disk_size_gb                      = 127
vm_image_publisher                      = "MicrosoftWindowsServer"
vm_image_offer                          = "WindowsServer"
vm_image_sku                            = "2022-datacenter-azure-edition"
vm_image_version                        = "latest"
vm_identity_type                        = "SystemAssigned"
vm_enable_boot_diagnostics              = true
vm_boot_diagnostics_storage_account_uri = null
vm_patch_mode                           = "AutomaticByPlatform"
vm_patch_assessment_mode                = "AutomaticByPlatform"
vm_enable_automatic_updates             = true
vm_encryption_at_host_enabled           = true
vm_secure_boot_enabled                  = true
vm_vtpm_enabled                         = true
vm_license_type                         = "None"
vm_timezone                             = "GMT Standard Time"
vm_availability_zone                    = null
vm_enable_diagnostic_settings           = true
```

VM security baseline:

- Keep VM private (no public IP) unless explicitly required.
- Store admin password/secret in Key Vault (do not commit to tfvars).
- Apply NSG restrictions and just-in-time/controlled access patterns.
- Enable diagnostics/monitoring to central Log Analytics.

## 10. Environment tfvars File (Required)

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

Example common template:

```hcl
# Keep only deployment values in this file; backend settings come from pipeline/bootstrap.
subscription_id = "<subscription-id>"
location        = "<azure-region>"
location_short  = "<region-short-code>"
environment     = "<env>"
instance_number = "01"

# Core references
vnet_name                = "vnet-dpn-<env>-<region>-01"
vnet_resource_group_name = "rg-dpn-<env>-<region>-01"
subnets                  = { ... }

# Platform services
keyvault_name                = "kv-dpn-<env>-<region>-01"
acr_name                     = "acrdpn<env><region>01"
aks_name                     = "aks-dpn-<env>-<region>-01"
storage_account_name         = "stdpn<env><region>01"
storage_resource_group_name  = "rg-storage-dpn-<env>-<region>-01"
dev_storage_account_name     = "stdevdpn<env><region>01"
workload_identity_name       = "id-aks-workload-dpn-<env>-<region>-01"
vm_name                      = "vm-dpn-<env>-<region>-01"

# File Scanning Service
event_grid_topic_name                      = "evgt-dpn-<env>-<region>-01"
service_bus_namespace_name                 = "sb-dpn-<env>-<region>-01"
file_scanning_service_storage_account_name = "stfss<env><region>01"

# Observability logging storage
observability_logging_storage_account_name = "stobsdpn<env><region>01"

# Observability and tags
log_analytics_workspace_name = "law-dpn-<env>-<region>-01"
enable_diagnostic_settings   = true
tags                         = { ... }
```

Use Sections 1-9 in this document to populate the full value set.
Use `infrastructure/opentofu/environments/*.tfvars` as the source for environment-specific examples.

Tip: keep a short mapping table from this guide's sample keys to your exact keys in `variables.tf`.

## 11. Azure DevOps Configuration for Infrastructure Deployment

Configure Azure DevOps to manage infrastructure deployment pipelines and prepare for subsequent application deployment.

### Service Connection Setup

Create an Azure DevOps Service Connection to enable infrastructure deployment pipelines.

**Required Service Principal Roles:**

- **Contributor** – for creating and managing Azure resources via OpenTofu
- **User Access Administrator** – for managing RBAC assignments
- **Azure Container Registry Push/Pull** – for container registry access

### Service Principal Configuration (Template)

Create one dedicated non-human service principal for infrastructure pipelines.

Suggested properties:

- Name: `spn-iac-<env>`
- Authentication: certificate or federated credentials (preferred over client secret)
- Scope: subscription or dedicated resource groups used by the environment
- Rotation: follow your security policy for credential/certificate lifecycle

Recommended least-privilege roles:

- **Contributor** at deployment scope
- **User Access Administrator** only if OpenTofu creates role assignments
- **Storage Blob Data Owner** on the backend state storage account used by OpenTofu
- **Reader** on connectivity/dns subscription when private DNS lives centrally, based on the organisation network architecture

**Create Service Connection:**

```bash
az devops service-endpoint azurerm create \
  --name "dpn-infrastructure-<env>" \
  --azure-rm-service-principal-id "<sp-client-id>" \
  --azure-rm-service-principal-key "<sp-client-secret>" \
  --azure-rm-subscription-id "$SUBSCRIPTION_ID" \
  --azure-rm-subscription-name "<subscription-name>"
```

### Self-Hosted Agent Pool Configuration

Configure a self-hosted agent pool in Azure DevOps for infrastructure deployment operations.

**Agent Pool Setup:**

```bash
az devops admin pipelines pool create \
  --name "dpn-infrastructure-agents-<env>" \
  --organisation "https://dev.azure.com/<organisation>" \
  --project "<project-name>"
```

**Agent VM Requirements:**

The self-hosted agent VM (provisioned during infrastructure deployment) must have:

- OpenTofu
- Azure CLI v2.50+
- Git (latest version)
- kubectl
- Helm


### Repository Structure for Infrastructure

Use a clear and discoverable common structure for pipeline organisation.
The example below is a common pattern based on the current repository layout.

Reference repository:

- https://github.com/energy-dsi/dpn-infra-deployment

```
INFRA-REPO/
├──infrastructure-deployment/
│   └── azure/
├── .azuredevops/
│   └── pipelines/
│       ├── azure-pipeline-bootstrap*.yml
│       ├── azure-pipelines-*.yml
│       └── azure-pipeline-delete-services*.yml
├── infrastructure/
│   └── opentofu/
│       ├── environments/
│       └── modules/
└── scripts/
```

This is a common reference structure. Your exact environment folder names and YAML file names can vary, but the same pattern should be followed.

### Variable Group and Key Vault Usage

Infrastructure pipelines require an Azure DevOps **Library Variable Group** per environment.

Common current naming pattern:

- `dpn-<env>-vars-001`
- `dpn-<env>-vars-002`

Create the variable group in **Azure DevOps Library** and populate it with the environment-specific deployment values referenced by the pipeline YAML.


### Deployment Connectivity Flow

Use the following execution model for pipeline-based deployments:

```text
Self-Hosted Agent
  ↓ (checks out code)
Azure DevOps Repo
  ↓ (runs pipeline YAML)
Azure DevOps Pipeline
  ↓ (uses service connection)
Service Principal
  ↓ (Azure Resource Manager API)
Azure Subscription Resources
```

Operational summary:

- Agent pulls OpenTofu code from ADO repo.
- Pipeline executes `tofu init/plan/apply`.
- Service connection provides service principal identity to OpenTofu provider.
- OpenTofu provisions resources in Azure with RBAC-scoped permissions.



## 12. Validation Checklist Before Apply

Review the following checks to confirm the configuration is ready for execution.

- Confirm no placeholder tokens remain in tfvars (for example `<env>`, `<azure-region>`, `{instance}`).
- Confirm resource names are globally valid where required (especially storage account naming rules).
- Confirm `location` matches the intended Azure region for all deployed services.
- Run `tofu validate` and fix any errors before the first `tofu plan`.

---

Continue with [03-installation-process.md](03-installation-process.md)