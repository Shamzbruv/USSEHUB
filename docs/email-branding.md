# USSE Hub email design

All platform-generated mail uses the shared purple, sea-blue and light-slate design in `supabase/functions/_shared/email.mjs`. Essential styling is inline, with table layouts, solid colour fallbacks, readable text, phone sizing, a hidden inbox preview and a contact footer. The wordmark renders without external images or fonts.

## Coverage

- All six Supabase account emails: signup confirmation, invitation, magic link, email change, password reset and reauthentication code.
- All seven Supabase security notification templates. Deployment preserves their existing enabled/disabled settings; styling does not subscribe users to additional notifications.
- Advertising order and payment updates, admin payment-review alerts, business webpage activation/renewal/cancellation and future notification-outbox events.
- Admin signup, listing and consultation notifications from both Edge Functions.

Public `mailto:` links open the visitor's own email application; they are not platform-sent emails. Auth keeps Supabase's original `{{ .ConfirmationURL }}` and `{{ .Token }}` variables. Business data is HTML-escaped and can never supply an action URL. Provider messages include plain-text alternatives where the application controls the payload.

## Source and release

1. Edit the shared layout or account wording in `scripts/email-templates.mjs`.
2. Run `npm run build:emails` and `npm test`. Generated templates are committed under `supabase/templates`.
3. Commit changes to GitHub `main`. Railway picks up the website deployment automatically; no direct Railway access is required.
4. For a new database design release, create a new migration with the Supabase CLI. Do not edit a migration after it has been applied. Deploy schema changes through the existing transactional migration process (`--skip-secrets` preserves configured provider credentials).
5. From that GitHub checkout, run `npm run deploy:emails -- --apply` with `SUPABASE_ACCESS_TOKEN` and optionally `SUPABASE_PROJECT_REF`. The default project is USSE Hub. This updates the hosted Auth templates and deploys the two email-producing Edge Functions with their pinned import map. It verifies all template contents and preserves Auth redirects, email confirmation requirements, notification flags and function JWT enforcement. It never reads or changes SMTP passwords or Edge Function secrets.

`npm run deploy:emails` without `--apply` is a dry run. The SQL outbox renderer adds HTML at dispatch, so existing pending rows inherit the design without changing their recipients, status, retry counts or message text. The migration does not dispatch pending mail. Both database render helpers are private, use a fixed search path and have no client execute permission.

To check a release, render desktop/mobile previews, request a confirmation and password-reset email only for an owned QA mailbox, verify the branded body and secure action links, sign out the temporary account, then remove its Auth/profile records. Do not trigger real client order events merely to test the design.
