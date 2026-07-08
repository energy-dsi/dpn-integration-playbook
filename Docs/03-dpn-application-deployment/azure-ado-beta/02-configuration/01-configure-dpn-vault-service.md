# DPN Deployment Configuration Guide

---

## Table of Contents

- [Overview](#overview)
  - [Continuous Integration (CI)](#continuous-integration-ci)
  - [Continuous Deployment (CD)](#continuous-deployment-cd)

- [Global / Generic Configuration](#global--generic-configuration)
  - [DSI DSM Endpoint Configuration](#dsi-dsm-endpoint-configuration)
  - [Azure DevOps Configuration](#azure-devops-configuration)
    - [Node Pool Set Up](#node-pool-set-up)
      - [Existing Configuration](#existing-configuration)
      - [Updated Configuration](#updated-configuration)
    - [Azure Environment Configuration](#azure-environment-configuration)
  - [Secrets Configuration (Global)](#secrets-configuration-global)
    - [Certificate Handling Note](#certificate-handling-note)
  - [Network and Ports Configuration](#network-and-ports-configuration)

- [Component-Specific Configuration](#component-specific-configuration)

  - [DPN Security Services](#dpn-security-services)
    - [HashiCorp Vault Configuration](#hashicorp-vault-configuration)
      - [HTTPS Configuration](#https-configuration)
      - [Vault Helm Configuration For Certificate Manager](#vault-helm-configuration-for-certificate-manager)
      - [Vault Secrets Configuration](#vault-secrets-configuration)

    - [Shared Storage Service Configuration](#shared-storage-service-configuration)
      - [Certificate P12 Storage as File Share](#certificate-p12-storage-as-file-share)
      - [Helm Configuration](#helm-configuration)
      - [Secrets Configuration](#secrets-configuration)

    - [Federator Certificate Manager Configuration](#federator-certificate-manager-configuration)
      - [Helm Configuration](#helm-configuration-1)
      - [Secrets Configuration](#secrets-configuration-1)
        - [Key Vault Secrets Configuration](#key-vault-secrets-configuration)
        - [Kubernetes Secrets Configuration](#kubernetes-secrets-configuration)

  - [DPN Data Pipelines Configuration](#dpn-data-pipelines-configuration)
    - [Introduction and Purpose](#introduction-and-purpose)
    - [Helm Configuration](#helm-configuration-data-pipelines)
      - [Data Pipeline Blueprints](#data-pipeline-blueprints)
      - [Producer Setup](#producer-setup)
      - [Consumer Setup](#consumer-setup)
      - [Producer Parameters — dl, eq, eqbd, and ssh (adaptor & schema_mapper)](#producer-parameters--dl-eq-eqbd-and-ssh-adaptor--schema_mapper)
      - [Consumer Parameters — extractor & schema_mapper](#consumer-parameters--extractor--schema_mapper)
    - [Secrets Configuration](#secrets-configuration-data-pipelines)

  - [DPN Data Store Configuration](#dpn-data-store-configuration)
    - [Storage Blob / S3 Configuration](#storage-blob--s3-configuration)
    - [DPN Streaming Service (Kafka)](#dpn-streaming-service-kafka)

  - [DPN Federator Gateway Configuration](#dpn-federator-gateway-configuration)
    - [Helm Configuration](#helm-configuration-federator-gateway)
    - [Secrets Configuration](#secrets-configuration-federator-gateway)

- [Review Notes](#review-notes)

---

# Hashicorp Vault Configuration
DSI package provides an automated method of setting up DPN Hashicorp Vault along with required csr, certificate and keys files. The automation uses ADO pipeline at this moment and requires devOPS agent capabilities to run OpenSSL as per prerequisites. 

If Organisation is not able to follow automated method then manual process is also provided below with detailed command line instructions. 

# Automated Vault Configuration

<< Anik to update>>

## DPN Security Services

The DPN Security Services consist of the Federator Certificate Manager, HashiCorp Vault, Azure Key Vault, and an SMB-based File Share.

---

### HashiCorp Vault Configuration

HashiCorp Vault is used in the DPN to store the Intermediate CA, CA Chain, and KeyPair files. These files are used to create keystore and truststore files for the Federator Gateway Server and Client to communicate with the DSI Management Node and authentication services.

DSI provides a community edition of the HashiCorp Vault container as part of the DSI package. Organisations may choose to substitute an enterprise edition based on their licensing strategy.

#### HTTPS Configuration

Vault should be set up to use a https based connection internally within DPN application. In this document , stpes are provided to create a Root CA (once) for using a self signed certificate in Vault. However, if organisation already have a CA authority, no need to create a ROOT CA. They should generate a CSR for the Vault URL and jump to step 8 onwards.

organisations would require a server machine that has access to the kubernetes cluster private environment/machine from where Certificate manager and federator containers are accessible and has openssl installed as mentioned in the prerequisite section 01.The output of the following steps would generate truststore ,vault crt and key files which would be mounted on the Certificate manager and federator containers to invoke vault service over https.

##### Step 1: 
Create a vault directory and ca subdirectory in a suitable location on the server machine

```bash
mkdir -p vault
cd vault
mkdir -p ca
cd ca
```

##### Step 2: 
Generate Root CA private key

```bash
openssl genrsa -out rootCA.key 4096
```
##### Step 3: 
Generate Root CA certificate

```bash
openssl req -x509 -new -nodes -key rootCA.key \
  -sha256 -days 3650 \
  -out rootCA.crt \
  -subj "<Your Subject>"
```
After the above steps are completed, the following files will be available in the ca folder.

vault/ca/rootCA.key
vault/ca/rootCA.crt

##### Step 4: 
Switch to Vault directory and create another subdirectory certs. Create a Vault private key in the certs folder.

```bash
cd ..
mkdir -p certs
openssl genrsa -out certs/vault.key 4096
```
##### Step 5: 
Create a config file as vault-openssl.cnf to use for certificate signining request. The SAN should include the internal Kubernetes DNS URL or any defined url by the organisation to access the Vault.

**certs/vault-openssl.cnf**
```text
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
C  = <Your Country>
O  = <Your Org>
CN = <Your CN>

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = vault.<namespace>.svc.cluster.local
DNS.2 = <vault.xyz.com>
DNS.3 = <Other SANs>
```

##### Step 6: 
Create a CSR (Certificate Signing Request) for Vault.

```bash
openssl req -new \
  -key certs/vault.key \
  -out certs/vault.csr \
  -config certs/vault-openssl.cnf
```

##### Step 7: 
Go to vault folder again and run the following command to sign the csr using the root CA created before.

```bash
openssl x509 -req \
  -in certs/vault.csr \
  -CA ca/rootCA.crt \
  -CAkey ca/rootCA.key \
  -CAcreateserial \
  -out certs/vault.crt \
  -days 825 \
  -sha256 \
  -extensions req_ext \
  -extfile certs/vault-openssl.cnf
```
At the end of this step the following files will be ready in the respective folders.

certs/vault.crt → signed by Root CA
<br>certs/vault.key → private key
<br>ca/rootCA.crt → CA trust anchor

##### Step 8: 
Verify the vault.hcl file located in the federator-certificate-manager repository has the above tls configuration for tls_cert_file , tls_key_file and path

```text
Root-Repository/
└── docker/
    └── vault-https/
        └── config/
            ├── vault.hcl
```

**vault.hcl**
```text
  listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_disable   = 0
  tls_cert_file = "/vault/certs/vault.crt"
  tls_key_file  = "/vault/certs/vault.key"
  }

api_addr     = "https://localhost:8200"
cluster_addr = "https://localhost:8201"
ui           = true

storage "file" {
path = "/vault/file"
}
```

##### Step 9: 

Verify the docker-compose.yaml located in the federator-certificate-manager repository has the certificate files from the following location on the Vault container.

```text
Root-Repository/
└── docker/
    └── vault-https/
        ├── docker-compose.yaml
```

Check the docker compose file for the certificate mount path

```yaml
- ./certs:/vault/certs:ro
```

##### Step 11:

Prepare truststore for trusting the Vault HTTPS certificate. **Create a Java truststore using keytool** (PKCS12 format) from the vault directory created above 

```bash
keytool -import -trustcacerts -noprompt -alias ca -file ca/rootCA.crt -keystore truststore.jks -storetype PKCS12
```

This trust store needs to be set up in Federator Gateway and Certificate Manager trustore.jks file in the secret configuration defined in the subsequent step below.
 

#### Vault Helm Configuration For Certificate Manager

The `dpn-federator-certificate-manager` repository includes a Helm chart values file for customising the HashiCorp Vault deployment. The values files are located as follows:

```text
Root-Repository
  └── charts
        └── vault-https
              ├── values.yaml             <- Reference file; do not edit directly
              └── values-<env>-dpn01.yaml <- Environment-specific overrides
```

> **Note:** Replicate `values.yaml` for each environment or DPN deployment (e.g. `values-dev-dpn01.yaml`, `values-sit-dpn02.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section.

DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

| Parameter                       | Purpose                                   | Example Value                                   |
|---------------------------------|-------------------------------------------|-------------------------------------------------|
| image.repository                | Complete URL of the image registry        | `<DSI public image repository>/hashicorp/vault` |
| image.tag                       | Image version tag                         | `1.16`                                          |
| namespace                       | Name of the Kubernetes namespace          | `ns-dpn-01`                                     |
| replicaCount                    | Number of replicas for the container      | `3`                                             |
| vault.storagePath               | Path inside the persistent storage volume | `/vault/file`                                   |
| seal.azureKeyVault.tenantId     | Unseal Key KeyVault's Tenant Id           | `xxxxx-yyyy`                                    |
| seal.azureKeyVault.clientId     | Unseal Key KeyVault's Client Id           | `xxxxx-yyyy`                                    |                                                 |
| seal.azureKeyVault.keyVaultName | Unseal Key KeyVault's Name                | `kv-dpn-dev-uks-xx`                             |
| seal.azureKeyVault.keyName      | Unseal Key KeyVault's Key name            | `vault-unseal-key`                              |
| keyvault.tenantId               | TLS Cert KeyVault's Tenant Id             | `xxxxx-yyyy`                                    |
| keyvault.clientID               | TLS Cert KeyVault's Client Id             | `xxxxx-yyyy`                                    |
| keyvault.name                   | TLS Cert KeyVault's Name                  | `kv-dpn-dev-uks-xx`                             |

#### Vault Secrets Configuration

The `dpn-federator-certificate-manager` repository includes Helm chart secret and `SecretProviderClass` templates for retrieving and bundling secrets from Azure Key Vault (AKV). The relevant files are located as follows:

```text
Root-Repository
  └── charts
        └── vault-https
              └── templates
                    ├── secret.yaml
                    └── secretproviderclass.yaml
```

HashiCorp Vault must be configured to serve over HTTPS with a minimum of TLS 1.2. The following AKV secrets must be created under `<keyvault.name>` to provide the TLS certificate material:

| Secret           | Purpose                                                                                |
|------------------|----------------------------------------------------------------------------------------|
| `VAULT-TLS-CERT` | AKV secret containing the TLS certificate **vault.crt** file  |
| `VAULT-TLS-KEY`  | AKV secret containing the TLS key **vault.key** |

---

### Shared Storage Service Configuration

The keystore and truststore P12 certificate files used by the Federator Gateway Server and Client are stored in a common SMB-based file share (Azure File Share). This file share is mounted by both the Federator Certificate Manager and the Federator Gateway components, as all three require access to the same certificate material when communicating with the DSI DSM Management Node and authentication endpoints.

#### Certificate P12 Storage as File Share

The Federator Certificate Manager, Federator Gateway Server, and Federator Gateway Client all require the certificate P12 files and their passwords to be accessible from a common mount point (e.g. `/tls`) on the file share.These files are dynamically created when certificate manager renews or fetch certificate from DSI.These files are mounted in read only mode for the federator.

```text
/file-share-mount-path
└── tls
    ├── keystore.p12
    ├── truststore.p12
    ├── keystore.password
    └── truststore.password
```

#### Helm Configuration

The `dpn-federator-certificate-manager` repository includes a Helm chart values file and a PV/PVC manifest for customising the File Share deployment. The values files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              ├── values.yaml             <- Reference file; do not edit directly
              ├── values-<env>-dpn01.yaml <- Environment-specific overrides
              └── templates
                    └── pv-pvc.yaml
```

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| fileShare.shareName | SMB File Share name used for common DPN certificate storage | `fs<env>dpn01<region>01` |
| fileShare.secretName | Kubernetes secret name containing the File Share credentials | `azure-fileshare-secret` |
| fileShare.namespace | Kubernetes namespace for the File Share | `ns-dpn-01` |
| fileShare.pvName | Persistent Volume name for the File Share | `pv-dpn-certs-fileshare` |
| fileShare.pvcName | Persistent Volume Claim name for the File Share | `pvc-dpn-certs-fileshare` |
| fileShare.size | Capacity to allocate for the File Share | `1Gi` |

#### Secrets Configuration

The `dpn-federator-certificate-manager` repository includes Helm chart secret and `SecretProviderClass` templates for retrieving and bundling secrets from Azure Key Vault. The relevant files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              └── templates
                    ├── secret.yaml
                    └── secretproviderclass.yaml
```

| Secret Parameter | Purpose | Example Value             |
|------------------|---------|---------------------------|
| `azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-NAME` | Storage account name for the Azure File Share used for common DPN certificate storage | `st<env>>dpn01<region>01` |
| `azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-KEY` | Storage account key for the Azure File Share used for common DPN certificate storage | `XXXXXXXXXXXXXXXX`        |

---

### Federator Certificate Manager Configuration

The Federator Certificate Manager is a non-interactive Spring Boot service that automates X.509 certificate lifecycle management for Federator components within the **DSI DPN**. It operates as a headless daemon — no HTTP endpoints are exposed — running two scheduled jobs that handle certificate renewal and filesystem synchronisation.

The service integrates with **HashiCorp Vault** (KV v2) for secret persistence, an external **Management Node** API for PKI operations (intermediate CA retrieval and CSR signing), and an **OAuth2 Identity Provider** for token-based authentication. All external HTTP communication is secured via mutual TLS (mTLS).

#### Helm Configuration

The `dpn-federator-certificate-manager` repository includes a Helm chart values file for customising the deployment. The values files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              ├── values.yaml             <- Reference file; do not edit directly
              └── values-<env>-dpn01.yaml <- Environment-specific overrides
```

> **Note:** Replicate `values.yaml` for each environment or DPN deployment (e.g. `values-dev-dpn01.yaml`, `values-test-dpn01.yaml`). The organisation must specify the values file name in the pipeline configuration as described in the [Azure Environment Configuration](#azure-environment-configuration) section.

DSI proposes only selective changes to the values file but provides the provision to customise other parameters if required.

| Parameter              | Purpose                                                                      | Example Value                                                                                     |
|------------------------|------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| image.repository       | Complete URL of the image in the registry                                    | `<DSI public image repository>/dpn-federator-certificate-manager`                                 |
| namespace              | Name of the Kubernetes namespace                                             | `ns-dpn-01`                                                                                       |
| managementNode.baseUrl | Complete URL of the DSI DSM Management Node                                  | `https://management.dsm01.dsiXXX.neso.energy`                                                     |
| oauth2.clientId        | Client ID received from DSM to establish the DPN connection                  | `9c4f2e8a-6b21-4d73-9a5e-1f6b8c7a4d92`                                                            |
| oauth2.tokenUri        | IDP token URL received from DSM to establish the DPN connection              | `https://auth-mtls.dsm01.dsiXXX.neso.energy/realms/management-node/protocol/openid-connect/token` |
| replicaCount           | Number of replicas for the container                                         | `1`                                                                                               |
| vault.uri              | Complete URL of the DPN Vault                                                | `https://vault.<namespace>.svc.cluster.local:8200`                                                |
| vault.truststorePath   | Absolute Path of the folder under which vault truststore.jks will be mounted | `/vault`                                                                                           |
| existingSecret.name    | Secret bundle name for the Federator Certificate Manager secrets             | `certificate-manager-secrets`                                                                     |
| fileShare.shareName    | File Share name for common DPN certificate storage                           | `fs<env>dpn01<region>01`                                                                          |
| fileShare.secretName   | Secret bundle name for the Azure File Share credentials                      | `azure-fileshare-secret`                                                                          |
| fileShare.namespace    | Kubernetes namespace for the File Share                                      | `ns-dpn-01`                                                                                       |

#### Secrets Configuration

The `dpn-federator-certificate-manager` repository includes Helm chart secret and `SecretProviderClass` templates for retrieving and bundling secrets from Azure Key Vault. 

The relevant files are located as follows:

```text
Root-Repository
  └── charts
        └── certificate-manager
              └── templates
                    ├── secret.yaml
                    └── secretproviderclass.yaml
```

##### Key Vault Secrets Configuration

| Secret Parameter                                        | Purpose                                                                               | Example Value            |
|---------------------------------------------------------|---------------------------------------------------------------------------------------|--------------------------|
| `certificate-manager-secrets.VAULT-TOKEN`               | Root token of the DPN HashiCorp Vault                                                 | `hsv.xxxxxxxxxxx`        |
| `certificate-manager-secrets.OAUTH2-CLIENT-SECRET`      | OAuth2 client secret for the DPN's client ID received from DSI DSM                    | `xxxxxxxxxxx`            |
| `certificate-manager-secrets.VAULT-TRUSTSTORE-PASSWORD` | DPN Hashicorp Vault Truststore password                                               | `changeit`               |
| `azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-NAME`     | Storage account name for the Azure File Share used for common DPN certificate storage | `fs<env>dpn01<region>01` |
| `azure-fileshare-secret.AZURE-STORAGE-ACCOUNT-KEY`      | Storage account key for the Azure File Share used for common DPN certificate storage  | `xxxxxxxxxxx`            |

##### Kubernetes Secrets Configuration

Below Kubernetes secret must be created to load the Vault `truststore.jks` file created using steps [here](#https-configuration) under path `<vault.truststorePath>`.

| Secret Parameter       | Purpose                                                     | Example Value |
|------------------------|-------------------------------------------------------------|---------------|
| `VAULT-TRUSTSTORE-JKS` | Secret container for DPN Vault's Truststore.jks binary file | ` `           |

---

# Review Notes

| Review Date | Last Reviewed By | Status | Version |
|-------------|-----------------|--------|---------|
| 15-May-2026 | DSI Assurance | Draft | V0.1.0 |
