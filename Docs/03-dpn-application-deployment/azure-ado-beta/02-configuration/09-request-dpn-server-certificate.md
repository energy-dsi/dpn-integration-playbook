# Requesting a DPN Server Certificate

---

## Table of Contents

- [Overview](#overview)
- [How this differs from the Federator Gateway's certificate](#how-this-differs-from-the-federator-gateways-certificate)
- [Step1: Create a key pair](#step1-create-a-key-pair)
- [Step2: Create a CSR](#step2-create-a-csr)
- [Step3: Request the signed server certificate](#step3-request-the-signed-server-certificate)
- [Certificate properties](#certificate-properties)
- [Renewal](#renewal)
- [Review Notes](#review-notes)

---

## Overview

A **server certificate** is a long-TTL (60 day) certificate issued by the DSM Management Node for a participant's own edge/server-facing endpoints — for example, a Cloudflare-fronted server. It is issued and downloaded in a single call and is **not** renewed automatically.

> **This is not the Federator Gateway's mTLS certificate.** The gRPC Federator Gateway's producer/consumer certificate is obtained and continuously renewed automatically by the [Certificate Manager](04-configure-dpn-certificate-manager.md) against a different Management Node endpoint (`/api/v1/certificate/csr/sign`) and requires no manual action. The server certificate described on this page is a **separate, manually-requested** certificate for a participant's own edge infrastructure — the Management Node's own API documentation is explicit that it **must not be used by DPN Federator server or client containers**.

All endpoints below are under `/api/v1/certificate` on the DSM Management Node and require a bearer token with the appropriate authority (see each step).

> **Prefer the DSM web app for day-to-day use.** The steps below call the Management Node API directly — useful for automation/scripting, or for understanding what's happening under the hood. Most participants will instead use the DSM web app's own **Certificate Management** screen (Your Organisation → DPN → Certificate Management), where this certificate is labelled **"Edge"** rather than "server." See the [DSM Certificate Management UI Guide](../../../05-dpn-user-interfaces/10-dsm-certificate-management-ui-operations.md).

> **Bootstrap certificates are a different, Federator-side concept.** The Certificate Manager's *automatic* Federator certificate renewal (linked above) marks a participant's very first Federator certificate as a "bootstrap certificate" (a custom OID in its SAN, per `dpn-federator-certificate-manager`'s `docs/certificate-lifecycle.md`) so it gets replaced on the very next renewal cycle rather than running its full validity. That mechanism is unrelated to the server certificate on this page — a server certificate is never auto-renewed and never carries a bootstrap marker; it must always be requested fresh via [Step3](#step3-request-the-signed-server-certificate) before it expires.

## How this differs from the Federator Gateway's certificate

| | Federator Gateway certificate | Server certificate (this page) |
|---|---|---|
| Requested via | Certificate Manager's automatic renewal job (`/api/v1/certificate/csr/sign`) | Manual, single call (`/api/v1/certificate/server-certificate`) |
| TTL | 24 hours by default — renewed continuously, well before expiry | 60 days |
| Renewal | Automatic | **Manual** — you must request a new one before it expires |
| JWKS rotation | Yes, on every renewal | **Never** |
| Delivery | Persisted to Vault directly by the Certificate Manager | Returned to the caller as a ZIP download (`certificate.pem` + `ca-chain.pem`) |
| Intended use | The gRPC Federator Gateway's own producer/consumer mTLS endpoints | The participant's own edge/server endpoints (e.g. a Cloudflare-fronted server) — never the Federator Gateway itself |

Both certificate types are ultimately signed by the same underlying Certificate Authority — HashiCorp Vault's PKI secrets engine on the Management Node side — just against different signing roles (different TTL and SAN policy).

## Step1: Create a key pair

```
GET /api/v1/certificate/keyPair
```

Requires authority `ROLE_management-node:create_keys`.

Returns a fresh RSA 2048-bit key pair:

| Field | Description |
|---|---|
| `publicKeyPem` | The public key, PEM-encoded |
| `privateKeyPem` | The private key, PEM-encoded — handle this as a secret; the Management Node does not retain a copy |
| `algorithm` | `RSA` |
| `createdAt` | Generation timestamp |

## Step2: Create a CSR

```
POST /api/v1/certificate/csr/create
```

Requires authority `ROLE_management-node:create_keys`.

| Field | Description | Required |
|---|---|---|
| `publicKeyPem` / `privateKeyPem` | The key pair from [Step1](#step1-create-a-key-pair) | Yes |
| `commonName` | The certificate's CN — typically the server's fully-qualified hostname | Yes |
| `organization` | Subject `O` | No |
| `organizationalUnit` | Subject `OU` | No |
| `country` | Subject `C` | No |
| `dnsSans` | Additional DNS Subject Alternative Names to cover (e.g. alternate hostnames) | No |

Returns a CSR PEM.

> **Reusing an existing CSR:** if you already generated a CSR for this organisation's client/bootstrap certificate, the same CSR PEM may be reused directly in [Step3](#step3-request-the-signed-server-certificate) instead of repeating Steps 1–2 — the server-certificate request has the identical shape as the bootstrap (client) certificate request.

## Step3: Request the signed server certificate

```
POST /api/v1/certificate/server-certificate
```

Requires authority `ROLE_management-node:request_bootstrap_certificate` (the same authority used for the client/bootstrap certificate — there is no dedicated server-certificate authority).

| Field | Description |
|---|---|
| `organisationId` | The requesting organisation's ID |
| `csr` | The CSR PEM from [Step2](#step2-create-a-csr) |

The response is a `200 OK` with `Content-Type: application/zip` (`Content-Disposition: attachment; filename="server_certificate.zip"`), containing:

- `certificate.pem` — the signed server certificate
- `ca-chain.pem` — the issuing CA chain

This is a **single generate-and-download call** — there is no separate "sign" step to invoke afterward, and no polling required.

## Certificate properties

| Property | Value |
|---|---|
| Key algorithm | RSA 2048 (from the CSR generated in [Step1](#step1-create-a-key-pair)/[Step2](#step2-create-a-csr)) |
| Validity (TTL) | 60 days |
| Signing authority | HashiCorp Vault's PKI secrets engine on the Management Node, against a dedicated server-certificate signing role (separate from the Federator Gateway's signing role) |
| JWKS rotation | Never triggered by this certificate |
| Renewal | Manual — none of this flow is automatic |

## Renewal

There is no automatic renewal for a server certificate. Track its 60-day expiry yourself and repeat [Step1](#step1-create-a-key-pair) through [Step3](#step3-request-the-signed-server-certificate) (or just Step3, reusing an existing CSR) to obtain a replacement before the current one expires.

---

## Review Notes

Draft — grounded directly in `dsm-management-node`'s `CertificateController`/`CertificateSigningProviderImpl` as of this playbook branch; pending a review pass.
