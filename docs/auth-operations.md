# Account registration and recovery

Supabase Auth sends account emails through the project's configured Resend SMTP service. Frontend deployment alone does not repair SMTP credentials.

In Supabase Authentication settings, use the production site URL `https://ussehub.com` and allow these exact account callback URLs:

- `https://ussehub.com/ajm-advertising-hub`
- `https://ussehub.com/ajm-advertising-hub?auth=confirmed`
- `https://ussehub.com/ajm-advertising-hub?auth=recovery`
- `https://ussehub.com/ajm-advertising-hub.html` (older reset emails)

Keep email confirmation enabled. An SMTP error `535 Authentication credentials invalid` requires a valid provider credential. For Resend, the SMTP username is `resend`; the password is an active Resend API key authorized to send from the configured verified domain. The sender is `noreply@ussehub.com`. Enter provider secrets only into the SMTP settings or an approved secret mechanism. Never commit keys, and never reuse an API response's masked or hashed password as the real SMTP password.

The website uses eight-character passwords with uppercase and lowercase letters, a number and a symbol. `PASSWORD_RECOVERY` opens a real password-update form. Auth callbacks defer profile/database work until the auth lock is released. Failed or interrupted requests always restore the action button.

## Administrator onboarding

After applying `20261027160446_auth_registration_admin_reservations.sql`, a trusted operator can run:

```sh
DATABASE_URL='<trusted database connection>' node promote.mjs '<client email>'
```

The script reserves access in a private table. It does not invent a password, confirm the email, or activate a paid subscription. The reservation is claimed once, after Supabase verifies that exact Auth email. Signup metadata and editable profile email fields cannot grant a role. If the account is already verified, the script activates its administrator role immediately. Existing administrators retain their access.

A pending reservation is not an existing user account. If email delivery failed, the user must complete registration after SMTP is repaired.

## Verification

`npm test` covers auth actions, recovery, email failures, duplicate requests, reserved administrator provisioning, profile RLS, listing renewal, referrals, contrast and production routes. Database integration checks should use a transaction and roll back test records. Test email delivery through a mailbox controlled by the operator before telling customers registration is restored.
