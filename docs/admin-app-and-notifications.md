# USSE Hub administration app

Open `/admin-app`. The installation prompt and Home Screen instructions are available before sign-in. Sign in with the same active USSE administrator account used for the existing workspaces. The app contains links to enterprise administration, leads, directory reporting, advertising accounts and referrals; it does not grant new roles.

## Install and connect

- Android/desktop: select **Install USSE Hub**, or use the browser's Install app menu.
- iPhone/iPad: open in Safari, Share → Add to Home Screen; open the installed icon. Device notifications require iOS/iPadOS 16.4 or later.
- In **App & alerts**, choose **Enable on this device** and allow the browser/device permission. Connect each desired device separately. Select **Send test alert** and inspect its delivery result; provider acceptance is not proof a person saw the alert.
- Preferences control device delivery by category and can pause all alerts. The activity inbox still records supported activity. Remove a device to revoke its subscription. Device subscriptions are tied to a valid login session and are removed when that session is revoked/deleted. Losing the active administrator role disables delivery.
- Devices, browser privacy settings, offline periods, battery saving and Focus/Do Not Disturb can delay or suppress visible notifications. No browser can guarantee instant delivery in every device state.

## Events recorded from launch

New enquiries; changes to lead stage, assignee, priority or follow-up date; member registrations and role/account changes; listing submissions/status/details; advertising orders, payment proof/status, subscriptions and advertisement status; partner agreements/signatures; and referral/commission status. Derived subscription duplicates and routine page views are excluded. Existing records are not backfilled. Marking an enquiry as spam dismisses its activity and cancels outstanding device alerts.

Every active administrator receives a separate private activity record and independent read state. Device categories affect push delivery, not the activity history. Realtime refresh uses a per-user Postgres Changes subscription protected by RLS, with a 30-second foreground fallback. A lead notification opens its specific lead; other notifications open the relevant workspace.

## Delivery and privacy

`private.admin_push_subscriptions` contains browser capability URLs and encryption keys and has no client table grants. Only the authenticated, active-admin RPC registers/removes a user's own devices. The worker accepts only its dedicated dispatch credential. Recognized browser push service hosts are checked before each request; redirects are refused. No customer names, contact details, messages, passwords or tokens appear in push payloads. No login token is kept in the service worker.

New events queue delivery transactionally. `pg_net` requests the `admin-push` Edge worker after commit. A minute cron retries transient failures with bounded exponential backoff and claim tokens (up to eight attempts); 404/410 subscriptions are disabled. Closing an app does not stop standards-based Web Push on supported devices. Clicking a notification still requires a valid administrator login to read business data.

The root service worker is network-only for admin pages and does not intercept public pages or API requests. The only cache entry is a static offline notice. Working with customer records requires an internet connection.

## Deployment and checks

Frontend files deploy via GitHub main and the existing automatic deployment. No Railway configuration is changed. `scripts/deploy-admin-app.mjs` accepts the management credential as JSON on stdin: `--validate` runs schema/workflow checks in a rolled-back transaction; `--apply` installs the additive migration, creates only the new app VAPID/dispatch credentials, and deploys the worker; `--functions` redeploys the worker without rotating keys. Existing email/SMTP credentials and alert recipients are not changed. Keep VAPID keys stable or existing device subscriptions must be reconnected.

`npm run test:app` covers encrypted request generation, provider/network failures, endpoint and click-URL safety, worker behavior, and manifest/icon wiring. `tests/admin-app.sql` exercises live-schema admin/RLS isolation, enquiry fan-out, retry fencing, spam suppression, preferences, device tests/removal and login-session revocation in a rolled-back transaction. No synthetic customers, notification subscriptions or test messages are committed by validation. A real device must opt in before actual OS notification delivery can be checked on it.
