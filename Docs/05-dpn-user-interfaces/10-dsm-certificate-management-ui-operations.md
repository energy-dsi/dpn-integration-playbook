# DSM Certificate Management User Interface Guide

This section describes the certificate management screen in the DSM participant web app — the self-service alternative to calling the Management Node's certificate API directly (see [Requesting a DPN Server Certificate](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md#requesting-a-dpn-server-certificate) for the raw API flow).

---

## Table of Contents

- [Overview](#overview)
- [Accessing Certificate Management](#accessing-certificate-management)
- [The two certificate types shown](#the-two-certificate-types-shown)
- [Viewing an active certificate](#viewing-an-active-certificate)
- [Certificate history](#certificate-history)
- [Requesting a certificate (CSR upload)](#requesting-a-certificate-csr-upload)
- [What this UI does not do](#what-this-ui-does-not-do)
- [Review Notes](#review-notes)

---

## Overview

The DSM web app's **Certificate Management** screen lets a participant view their organisation's active certificates, browse certificate history, and request a new certificate by uploading a CSR — without calling any API directly. It covers both certificate types a participant deals with day to day:

- The **Federator** certificate — the gRPC Federator Gateway's own mTLS certificate (short-lived, auto-renewed once issued — see [Configure DPN Certificate Manager](../03-dpn-application-deployment/azure-ado-beta/02-configuration/04-configure-dpn-certificate-manager.md)).
- The **Edge** certificate — the UI's name for what the Management Node API calls the **server certificate**: a long-lived certificate for the participant's own edge/server infrastructure (e.g. a Cloudflare-fronted server), requested manually and never auto-renewed — see [Requesting a DPN Server Certificate](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md#requesting-a-dpn-server-certificate) for the underlying flow and certificate properties.

> **How this reaches the signing backend.** This screen does not call the Management Node's `/api/v1/certificate/*` API directly — it goes through the DSM web app's own organisation/participant backend, which is expected to forward the request internally. If you're troubleshooting a request that fails from this UI, [Requesting a DPN Server Certificate](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md#requesting-a-dpn-server-certificate) documents the underlying Management Node endpoints directly, which is useful for isolating whether an issue is in the UI's own backend or in the signing flow itself.

## Accessing Certificate Management

In the DSM web app, go to **Your Organisation** → **DPN** tab → **Certificate Management** sub-tab.

## The two certificate types shown

| | Federator certificate | Edge certificate |
|---|---|---|
| Corresponds to | The Management Node's automatic Federator signing flow | The Management Node's `/api/v1/certificate/server-certificate` ("server certificate") |
| Lifetime shown in the UI | Short-lived | Long-lived |
| Typical use | The gRPC Federator Gateway's producer/consumer mTLS endpoint | The participant's own edge/server endpoint — **not** the Federator Gateway itself |
| Auto-renewed? | Yes, once an initial certificate exists (see [bootstrap certificates](#requesting-a-certificate-csr-upload) below) | No — must be re-requested manually before it expires |

## Viewing an active certificate

For each certificate type, the screen shows (when one is active): status, expiry date, serial number, issuer, and subject DN. A **Download Active .crt** action downloads the active certificate for that type.

## Certificate history

Both certificate types have their own history view, listing previously issued certificates for the organisation.

## Requesting a certificate (CSR upload)

Under either the Federator or Edge section, upload a CSR to request a new certificate of that type. The result downloads as a ZIP (`bootstrap_bundle.zip` for the Federator flow, `edge_bundle.zip` for the Edge flow).

> **"Bootstrap certificate" terminology.** When no Federator certificate is currently active for the organisation, the UI's own copy describes the CSR you submit as issuing a **bootstrap certificate**. This matches the Certificate Manager's own bootstrap-certificate detection (a custom OID embedded in the certificate's SAN, checked on every renewal cycle — see `docs/certificate-lifecycle.md` in the `dpn-federator-certificate-manager` repository): an initial certificate is marked this way so the Certificate Manager renews it immediately on its next cycle rather than waiting out its normal validity window, and the replacement issued through that automatic renewal no longer carries the bootstrap marker. In short: the first Federator certificate you request here is a bootstrap certificate; everything after that is renewed automatically without further action in this UI.

You will need a CSR to upload — see [Requesting a DPN Server Certificate, Steps 1–2](../03-dpn-application-deployment/azure-ado-beta/02-configuration/01-configure-dpn-vault-service.md#step1-create-a-key-pair) for how to generate a key pair and CSR if you don't already have one from another tool.

## What this UI does not do

There is no certificate **revocation** action in this screen today. If a certificate needs to be revoked, that must be done through the Management Node's own `/api/v1/certificate/revoke` endpoint directly.

---

## Review Notes

Draft — grounded in `dsm-web-app`'s `apps/user` "Your Organisation" → DPN → Certificate Management screen as of this playbook branch; pending a review pass. The admin app's own "Certificates" tab is a placeholder (not yet implemented) and is not covered here.
