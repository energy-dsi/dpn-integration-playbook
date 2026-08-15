# Azure Infrastructure Deployment Guide

This folder provides a common, implementation-agnostic guide to deploy DPN-style infrastructure on Azure using OpenTofu (with optional Bicep bootstrap).

The documents are intentionally written as reference patterns so that teams can adapt naming, environments, and module wiring to their own repository.

## Reading Order

1. [01-prerequisites.md](01-prerequisites.md)
	- Access, tools, and planning inputs you should confirm before deployment.
2. [02-configuration-parameters.md](02-configuration-parameters.md)
	- Example parameter structure and tfvars patterns.
3. [03-installation-process.md](03-installation-process.md)
	- End-to-end deployment sequence with validation steps.
4. [04-rollback-procedures.md](04-rollback-procedures.md)
	- Recovery actions for failed or partial deployments.
5. [05-uninstall-decommissioning.md](05-uninstall-decommissioning.md)
	- Safe teardown and decommissioning checklist.

## How to Use This Guide

- Treat all resource names as examples unless your project standard requires exact naming.
- Replace placeholder values (for example `<env>`, `<region>`, `<subscription-id>`) before executing commands.
- If your repository variable names differ, map the examples to your own `variables.tf`, `outputs.tf`, and pipeline conventions.
- Prefer full `tofu plan` / `tofu apply` workflows first; use targeted module operations only for controlled troubleshooting.