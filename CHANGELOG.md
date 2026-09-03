# Changelog

**Repository:** `DPN Integration Playbook`  
**Description:** `Tracks all notable changes, version history, and roadmap towards DPN deployment component .`

<!-- SPDX-License-Identifier: OGL-UK-3.0 -->

--- 

All notable changes to this repository will be documented in this file.

This project follows **Semantic Versioning (SemVer)** ([semver.org](https://semver.org/)), using the format:

`[MAJOR].[MINOR].[PATCH]`
- **MAJOR** (`X.0.0`) – Addition of new component/services in the architecture.
- **MINOR** (`0.X.0`) – Backward-compatible new features, enhancements, or functionality changes.
- **PATCH** (`0.0.X`) – Backward-compatible minor corrections, typos , image rectification.
- **Pre-release versions** – Use suffixes such as `-alpha`, `-beta`, `-rc.1` (e.g., `2.1.0-beta.1`).
- **Build metadata** – If needed, use `+build` (e.g., `2.1.0+20250314`).

---
## Release 2.0.0 - 2026-08-31

**See [Release 2.0.0 Configuration Changes](Docs/06-release-notes/release-2.0.0-configuration-changes.md) for a full component-by-component Added/Removed/Modified breakdown of every configuration item.**

### Added

- Two new components in the architecture: the DPN Authentication Service (Keycloak) and the DPN REST Federator Gateway — see the linked configuration-changes page for the major-version rationale.
- DPN Authentication Service (Keycloak) configuration guide — deployment, TLS, and secrets for the platform's shared Identity Provider.
- DPN REST Federator Gateway configuration guide — a synchronous, HTTPS-based alternative to the gRPC Federator, and how to integrate the `rest-federator-client` library as a consumer.
- Vault AppRole authentication guidance — the recommended alternative to the Vault root token for the Certificate Manager and Federator Gateway, alongside the automated provisioning pipeline.
- AWS File Scan Service RUNBOOK — Amazon GuardDuty Malware Protection for S3, consumed via an SNS → SQS event flow, as the AWS equivalent of the existing Azure Defender for Storage integration.
- DPN Portal user guide — the Keycloak-SSO-gated landing page for the observability UIs, including its current group-based tile visibility model.

### Changed

- Certificate Manager and Federator Gateway configuration guides updated to reflect certificate material being built in memory directly from Vault — the shared Azure SMB file share these components previously used has been removed.
- Federator Gateway configuration guide updated: Kafka brokers now run `SASL_SSL`/`OAUTHBEARER` against Keycloak by default.
- Kafka UI, Kafka Health UI, OpenSearch Dashboard, and Jaeger Dashboard user guides updated to reflect HTTPS access gated by Keycloak SSO via the DPN Portal, superseding direct HTTP/basic-auth access as the standard path.
- Introduction updated to describe the Federator Platform's two federation styles (gRPC and REST) and the platform's Keycloak-based Identity Provider.

### Fixed

- None

### Dependencies

- None

---

## Release 1.0.0 - 2026-07-31

### Added

- DPN application deployment process.
- DPN prerequisites for Azure cloud specific installation using ADO
- DPN configuration parameter for azure cloud specific installation
- DPN installation procedure on Azure cloud
- DPN uninstall and decommission procedure on Azure
- DPN prerequisite for AWS cloud specific installation manually
- DPN configuration parameter for AWS cloud specific installation
- DPN installation procedure on AWS cloud
- DPN architecture components
- DPN User Intefaces Guidance

### Fixed

- None


### Changed

- None

### Dependencies

- None
---

## Maintained by the National Energy System Operator (NESO)

Copyright 2026 NESO.  This work is licensed under the Open Government Licence 3.0 (OGL). This work has been developed by NESO using content licensed by the Department for Business and Trade (UK) under the OGL.   
 
Licensed under the Open Government Licence v3.0.

For full licensing terms, [OGL_LICENSE.md](./OGL_LICENSE.md)
