# Lead inbox and urgent alerts

The lead inbox is at `/lead-inbox` and in every administrator workspace rail. Only active administrators can read or change it. Existing `consultations` records are retained and form the lead register; notes and email delivery records live in private tables.

## What is captured

Public forms on the home, consultancy, Aloe Jamaica and PISTOL pages save an enquiry before offering a WhatsApp continuation. Email enquiries are sent through the platform, so the visitor does not need an email app. Direct USSE email, WhatsApp and phone links open a short capture form. The directory's contact-business modal and published business-page enquiry form use the same intake. A receipt reference is shown only after the database confirms the save.

Records include name, company, phone/email, customer request, subsidiary, service, chosen channel, page path, a limited set of campaign/referrer fields, receipt time and agreement to follow up. Raw IP addresses, full referring URLs, authentication query strings and arbitrary tracking parameters are not stored. The server hashes the request IP with a secret for a bounded rate limit. The original enquiry is separate from internal notes and activity.

The system does not automatically import private inbox conversations or WhatsApp replies. Use **Record a lead** for emails, phone calls or messages received elsewhere. Opening a contact button records an attempted handoff; administrators explicitly set Contacted after actually reaching the customer. External booking/live-chat providers remain their own services.

## Following up

Search/filter by stage, channel, subsidiary or overdue follow-up. Assign an active administrator, set a Jamaica-time follow-up date, add private notes and update New / Contacted / Qualified / Won / Lost / Spam. Download the filtered register as CSV or an individual contact as a vCard. CSV exports escape spreadsheet formulas. Removing a listing retains its associated lead with an empty listing reference.

## Recipient settings and alert safety

Set one to ten email addresses under **Alert recipients**. The existing configured notification email is adopted on first startup. Each address receives a separate branded urgent message with customer details, request, reply/call/WhatsApp actions, a private inbox link and a vCard attachment. Recipient choices come from administrator settings, never public form fields. **Send a test to saved recipients** sends a synthetic diagnostic and creates no lead.

Lead capture and alert queueing are atomic. Each lead/recipient pair is unique. Workers claim at most eight alerts with row locks and claim tokens; stale workers cannot complete a newer claim. The provider receives a stable idempotency key. Temporary failures retry with exponential backoff, capped at six hours, for up to eight attempts. A protected cron dispatcher runs each minute and normal submissions start dispatch immediately. Missing sending credentials leave the lead and its alerts safely queued. Paused alerts and removed recipients are not dispatched.

“Accepted” means accepted by the email provider, not confirmed inbox delivery or reading. Bounces and replies are not currently ingested. The provider's idempotency window is finite; manual retries long after an interrupted, unconfirmed send may result in a duplicate email. Already accepted recipients are never resent by the retry action. Configure a working Resend sending key and verified `noreply@ussehub.com` sender in the existing Edge Function secrets.

## Deployment and checks

All source is committed to GitHub `main`; Railway deploys the website automatically. Do not edit Railway directly. The migration is also listed in the standard transactional migration deployer.

`npm run deploy:leads` is a dry run. Supply a Supabase management credential as JSON on stdin to `node scripts/deploy-leads.mjs --validate` for a rolled-back live-schema trial, then `--apply` for the checked source. It installs the migration, configures a restricted dispatch secret in Edge Function secrets and Vault, deploys the validated intake and protected worker, and initializes notification recipients. SMTP credentials are not read or modified. Authentication SMTP and Edge Function email secrets are separate: a working signup email does not validate `RESEND_API_KEY` for lead alerts. Replace an invalid sending key in Supabase Edge Function secrets, then use the saved-recipient test button. An optional `qaRecipient` sends a synthetic test to an owned mailbox without changing real recipients or creating a fake customer record. Keep credentials in process memory and never commit them.

Tests cover role boundaries, no direct public table inserts, honeypot/consent/CORS checks, request idempotency, rate limits, separate recipient deliveries, claim fencing, retries, lead retention, stage/note audit behavior, contact links, HTML escaping, vCards and CSV formula safety. Validate the public forms and admin inbox using isolated preview fixtures, then verify a branded test email in the owned mailbox. Do not send real customer messages merely to test.

## October 31 update: direct enquiries and visible email diagnostics

At the owner's request, Cloudflare Turnstile has been removed from all public enquiry forms and the shared intake handler. No Cloudflare script, token or secret is needed for lead submission. Server-side field validation, consent, the hidden spam field, bounded payloads, allowed-origin checks, request idempotency, contact/IP rate limits and database permissions remain enforced. Moving DNS to Cloudflare is independent of both form capture and the Resend sending key.

The alert test shows progress and individual saved-recipient results beside its button, including partial success, invalid-key responses and connection failures. Successful tests are provider acceptance only. A broken provider credential cannot be repaired by retrying or changing recipient addresses. Replace `RESEND_API_KEY` in Edge Function secrets with a valid Resend key authorized to send from the verified `ussehub.com` domain. No secrets are collected in the public website or stored in Git. The new deployment helper `node scripts/deploy-lead-functions.mjs --apply` deploys only the three function sources with a management credential on stdin; it leaves schema, recipients and credentials intact.

## Spam protection

The lead inbox now includes **Spam protection**. Active administrators can block a lead's email address and phone number or apply a 24-hour block to the connection used for a recent website enquiry. Contact blocks remain until manually removed; connection blocks expire automatically. The list contains separate contact identifiers, so remove all applicable entries to fully unblock a contact. Blocks are reversible and audited; raw IP addresses are not stored or shown. Connection blocks can affect other people sharing that connection and should be reserved for repeated abuse. Existing manually entered leads support contact blocks; connection metadata is available only for website enquiries captured after this migration.

Every public form uses the same database guard. It serializes submissions by request, connection and normalized contact identifiers. There are at most three requests per connection per minute, two per contact identifier per minute, six per contact identifier per hour, plus the existing limit of twelve successful submissions per connection per hour. Email and phone quotas are independent, so rotating one field does not evade the other. These are fixed time windows, so a boundary may permit a brief burst. Network signals come from the platform gateway's forwarded headers; contact blocks and quotas remain independent of that signal.

A repeated enquiry with the same normalized contact identifiers, message, branch and listing within fifteen minutes returns the existing receipt and creates no additional lead or email alert. Idempotent retries of the same request remain free of additional quota usage. Other blocked and rate-limited submissions never create a lead or queue an alert. Rejection counters and duplicate counters are aggregate hourly records, with no contact details or IP addresses. Invalid-origin, honeypot and malformed-request rejections occur before the database guard and are not included in these counters.

Marking an existing lead as Spam or applying either block cancels outstanding alerts. Adding new recipients or retrying alerts does not reactivate spam notifications. Previously accepted or already in-flight emails cannot be recalled. Unblocking allows future enquiries; it does not automatically reclassify old spam records or resend their cancelled alerts.

The intake also rejects missing/foreign origins, non-JSON requests, malformed payloads, hidden-field spam and oversized bodies before expensive processing. The request body is read with a 20 KB streaming cap. No CAPTCHA or third-party anti-spam service is used. These layers reduce automated abuse and block known contacts; they do not claim to identify every human or distributed spam campaign. DNS changes and the pending Resend credential repair remain independent.

The additive migration is `20261101020019_lead_spam_protection.sql`. Validate it against the live schema with `node scripts/deploy-lead-spam.mjs --validate`; apply the checked source with `--apply`, passing the management credential as JSON on stdin. The script verifies database grants and RLS, records a checksum, and compares security advisories. Deploy the updated intake handler before installing the new database guard so that blocked outcomes are interpreted correctly, then publish the administrator UI through GitHub.
