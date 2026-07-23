-- Vault secrets for Resend email dispatch and AJM admin notification
-- Safe to re-run: uses INSERT ... ON CONFLICT DO UPDATE

-- Resend API key (used by dispatch_ad_notification_outbox())
INSERT INTO vault.secrets (name, secret)
VALUES ('RESEND_API_KEY', 're_dWqU6Bb8_Gutp6Q8xjdXqJQJFLV93sos7')
ON CONFLICT (name) DO UPDATE SET secret = EXCLUDED.secret;

-- Sender address used in the From: header
INSERT INTO vault.secrets (name, secret)
VALUES ('RESEND_FROM_EMAIL', 'AJM Advertising <noreply@ussehub.com>')
ON CONFLICT (name) DO UPDATE SET secret = EXCLUDED.secret;
