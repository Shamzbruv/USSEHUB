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

Tests cover role boundaries, no direct public table inserts, CAPTCHA/hostname/CORS checks, request idempotency, rate limits, separate recipient deliveries, claim fencing, retries, lead retention, stage/note audit behavior, contact links, HTML escaping, vCards and CSV formula safety. Validate the public forms and admin inbox using isolated preview fixtures, then verify a branded test email in the owned mailbox. Do not send real customer messages merely to test.
