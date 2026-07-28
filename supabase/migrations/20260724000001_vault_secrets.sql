-- Intentionally contains no credential values.
--
-- Supabase Vault secrets are deployment configuration, not schema. Configure
-- RESEND_API_KEY and RESEND_FROM_EMAIL through deploy_new_migrations.mjs (which
-- reads local environment variables and sends them as query parameters), or
-- through the Supabase dashboard. Never commit live secret values here.

DO $$
BEGIN
  RAISE NOTICE 'Vault credentials are configured separately from migrations.';
END
$$;
