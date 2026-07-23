-- AJM advertising commerce, fulfillment, notifications and analytics.
--
-- Design goals:
--   * package prices, durations, selected options and payment instructions are
--     snapshotted on each order and cannot be rewritten later;
--   * customers never write lifecycle fields directly;
--   * every privileged change is made by an authenticated SECURITY DEFINER RPC
--     and recorded in admin_audit_log;
--   * bank accounts and proof/creative objects stay private;
--   * public ad delivery and event tracking expose no payment information; and
--   * Resend credentials live in Supabase Vault, never in source control.

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- Payment destinations and configurable products
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.payment_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  label text NOT NULL,
  bank_name text,
  account_name text,
  account_number text,
  account_type text,
  branch_name text,
  routing_number text,
  swift_code text,
  currency text NOT NULL DEFAULT 'JMD',
  instructions text,
  is_active boolean NOT NULL DEFAULT true,
  is_default boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payment_accounts_code_check
    CHECK (code = lower(code) AND code ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  CONSTRAINT payment_accounts_currency_check
    CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT payment_accounts_metadata_check
    CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE UNIQUE INDEX IF NOT EXISTS payment_accounts_one_default_idx
ON public.payment_accounts (is_default)
WHERE is_default = true AND is_active = true;

ALTER TABLE public.ad_packages
ADD COLUMN IF NOT EXISTS product_type text,
ADD COLUMN IF NOT EXISTS placements text[] NOT NULL DEFAULT '{}'::text[],
ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'JMD',
ADD COLUMN IF NOT EXISTS description text,
ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS payment_account_id uuid,
ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ad_packages_payment_account_id_fkey'
      AND conrelid = 'public.ad_packages'::regclass
  ) THEN
    ALTER TABLE public.ad_packages
      ADD CONSTRAINT ad_packages_payment_account_id_fkey
      FOREIGN KEY (payment_account_id)
      REFERENCES public.payment_accounts(id)
      ON DELETE SET NULL;
  END IF;
END $$;

ALTER TABLE public.ad_packages
DROP CONSTRAINT IF EXISTS ad_packages_product_type_check;

ALTER TABLE public.ad_packages
ADD CONSTRAINT ad_packages_product_type_check
CHECK (product_type IS NULL OR product_type IN ('webpage', 'display_ad'));

ALTER TABLE public.ad_packages
DROP CONSTRAINT IF EXISTS ad_packages_currency_check;

ALTER TABLE public.ad_packages
ADD CONSTRAINT ad_packages_currency_check
CHECK (currency ~ '^[A-Z]{3}$');

ALTER TABLE public.ad_packages
DROP CONSTRAINT IF EXISTS ad_packages_price_nonnegative_check;

ALTER TABLE public.ad_packages
ADD CONSTRAINT ad_packages_price_nonnegative_check
CHECK (price >= 0);

ALTER TABLE public.ad_packages
DROP CONSTRAINT IF EXISTS ad_packages_duration_positive_check;

ALTER TABLE public.ad_packages
ADD CONSTRAINT ad_packages_duration_positive_check
CHECK (duration_days > 0);

UPDATE public.ad_packages
SET
  product_type = 'webpage',
  placements = ARRAY['directory-webpage']::text[],
  currency = 'JMD',
  description = CASE code
    WHEN 'ajm-webpage-silver' THEN 'Business essentials webpage with contact details, services, hours and up to three photos.'
    WHEN 'ajm-webpage-gold' THEN 'Lead-generation webpage with richer media, maps, reviews, offers and enquiry tools.'
    WHEN 'ajm-webpage-platinum' THEN 'Premier webpage with booking, virtual-tour, tracked-call and live-chat features.'
    ELSE description
  END,
  sort_order = CASE code
    WHEN 'ajm-webpage-silver' THEN 10
    WHEN 'ajm-webpage-gold' THEN 20
    WHEN 'ajm-webpage-platinum' THEN 30
    ELSE sort_order
  END
WHERE code IN (
  'ajm-webpage-silver',
  'ajm-webpage-gold',
  'ajm-webpage-platinum'
);

-- Normalize the three legacy advertising products already present in the live
-- database. Name-based matching is limited to rows which still have no code,
-- so a later administrator rename or custom product is never overwritten.
UPDATE public.ad_packages
SET
  code = CASE lower(name)
    WHEN 'basic package' THEN 'display-basic'
    WHEN 'advanced package' THEN 'display-advanced'
    WHEN 'banner ad' THEN 'display-banner'
  END,
  product_type = 'display_ad',
  placements = CASE lower(name)
    WHEN 'basic package' THEN ARRAY['directory-featured']::text[]
    WHEN 'advanced package' THEN ARRAY['directory-featured', 'hub-sidebar']::text[]
    WHEN 'banner ad' THEN ARRAY['homepage', 'hub-sidebar']::text[]
  END,
  currency = 'JMD',
  description = CASE lower(name)
    WHEN 'basic package' THEN 'Featured directory advertising for local discovery.'
    WHEN 'advanced package' THEN 'Featured directory and Advertising Hub sidebar placement with richer creative.'
    WHEN 'banner ad' THEN 'Premium homepage and Advertising Hub banner/sidebar exposure.'
  END,
  sort_order = CASE lower(name)
    WHEN 'basic package' THEN 100
    WHEN 'advanced package' THEN 110
    WHEN 'banner ad' THEN 120
  END,
  updated_at = now()
WHERE code IS NULL
  AND lower(name) IN ('basic package', 'advanced package', 'banner ad');

CREATE TABLE IF NOT EXISTS public.ad_package_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id uuid NOT NULL REFERENCES public.ad_packages(id) ON DELETE CASCADE,
  code text NOT NULL,
  name text NOT NULL,
  description text,
  price_delta numeric(12,2) NOT NULL DEFAULT 0,
  duration_days_delta integer NOT NULL DEFAULT 0,
  additional_placements text[] NOT NULL DEFAULT '{}'::text[],
  features jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ad_package_options_package_code_key UNIQUE (package_id, code),
  CONSTRAINT ad_package_options_code_check
    CHECK (code = lower(code) AND code ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  CONSTRAINT ad_package_options_price_check CHECK (price_delta >= 0),
  CONSTRAINT ad_package_options_duration_check CHECK (duration_days_delta >= 0),
  CONSTRAINT ad_package_options_features_check
    CHECK (jsonb_typeof(features) IN ('object', 'array'))
);

CREATE INDEX IF NOT EXISTS idx_ad_package_options_catalog
ON public.ad_package_options (package_id, is_active, sort_order, name);

-- ---------------------------------------------------------------------------
-- Orders and immutable commercial snapshots
-- ---------------------------------------------------------------------------

CREATE SEQUENCE IF NOT EXISTS public.ad_order_number_seq START WITH 1001;

CREATE TABLE IF NOT EXISTS public.ad_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number text NOT NULL UNIQUE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  listing_id uuid REFERENCES public.listings(id) ON DELETE SET NULL,
  package_id uuid NOT NULL REFERENCES public.ad_packages(id) ON DELETE RESTRICT,
  payment_account_id uuid REFERENCES public.payment_accounts(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending_payment',

  package_code_snapshot text NOT NULL,
  package_name_snapshot text NOT NULL,
  package_description_snapshot text,
  product_type_snapshot text NOT NULL,
  placements_snapshot text[] NOT NULL DEFAULT '{}'::text[],
  currency_snapshot text NOT NULL,
  base_price_snapshot numeric(12,2) NOT NULL,
  options_price_snapshot numeric(12,2) NOT NULL DEFAULT 0,
  total_price_snapshot numeric(12,2) NOT NULL,
  duration_days_snapshot integer NOT NULL,
  selected_options_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb,
  payment_account_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,

  customer_notes text,
  creative_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  creative_path text,
  payment_proof_path text,
  payment_reference text,
  rejection_reason text,
  admin_note text,

  payment_submitted_at timestamptz,
  approved_at timestamptz,
  approved_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  starts_at timestamptz,
  expires_at timestamptz,
  renewed_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT ad_orders_status_check CHECK (
    status IN (
      'pending_payment',
      'payment_submitted',
      'approved',
      'paused',
      'rejected',
      'cancelled',
      'expired'
    )
  ),
  CONSTRAINT ad_orders_product_type_check
    CHECK (product_type_snapshot IN ('webpage', 'display_ad')),
  CONSTRAINT ad_orders_currency_check
    CHECK (currency_snapshot ~ '^[A-Z]{3}$'),
  CONSTRAINT ad_orders_amounts_check CHECK (
    base_price_snapshot >= 0
    AND options_price_snapshot >= 0
    AND total_price_snapshot = base_price_snapshot + options_price_snapshot
  ),
  CONSTRAINT ad_orders_duration_check CHECK (duration_days_snapshot > 0),
  CONSTRAINT ad_orders_options_snapshot_check
    CHECK (jsonb_typeof(selected_options_snapshot) = 'array'),
  CONSTRAINT ad_orders_payment_snapshot_check
    CHECK (jsonb_typeof(payment_account_snapshot) = 'object'),
  CONSTRAINT ad_orders_creative_snapshot_check
    CHECK (jsonb_typeof(creative_snapshot) = 'object'),
  CONSTRAINT ad_orders_activation_dates_check CHECK (
    expires_at IS NULL OR starts_at IS NULL OR expires_at > starts_at
  )
);

CREATE INDEX IF NOT EXISTS idx_ad_orders_user_created
ON public.ad_orders (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_orders_status_created
ON public.ad_orders (status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_orders_package_created
ON public.ad_orders (package_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_orders_listing
ON public.ad_orders (listing_id, created_at DESC)
WHERE listing_id IS NOT NULL;

ALTER TABLE public.ad_subscriptions
ADD COLUMN IF NOT EXISTS ad_order_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ad_subscriptions_ad_order_id_fkey'
      AND conrelid = 'public.ad_subscriptions'::regclass
  ) THEN
    ALTER TABLE public.ad_subscriptions
      ADD CONSTRAINT ad_subscriptions_ad_order_id_fkey
      FOREIGN KEY (ad_order_id)
      REFERENCES public.ad_orders(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS ad_subscriptions_ad_order_id_key
ON public.ad_subscriptions (ad_order_id)
WHERE ad_order_id IS NOT NULL;

ALTER TABLE public.ad_subscriptions
DROP CONSTRAINT IF EXISTS ad_subscriptions_status_check;

ALTER TABLE public.ad_subscriptions
ADD CONSTRAINT ad_subscriptions_status_check
CHECK (status IN ('pending', 'active', 'paused', 'expired', 'cancelled'));

-- ---------------------------------------------------------------------------
-- Activated advertisements and privacy-preserving events
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.advertisements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.ad_orders(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  listing_id uuid REFERENCES public.listings(id) ON DELETE SET NULL,
  package_id uuid NOT NULL REFERENCES public.ad_packages(id) ON DELETE RESTRICT,
  placement text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  headline text,
  body_text text,
  cta_label text,
  cta_url text,
  creative_path text,
  creative_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  starts_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT advertisements_order_placement_key UNIQUE (order_id, placement),
  CONSTRAINT advertisements_status_check
    CHECK (status IN ('active', 'paused', 'cancelled', 'expired')),
  CONSTRAINT advertisements_dates_check CHECK (expires_at > starts_at),
  CONSTRAINT advertisements_metadata_check
    CHECK (jsonb_typeof(creative_metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_advertisements_delivery
ON public.advertisements (placement, status, starts_at, expires_at);

CREATE INDEX IF NOT EXISTS idx_advertisements_owner
ON public.advertisements (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.ad_events (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  advertisement_id uuid NOT NULL REFERENCES public.advertisements(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.ad_orders(id) ON DELETE CASCADE,
  placement text NOT NULL,
  event_type text NOT NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  session_hash text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  occurred_on date NOT NULL DEFAULT (timezone('UTC', now()))::date,
  CONSTRAINT ad_events_type_check CHECK (
    event_type IN (
      'impression',
      'view',
      'click',
      'lead',
      'call',
      'chat',
      'booking'
    )
  ),
  CONSTRAINT ad_events_session_hash_check
    CHECK (session_hash IS NULL OR session_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT ad_events_metadata_check CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_ad_events_ad_time
ON public.ad_events (advertisement_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_events_order_time
ON public.ad_events (order_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_ad_events_type_time
ON public.ad_events (event_type, occurred_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ad_events_daily_session_dedupe_idx
ON public.ad_events (advertisement_id, event_type, session_hash, occurred_on)
WHERE session_hash IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Resend outbox. API credentials are looked up from Vault only at dispatch.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.notification_outbox (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  order_id uuid REFERENCES public.ad_orders(id) ON DELETE CASCADE,
  recipient_email text NOT NULL,
  subject text NOT NULL,
  text_body text NOT NULL,
  template_key text NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  attempts integer NOT NULL DEFAULT 0,
  net_request_id bigint,
  last_error text,
  queued_at timestamptz NOT NULL DEFAULT now(),
  dispatched_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_outbox_status_check
    CHECK (status IN ('pending', 'queued', 'sent', 'failed')),
  CONSTRAINT notification_outbox_attempts_check CHECK (attempts >= 0)
);

CREATE INDEX IF NOT EXISTS idx_notification_outbox_pending
ON public.notification_outbox (status, queued_at)
WHERE status IN ('pending', 'failed');

-- ---------------------------------------------------------------------------
-- Shared guards, audit helpers and triggers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.require_admin(p_uid uuid DEFAULT auth.uid())
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_uid IS NULL OR NOT private.is_admin(p_uid) THEN
    RAISE EXCEPTION 'Administrator access is required.'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.request_is_service_role()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT coalesce(
    coalesce(
      nullif(current_setting('request.jwt.claims', true), ''),
      '{}'
    )::jsonb->>'role' = 'service_role',
    false
  );
$$;

CREATE OR REPLACE FUNCTION private.set_advertising_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.redact_payment_account(p_state jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_state IS NULL THEN NULL
    ELSE p_state || jsonb_build_object(
      'account_number',
      CASE
        WHEN nullif(p_state->>'account_number', '') IS NULL THEN NULL
        ELSE '••••' || right(p_state->>'account_number', 4)
      END
    )
  END;
$$;

CREATE OR REPLACE FUNCTION private.audit_advertising_change(
  p_actor uuid,
  p_entity_type text,
  p_entity_id text,
  p_action text,
  p_before jsonb DEFAULT NULL,
  p_after jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.admin_audit_log (
    actor_user_id,
    entity_type,
    entity_id,
    action,
    before_state,
    after_state
  ) VALUES (
    p_actor,
    left(p_entity_type, 100),
    p_entity_id,
    left(p_action, 150),
    p_before,
    p_after
  );
END;
$$;

CREATE OR REPLACE FUNCTION private.guard_ad_order_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF ROW(
    NEW.order_number,
    NEW.user_id,
    NEW.listing_id,
    NEW.package_id,
    NEW.payment_account_id,
    NEW.package_code_snapshot,
    NEW.package_name_snapshot,
    NEW.package_description_snapshot,
    NEW.product_type_snapshot,
    NEW.placements_snapshot,
    NEW.currency_snapshot,
    NEW.base_price_snapshot,
    NEW.options_price_snapshot,
    NEW.total_price_snapshot,
    NEW.duration_days_snapshot,
    NEW.selected_options_snapshot,
    NEW.payment_account_snapshot
  ) IS DISTINCT FROM ROW(
    OLD.order_number,
    OLD.user_id,
    OLD.listing_id,
    OLD.package_id,
    OLD.payment_account_id,
    OLD.package_code_snapshot,
    OLD.package_name_snapshot,
    OLD.package_description_snapshot,
    OLD.product_type_snapshot,
    OLD.placements_snapshot,
    OLD.currency_snapshot,
    OLD.base_price_snapshot,
    OLD.options_price_snapshot,
    OLD.total_price_snapshot,
    OLD.duration_days_snapshot,
    OLD.selected_options_snapshot,
    OLD.payment_account_snapshot
  ) THEN
    RAISE EXCEPTION 'Order pricing, duration, package and payment snapshots are immutable.';
  END IF;

  IF NEW.status <> OLD.status AND NOT (
    (OLD.status = 'pending_payment' AND NEW.status IN ('payment_submitted', 'approved', 'rejected', 'cancelled'))
    OR (OLD.status = 'payment_submitted' AND NEW.status IN ('approved', 'rejected', 'cancelled'))
    OR (OLD.status = 'approved' AND NEW.status IN ('paused', 'cancelled', 'expired'))
    OR (OLD.status = 'paused' AND NEW.status IN ('approved', 'cancelled', 'expired'))
  ) THEN
    RAISE EXCEPTION 'Invalid advertising order transition: % to %.', OLD.status, NEW.status;
  END IF;

  IF OLD.status IN ('approved', 'paused', 'cancelled', 'expired')
     AND NEW.creative_snapshot IS DISTINCT FROM OLD.creative_snapshot THEN
    RAISE EXCEPTION 'Approved advertising creative cannot be replaced without a new review.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payment_accounts_updated_at ON public.payment_accounts;
CREATE TRIGGER trg_payment_accounts_updated_at
BEFORE UPDATE ON public.payment_accounts
FOR EACH ROW EXECUTE FUNCTION private.set_advertising_updated_at();

DROP TRIGGER IF EXISTS trg_ad_packages_commerce_updated_at ON public.ad_packages;
CREATE TRIGGER trg_ad_packages_commerce_updated_at
BEFORE UPDATE ON public.ad_packages
FOR EACH ROW EXECUTE FUNCTION private.set_advertising_updated_at();

DROP TRIGGER IF EXISTS trg_ad_package_options_updated_at ON public.ad_package_options;
CREATE TRIGGER trg_ad_package_options_updated_at
BEFORE UPDATE ON public.ad_package_options
FOR EACH ROW EXECUTE FUNCTION private.set_advertising_updated_at();

DROP TRIGGER IF EXISTS trg_guard_ad_order_update ON public.ad_orders;
CREATE TRIGGER trg_guard_ad_order_update
BEFORE UPDATE ON public.ad_orders
FOR EACH ROW EXECUTE FUNCTION private.guard_ad_order_update();

DROP TRIGGER IF EXISTS trg_advertisements_updated_at ON public.advertisements;
CREATE TRIGGER trg_advertisements_updated_at
BEFORE UPDATE ON public.advertisements
FOR EACH ROW EXECUTE FUNCTION private.set_advertising_updated_at();

-- ---------------------------------------------------------------------------
-- RLS and least-privilege table grants
-- ---------------------------------------------------------------------------

ALTER TABLE public.payment_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_package_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advertisements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ad_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_outbox ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage payment accounts" ON public.payment_accounts;
CREATE POLICY "Admins manage payment accounts"
ON public.payment_accounts FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Active package options are readable" ON public.ad_package_options;
CREATE POLICY "Active package options are readable"
ON public.ad_package_options FOR SELECT TO anon, authenticated
USING (
  is_active = true
  AND EXISTS (
    SELECT 1
    FROM public.ad_packages p
    WHERE p.id = package_id AND p.is_active = true
  )
  OR private.is_admin((SELECT auth.uid()))
);

DROP POLICY IF EXISTS "Admins manage package options" ON public.ad_package_options;
CREATE POLICY "Admins manage package options"
ON public.ad_package_options FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Customers read own ad orders" ON public.ad_orders;
CREATE POLICY "Customers read own ad orders"
ON public.ad_orders FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Public reads currently active advertisements" ON public.advertisements;
CREATE POLICY "Public reads currently active advertisements"
ON public.advertisements FOR SELECT TO anon, authenticated
USING (
  (
    status = 'active'
    AND starts_at <= now()
    AND expires_at > now()
  )
  OR user_id = (SELECT auth.uid())
  OR private.is_admin((SELECT auth.uid()))
);

DROP POLICY IF EXISTS "Admins manage advertisements" ON public.advertisements;
CREATE POLICY "Admins manage advertisements"
ON public.advertisements FOR ALL TO authenticated
USING (private.is_admin((SELECT auth.uid())))
WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Advertisers and admins read ad events" ON public.ad_events;
CREATE POLICY "Advertisers and admins read ad events"
ON public.ad_events FOR SELECT TO authenticated
USING (
  private.is_admin((SELECT auth.uid()))
  OR EXISTS (
    SELECT 1
    FROM public.advertisements a
    WHERE a.id = advertisement_id
      AND a.user_id = (SELECT auth.uid())
  )
);

DROP POLICY IF EXISTS "Admins read notification outbox" ON public.notification_outbox;
CREATE POLICY "Admins read notification outbox"
ON public.notification_outbox FOR SELECT TO authenticated
USING (private.is_admin((SELECT auth.uid())));

REVOKE ALL ON public.payment_accounts FROM anon, authenticated;
REVOKE ALL ON public.ad_package_options FROM anon, authenticated;
REVOKE ALL ON public.ad_orders FROM anon, authenticated;
REVOKE ALL ON public.advertisements FROM anon, authenticated;
REVOKE ALL ON public.ad_events FROM anon, authenticated;
REVOKE ALL ON public.notification_outbox FROM anon, authenticated;

GRANT SELECT ON public.payment_accounts TO authenticated;
GRANT SELECT ON public.ad_package_options TO anon, authenticated;
GRANT SELECT ON public.ad_orders TO authenticated;
GRANT SELECT ON public.advertisements TO anon, authenticated;
GRANT SELECT ON public.ad_events TO authenticated;
GRANT SELECT ON public.notification_outbox TO authenticated;

-- ---------------------------------------------------------------------------
-- Private storage buckets and ownership policies
-- Object names must be: <user UUID>/<order UUID>/<filename>.
-- ---------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  (
    'ad-payment-proofs',
    'ad-payment-proofs',
    false,
    10485760,
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']::text[]
  ),
  (
    'ad-creatives',
    'ad-creatives',
    true,
    20971520,
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'video/mp4', 'video/webm']::text[]
  )
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

CREATE OR REPLACE FUNCTION private.can_access_ad_order_object(
  p_object_name text,
  p_uid uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    private.is_admin(p_uid)
    OR EXISTS (
      SELECT 1
      FROM public.ad_orders o
      WHERE o.user_id = p_uid
        AND split_part(p_object_name, '/', 1) = p_uid::text
        AND split_part(p_object_name, '/', 2) = o.id::text
        AND o.status IN ('pending_payment', 'payment_submitted', 'approved', 'paused')
    );
$$;

DROP POLICY IF EXISTS "Order owners read private ad assets" ON storage.objects;
CREATE POLICY "Order owners read private ad assets"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id IN ('ad-payment-proofs', 'ad-creatives')
  AND private.can_access_ad_order_object(name, (SELECT auth.uid()))
);

DROP POLICY IF EXISTS "Order owners upload private ad assets" ON storage.objects;
CREATE POLICY "Order owners upload private ad assets"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id IN ('ad-payment-proofs', 'ad-creatives')
  AND private.can_access_ad_order_object(name, (SELECT auth.uid()))
);

DROP POLICY IF EXISTS "Order owners replace private ad assets" ON storage.objects;
CREATE POLICY "Order owners replace private ad assets"
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id IN ('ad-payment-proofs', 'ad-creatives')
  AND private.can_access_ad_order_object(name, (SELECT auth.uid()))
)
WITH CHECK (
  bucket_id IN ('ad-payment-proofs', 'ad-creatives')
  AND private.can_access_ad_order_object(name, (SELECT auth.uid()))
);

DROP POLICY IF EXISTS "Order owners remove private ad assets" ON storage.objects;
CREATE POLICY "Order owners remove private ad assets"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id IN ('ad-payment-proofs', 'ad-creatives')
  AND private.can_access_ad_order_object(name, (SELECT auth.uid()))
);

-- ---------------------------------------------------------------------------
-- Notification queue helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.queue_order_notifications(
  p_order_id uuid,
  p_event text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_order public.ad_orders%ROWTYPE;
  v_customer_email text;
  v_subject text;
  v_body text;
BEGIN
  SELECT * INTO v_order
  FROM public.ad_orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT p.email INTO v_customer_email
  FROM public.profiles p
  WHERE p.id = v_order.user_id;

  v_subject := CASE p_event
    WHEN 'created' THEN 'AJM advertising order received'
    WHEN 'payment_submitted' THEN 'AJM payment proof received'
    WHEN 'approved' THEN 'Your AJM advertisement is active'
    WHEN 'rejected' THEN 'Update on your AJM advertising payment'
    WHEN 'cancelled' THEN 'Your AJM advertising order was cancelled'
    WHEN 'renewed' THEN 'Your AJM advertisement was renewed'
    WHEN 'paused' THEN 'Your AJM advertisement was paused'
    WHEN 'resumed' THEN 'Your AJM advertisement was resumed'
    WHEN 'expired' THEN 'Your AJM advertisement has expired'
    ELSE 'AJM advertising order update'
  END;

  v_body := format(
    'Order %s for %s is now %s.%s',
    v_order.order_number,
    v_order.package_name_snapshot,
    replace(v_order.status, '_', ' '),
    CASE
      WHEN p_event = 'rejected' AND nullif(v_order.rejection_reason, '') IS NOT NULL
        THEN E'\n\nReason: ' || v_order.rejection_reason
      WHEN p_event IN ('approved', 'renewed', 'resumed') AND v_order.expires_at IS NOT NULL
        THEN E'\n\nAccess is scheduled through ' || to_char(v_order.expires_at, 'FMMonth DD, YYYY') || '.'
      ELSE ''
    END
  );

  IF nullif(v_customer_email, '') IS NOT NULL THEN
    INSERT INTO public.notification_outbox (
      order_id,
      recipient_email,
      subject,
      text_body,
      template_key
    ) VALUES (
      v_order.id,
      lower(v_customer_email),
      v_subject,
      v_body,
      'ad_order_' || p_event
    );
  END IF;

  IF p_event = 'payment_submitted' THEN
    INSERT INTO public.notification_outbox (
      order_id,
      recipient_email,
      subject,
      text_body,
      template_key
    )
    SELECT
      v_order.id,
      lower(p.email),
      'AJM payment proof requires review',
      format(
        'Payment proof was submitted for order %s (%s). Sign in to the AJM admin panel to confirm or reject it.',
        v_order.order_number,
        v_order.package_name_snapshot
      ),
      'ad_order_admin_payment_review'
    FROM public.profiles p
    WHERE p.role = 'admin'
      AND nullif(p.email, '') IS NOT NULL;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatch_ad_notification_outbox(
  p_limit integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_api_key text;
  v_from text;
  v_row public.notification_outbox%ROWTYPE;
  v_request_id bigint;
  v_queued integer := 0;
  v_failed integer := 0;
BEGIN
  IF NOT private.request_is_service_role() THEN
    PERFORM private.require_admin(auth.uid());
  END IF;

  SELECT decrypted_secret INTO v_api_key
  FROM vault.decrypted_secrets
  WHERE name IN ('RESEND_API_KEY', 'resend_api_key')
  ORDER BY CASE name WHEN 'RESEND_API_KEY' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret INTO v_from
  FROM vault.decrypted_secrets
  WHERE name IN ('RESEND_FROM_EMAIL', 'resend_from_email')
  ORDER BY CASE name WHEN 'RESEND_FROM_EMAIL' THEN 0 ELSE 1 END
  LIMIT 1;

  IF nullif(v_api_key, '') IS NULL OR nullif(v_from, '') IS NULL THEN
    RAISE EXCEPTION 'Vault secrets RESEND_API_KEY and RESEND_FROM_EMAIL must be configured before dispatch.';
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.notification_outbox
    WHERE status IN ('pending', 'failed')
      AND attempts < 5
    ORDER BY queued_at
    FOR UPDATE SKIP LOCKED
    LIMIT greatest(1, least(coalesce(p_limit, 25), 100))
  LOOP
    BEGIN
      SELECT net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || v_api_key,
          'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
          'from', v_from,
          'to', jsonb_build_array(v_row.recipient_email),
          'subject', v_row.subject,
          'text', v_row.text_body
        ),
        timeout_milliseconds := 10000
      ) INTO v_request_id;

      UPDATE public.notification_outbox
      SET
        status = 'queued',
        attempts = attempts + 1,
        net_request_id = v_request_id,
        dispatched_at = now(),
        last_error = NULL
      WHERE id = v_row.id;
      v_queued := v_queued + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.notification_outbox
      SET
        status = 'failed',
        attempts = attempts + 1,
        last_error = left(SQLERRM, 1000)
      WHERE id = v_row.id;
      v_failed := v_failed + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object('queued', v_queued, 'failed', v_failed);
END;
$$;

-- ---------------------------------------------------------------------------
-- Public catalog and customer order RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_ad_catalog()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'packages',
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'code', p.code,
          'name', p.name,
          'description', p.description,
          'product_type', p.product_type,
          'price', p.price,
          'currency', p.currency,
          'duration_days', p.duration_days,
          'placements', p.placements,
          'features', p.features,
          'webpage_tier', p.webpage_tier,
          'sort_order', p.sort_order,
          'is_orderable', (
            p.price > 0
            AND EXISTS (
              SELECT 1
              FROM public.payment_accounts pa
              WHERE pa.is_active = true
                AND pa.currency = p.currency
                AND (pa.id = p.payment_account_id OR (p.payment_account_id IS NULL AND pa.is_default = true))
            )
          ),
          'options', coalesce(
            (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'id', o.id,
                  'code', o.code,
                  'name', o.name,
                  'description', o.description,
                  'price_delta', o.price_delta,
                  'duration_days_delta', o.duration_days_delta,
                  'additional_placements', o.additional_placements,
                  'features', o.features,
                  'sort_order', o.sort_order
                ) ORDER BY o.sort_order, o.name
              )
              FROM public.ad_package_options o
              WHERE o.package_id = p.id AND o.is_active = true
            ),
            '[]'::jsonb
          )
        ) ORDER BY p.sort_order, p.name
      ),
      '[]'::jsonb
    )
  )
  FROM public.ad_packages p
  WHERE p.is_active = true
    AND p.code IS NOT NULL
    AND p.product_type IN ('webpage', 'display_ad');
$$;

CREATE OR REPLACE FUNCTION public.create_ad_order(
  p_package_id uuid,
  p_listing_id uuid DEFAULT NULL,
  p_option_ids uuid[] DEFAULT '{}'::uuid[],
  p_customer_notes text DEFAULT NULL,
  p_creative jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_package public.ad_packages%ROWTYPE;
  v_account public.payment_accounts%ROWTYPE;
  v_order public.ad_orders%ROWTYPE;
  v_option_ids uuid[];
  v_option_count integer;
  v_options_price numeric(12,2);
  v_duration_delta integer;
  v_options_snapshot jsonb;
  v_placements text[];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication is required.' USING ERRCODE = '42501';
  END IF;

  IF p_creative IS NULL OR jsonb_typeof(p_creative) <> 'object'
     OR octet_length(p_creative::text) > 20000 THEN
    RAISE EXCEPTION 'Creative details must be a JSON object no larger than 20 KB.';
  END IF;

  SELECT * INTO v_package
  FROM public.ad_packages
  WHERE id = p_package_id
    AND is_active = true
    AND code IS NOT NULL
    AND product_type IN ('webpage', 'display_ad')
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'The selected advertising package is unavailable.';
  END IF;

  IF v_package.price <= 0 THEN
    RAISE EXCEPTION 'This package is not yet priced. Contact AJM for assistance.';
  END IF;

  IF p_listing_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.listings l
    WHERE l.id = p_listing_id AND l.owner_user_id = v_uid
  ) THEN
    RAISE EXCEPTION 'The selected listing is unavailable or does not belong to you.';
  END IF;

  IF v_package.product_type = 'webpage' AND p_listing_id IS NULL THEN
    RAISE EXCEPTION 'A business listing is required for a webpage package.';
  END IF;

  SELECT * INTO v_account
  FROM public.payment_accounts pa
  WHERE pa.is_active = true
    AND pa.currency = v_package.currency
    AND (
      pa.id = v_package.payment_account_id
      OR (v_package.payment_account_id IS NULL AND pa.is_default = true)
    )
  ORDER BY (pa.id = v_package.payment_account_id) DESC, pa.sort_order, pa.created_at
  LIMIT 1
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active bank-transfer destination is configured for this package.';
  END IF;

  SELECT coalesce(array_agg(DISTINCT option_id), '{}'::uuid[])
  INTO v_option_ids
  FROM unnest(coalesce(p_option_ids, '{}'::uuid[])) AS option_id;

  SELECT
    count(*)::integer,
    coalesce(sum(o.price_delta), 0)::numeric(12,2),
    coalesce(sum(o.duration_days_delta), 0)::integer,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'code', o.code,
          'name', o.name,
          'description', o.description,
          'price_delta', o.price_delta,
          'duration_days_delta', o.duration_days_delta,
          'additional_placements', o.additional_placements,
          'features', o.features
        ) ORDER BY o.sort_order, o.name
      ),
      '[]'::jsonb
    )
  INTO v_option_count, v_options_price, v_duration_delta, v_options_snapshot
  FROM public.ad_package_options o
  WHERE o.id = ANY(v_option_ids)
    AND o.package_id = v_package.id
    AND o.is_active = true;

  IF v_option_count <> coalesce(array_length(v_option_ids, 1), 0) THEN
    RAISE EXCEPTION 'One or more selected package options are invalid or inactive.';
  END IF;

  SELECT coalesce(array_agg(DISTINCT placement ORDER BY placement), '{}'::text[])
  INTO v_placements
  FROM (
    SELECT unnest(coalesce(v_package.placements, '{}'::text[])) AS placement
    UNION ALL
    SELECT unnest(o.additional_placements)
    FROM public.ad_package_options o
    WHERE o.id = ANY(v_option_ids)
  ) placements
  WHERE nullif(trim(placement), '') IS NOT NULL;

  IF v_package.product_type = 'display_ad' AND coalesce(array_length(v_placements, 1), 0) = 0 THEN
    RAISE EXCEPTION 'This display package has no advertising placement configured.';
  END IF;

  INSERT INTO public.ad_orders (
    order_number,
    user_id,
    listing_id,
    package_id,
    payment_account_id,
    package_code_snapshot,
    package_name_snapshot,
    package_description_snapshot,
    product_type_snapshot,
    placements_snapshot,
    currency_snapshot,
    base_price_snapshot,
    options_price_snapshot,
    total_price_snapshot,
    duration_days_snapshot,
    selected_options_snapshot,
    payment_account_snapshot,
    customer_notes,
    creative_snapshot
  ) VALUES (
    format(
      'AJM-%s-%s',
      to_char(clock_timestamp(), 'YYYYMMDD'),
      lpad(nextval('public.ad_order_number_seq')::text, 6, '0')
    ),
    v_uid,
    p_listing_id,
    v_package.id,
    v_account.id,
    v_package.code,
    v_package.name,
    v_package.description,
    v_package.product_type,
    v_placements,
    v_package.currency,
    v_package.price,
    v_options_price,
    v_package.price + v_options_price,
    v_package.duration_days + v_duration_delta,
    v_options_snapshot,
    jsonb_build_object(
      'id', v_account.id,
      'code', v_account.code,
      'label', v_account.label,
      'bank_name', v_account.bank_name,
      'account_name', v_account.account_name,
      'account_number', v_account.account_number,
      'account_type', v_account.account_type,
      'branch_name', v_account.branch_name,
      'routing_number', v_account.routing_number,
      'swift_code', v_account.swift_code,
      'currency', v_account.currency,
      'instructions', v_account.instructions
    ),
    nullif(left(trim(coalesce(p_customer_notes, '')), 4000), ''),
    p_creative
  )
  RETURNING * INTO v_order;

  PERFORM private.audit_advertising_change(
    v_uid,
    'ad_order',
    v_order.id::text,
    'customer_create_ad_order',
    NULL,
    to_jsonb(v_order) - 'payment_account_snapshot' - 'payment_proof_path'
  );
  PERFORM private.queue_order_notifications(v_order.id, 'created');

  RETURN to_jsonb(v_order);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_ad_payment_proof(
  p_order_id uuid,
  p_proof_path text,
  p_payment_reference text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_before public.ad_orders%ROWTYPE;
  v_after public.ad_orders%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication is required.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_before
  FROM public.ad_orders
  WHERE id = p_order_id AND user_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Advertising order not found.';
  END IF;

  IF v_before.status NOT IN ('pending_payment', 'payment_submitted') THEN
    RAISE EXCEPTION 'Payment proof cannot be changed in the current order status.';
  END IF;

  IF split_part(p_proof_path, '/', 1) <> v_uid::text
     OR split_part(p_proof_path, '/', 2) <> p_order_id::text
     OR NOT EXISTS (
       SELECT 1
       FROM storage.objects o
       WHERE o.bucket_id = 'ad-payment-proofs' AND o.name = p_proof_path
     ) THEN
    RAISE EXCEPTION 'Upload the proof to the private payment-proof folder for this order first.';
  END IF;

  UPDATE public.ad_orders
  SET
    status = 'payment_submitted',
    payment_proof_path = p_proof_path,
    payment_reference = nullif(left(trim(coalesce(p_payment_reference, '')), 250), ''),
    payment_submitted_at = now(),
    rejection_reason = NULL
  WHERE id = p_order_id
  RETURNING * INTO v_after;

  PERFORM private.audit_advertising_change(
    v_uid,
    'ad_order',
    v_after.id::text,
    'customer_submit_bank_transfer_proof',
    (to_jsonb(v_before) - 'payment_account_snapshot' - 'payment_proof_path'),
    (to_jsonb(v_after) - 'payment_account_snapshot' - 'payment_proof_path')
  );
  PERFORM private.queue_order_notifications(v_after.id, 'payment_submitted');

  RETURN to_jsonb(v_after);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_ad_creative(
  p_order_id uuid,
  p_creative jsonb,
  p_creative_path text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_before public.ad_orders%ROWTYPE;
  v_after public.ad_orders%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication is required.' USING ERRCODE = '42501';
  END IF;
  IF p_creative IS NULL OR jsonb_typeof(p_creative) <> 'object'
     OR octet_length(p_creative::text) > 20000 THEN
    RAISE EXCEPTION 'Creative details must be a JSON object no larger than 20 KB.';
  END IF;

  SELECT * INTO v_before
  FROM public.ad_orders
  WHERE id = p_order_id AND user_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Advertising order not found.';
  END IF;
  IF v_before.status NOT IN ('pending_payment', 'payment_submitted') THEN
    RAISE EXCEPTION 'Creative changes require a new review after approval.';
  END IF;

  IF p_creative_path IS NOT NULL AND (
    split_part(p_creative_path, '/', 1) <> v_uid::text
    OR split_part(p_creative_path, '/', 2) <> p_order_id::text
    OR NOT EXISTS (
      SELECT 1 FROM storage.objects o
      WHERE o.bucket_id = 'ad-creatives' AND o.name = p_creative_path
    )
  ) THEN
    RAISE EXCEPTION 'Upload the creative to the private creative folder for this order first.';
  END IF;

  UPDATE public.ad_orders
  SET
    creative_snapshot = p_creative,
    creative_path = p_creative_path
  WHERE id = p_order_id
  RETURNING * INTO v_after;

  PERFORM private.audit_advertising_change(
    v_uid,
    'ad_order',
    v_after.id::text,
    'customer_submit_ad_creative',
    jsonb_build_object('creative', v_before.creative_snapshot, 'creative_path', v_before.creative_path),
    jsonb_build_object('creative', v_after.creative_snapshot, 'creative_path', v_after.creative_path)
  );

  RETURN to_jsonb(v_after);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_ad_orders()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN
      jsonb_build_object('orders', '[]'::jsonb)
    ELSE
      jsonb_build_object(
        'orders',
        coalesce(jsonb_agg(to_jsonb(o) ORDER BY o.created_at DESC), '[]'::jsonb)
      )
  END
  FROM public.ad_orders o
  WHERE o.user_id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- Administrator configuration RPCs
-- Canonical actions: upsert, archive, restore, delete (plus set_default for
-- payment accounts). Payload IDs are optional for upsert and required otherwise.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_manage_payment_account(
  p_action text,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_action text := lower(trim(coalesce(p_action, '')));
  v_id uuid;
  v_before public.payment_accounts%ROWTYPE;
  v_after public.payment_accounts%ROWTYPE;
  v_code text;
  v_currency text;
  v_default boolean;
BEGIN
  PERFORM private.require_admin(v_uid);
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'Payload must be a JSON object.';
  END IF;

  IF nullif(p_payload->>'id', '') IS NOT NULL THEN
    v_id := (p_payload->>'id')::uuid;
  END IF;

  IF v_action = 'upsert' THEN
    IF v_id IS NOT NULL THEN
      SELECT * INTO v_before
      FROM public.payment_accounts
      WHERE id = v_id
      FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Payment account not found.'; END IF;
    END IF;

    v_code := lower(regexp_replace(
      coalesce(nullif(trim(p_payload->>'code'), ''), v_before.code, ''),
      '[^a-zA-Z0-9_-]+',
      '-',
      'g'
    ));
    v_code := trim(both '-' FROM v_code);
    v_currency := upper(coalesce(nullif(trim(p_payload->>'currency'), ''), v_before.currency, 'JMD'));
    v_default := coalesce((p_payload->>'is_default')::boolean, v_before.is_default, false);

    IF v_code = '' OR coalesce(nullif(trim(p_payload->>'label'), ''), v_before.label) IS NULL THEN
      RAISE EXCEPTION 'Payment account code and label are required.';
    END IF;
    IF v_default THEN
      UPDATE public.payment_accounts
      SET is_default = false, updated_by = v_uid
      WHERE is_default = true AND (v_id IS NULL OR id <> v_id);
    END IF;

    IF v_id IS NULL THEN
      INSERT INTO public.payment_accounts (
        code,
        label,
        bank_name,
        account_name,
        account_number,
        account_type,
        branch_name,
        routing_number,
        swift_code,
        currency,
        instructions,
        is_active,
        is_default,
        sort_order,
        metadata,
        created_by,
        updated_by
      ) VALUES (
        v_code,
        trim(p_payload->>'label'),
        nullif(trim(p_payload->>'bank_name'), ''),
        nullif(trim(p_payload->>'account_name'), ''),
        nullif(trim(p_payload->>'account_number'), ''),
        nullif(trim(p_payload->>'account_type'), ''),
        nullif(trim(p_payload->>'branch_name'), ''),
        nullif(trim(p_payload->>'routing_number'), ''),
        nullif(trim(p_payload->>'swift_code'), ''),
        v_currency,
        nullif(trim(p_payload->>'instructions'), ''),
        coalesce((p_payload->>'is_active')::boolean, true),
        v_default,
        coalesce((p_payload->>'sort_order')::integer, 0),
        coalesce(p_payload->'metadata', '{}'::jsonb),
        v_uid,
        v_uid
      )
      RETURNING * INTO v_after;
    ELSE
      UPDATE public.payment_accounts
      SET
        code = v_code,
        label = coalesce(nullif(trim(p_payload->>'label'), ''), label),
        bank_name = CASE WHEN p_payload ? 'bank_name' THEN nullif(trim(p_payload->>'bank_name'), '') ELSE bank_name END,
        account_name = CASE WHEN p_payload ? 'account_name' THEN nullif(trim(p_payload->>'account_name'), '') ELSE account_name END,
        account_number = CASE WHEN p_payload ? 'account_number' THEN nullif(trim(p_payload->>'account_number'), '') ELSE account_number END,
        account_type = CASE WHEN p_payload ? 'account_type' THEN nullif(trim(p_payload->>'account_type'), '') ELSE account_type END,
        branch_name = CASE WHEN p_payload ? 'branch_name' THEN nullif(trim(p_payload->>'branch_name'), '') ELSE branch_name END,
        routing_number = CASE WHEN p_payload ? 'routing_number' THEN nullif(trim(p_payload->>'routing_number'), '') ELSE routing_number END,
        swift_code = CASE WHEN p_payload ? 'swift_code' THEN nullif(trim(p_payload->>'swift_code'), '') ELSE swift_code END,
        currency = v_currency,
        instructions = CASE WHEN p_payload ? 'instructions' THEN nullif(trim(p_payload->>'instructions'), '') ELSE instructions END,
        is_active = coalesce((p_payload->>'is_active')::boolean, is_active),
        is_default = v_default,
        sort_order = coalesce((p_payload->>'sort_order')::integer, sort_order),
        metadata = coalesce(p_payload->'metadata', metadata),
        updated_by = v_uid
      WHERE id = v_id
      RETURNING * INTO v_after;
    END IF;
  ELSIF v_action IN ('archive', 'restore', 'set_default') THEN
    IF v_id IS NULL THEN RAISE EXCEPTION 'Payment account id is required.'; END IF;
    SELECT * INTO v_before FROM public.payment_accounts WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Payment account not found.'; END IF;

    IF v_action = 'set_default' THEN
      UPDATE public.payment_accounts
      SET is_default = false, updated_by = v_uid
      WHERE is_default = true AND id <> v_id;
      UPDATE public.payment_accounts
      SET is_active = true, is_default = true, updated_by = v_uid
      WHERE id = v_id
      RETURNING * INTO v_after;
    ELSE
      UPDATE public.payment_accounts
      SET
        is_active = (v_action = 'restore'),
        is_default = CASE WHEN v_action = 'archive' THEN false ELSE is_default END,
        updated_by = v_uid
      WHERE id = v_id
      RETURNING * INTO v_after;
    END IF;
  ELSIF v_action = 'delete' THEN
    IF v_id IS NULL THEN RAISE EXCEPTION 'Payment account id is required.'; END IF;
    SELECT * INTO v_before FROM public.payment_accounts WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Payment account not found.'; END IF;
    IF EXISTS (SELECT 1 FROM public.ad_packages WHERE payment_account_id = v_id)
       OR EXISTS (SELECT 1 FROM public.ad_orders WHERE payment_account_id = v_id) THEN
      RAISE EXCEPTION 'This payment account is in use. Archive it instead.';
    END IF;
    DELETE FROM public.payment_accounts WHERE id = v_id RETURNING * INTO v_after;
  ELSE
    RAISE EXCEPTION 'Unsupported payment account action: %.', v_action;
  END IF;

  PERFORM private.audit_advertising_change(
    v_uid,
    'payment_account',
    coalesce(v_after.id, v_before.id)::text,
    'admin_payment_account_' || v_action,
    private.redact_payment_account(to_jsonb(v_before)),
    private.redact_payment_account(to_jsonb(v_after))
  );

  RETURN CASE WHEN v_action = 'delete' THEN jsonb_build_object('deleted', true, 'id', v_id) ELSE to_jsonb(v_after) END;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_manage_ad_package(
  p_action text,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_action text := lower(trim(coalesce(p_action, '')));
  v_id uuid;
  v_before public.ad_packages%ROWTYPE;
  v_after public.ad_packages%ROWTYPE;
  v_code text;
  v_product_type text;
  v_currency text;
  v_tier text;
  v_placements text[];
  v_payment_account_id uuid;
  v_features jsonb;
BEGIN
  PERFORM private.require_admin(v_uid);
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'Payload must be a JSON object.';
  END IF;
  IF nullif(p_payload->>'id', '') IS NOT NULL THEN v_id := (p_payload->>'id')::uuid; END IF;

  IF v_action = 'upsert' THEN
    IF v_id IS NOT NULL THEN
      SELECT * INTO v_before FROM public.ad_packages WHERE id = v_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Advertising package not found.'; END IF;
    END IF;

    v_code := lower(regexp_replace(
      coalesce(nullif(trim(p_payload->>'code'), ''), v_before.code, ''),
      '[^a-zA-Z0-9_-]+', '-', 'g'
    ));
    v_code := trim(both '-' FROM v_code);
    v_product_type := coalesce(nullif(p_payload->>'product_type', ''), v_before.product_type, 'display_ad');
    v_currency := upper(coalesce(nullif(trim(p_payload->>'currency'), ''), v_before.currency, 'JMD'));
    v_tier := CASE
      WHEN v_product_type = 'webpage' THEN coalesce(nullif(p_payload->>'webpage_tier', ''), v_before.webpage_tier)
      ELSE NULL
    END;
    v_features := coalesce(p_payload->'features', v_before.features, '{}'::jsonb);

    IF p_payload ? 'placements' THEN
      IF jsonb_typeof(p_payload->'placements') <> 'array' THEN RAISE EXCEPTION 'placements must be an array.'; END IF;
      SELECT coalesce(array_agg(DISTINCT value ORDER BY value), '{}'::text[])
      INTO v_placements
      FROM jsonb_array_elements_text(p_payload->'placements') value
      WHERE nullif(trim(value), '') IS NOT NULL;
    ELSE
      v_placements := coalesce(v_before.placements, '{}'::text[]);
    END IF;

    IF p_payload ? 'payment_account_id' AND nullif(p_payload->>'payment_account_id', '') IS NOT NULL THEN
      v_payment_account_id := (p_payload->>'payment_account_id')::uuid;
    ELSIF p_payload ? 'payment_account_id' THEN
      v_payment_account_id := NULL;
    ELSE
      v_payment_account_id := v_before.payment_account_id;
    END IF;

    IF v_code = '' OR coalesce(nullif(trim(p_payload->>'name'), ''), v_before.name) IS NULL THEN
      RAISE EXCEPTION 'Package code and name are required.';
    END IF;
    IF v_product_type NOT IN ('webpage', 'display_ad') THEN RAISE EXCEPTION 'Invalid product type.'; END IF;
    IF v_product_type = 'webpage' AND v_tier NOT IN ('silver', 'gold', 'platinum') THEN
      RAISE EXCEPTION 'Webpage packages require a Silver, Gold or Platinum tier.';
    END IF;
    IF jsonb_typeof(v_features) NOT IN ('object', 'array') THEN RAISE EXCEPTION 'features must be an object or array.'; END IF;
    IF v_payment_account_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.payment_accounts pa
      WHERE pa.id = v_payment_account_id AND pa.currency = v_currency
    ) THEN
      RAISE EXCEPTION 'Payment account is unavailable or uses a different currency.';
    END IF;

    IF v_id IS NULL THEN
      INSERT INTO public.ad_packages (
        code, name, description, product_type, price, currency, duration_days,
        placements, features, is_active, sort_order, payment_account_id,
        webpage_enabled, webpage_tier, updated_at
      ) VALUES (
        v_code,
        trim(p_payload->>'name'),
        nullif(trim(p_payload->>'description'), ''),
        v_product_type,
        coalesce((p_payload->>'price')::numeric, 0),
        v_currency,
        coalesce((p_payload->>'duration_days')::integer, 30),
        v_placements,
        v_features,
        coalesce((p_payload->>'is_active')::boolean, true),
        coalesce((p_payload->>'sort_order')::integer, 0),
        v_payment_account_id,
        v_product_type = 'webpage',
        v_tier,
        now()
      ) RETURNING * INTO v_after;
    ELSE
      UPDATE public.ad_packages
      SET
        code = v_code,
        name = coalesce(nullif(trim(p_payload->>'name'), ''), name),
        description = CASE WHEN p_payload ? 'description' THEN nullif(trim(p_payload->>'description'), '') ELSE description END,
        product_type = v_product_type,
        price = coalesce((p_payload->>'price')::numeric, price),
        currency = v_currency,
        duration_days = coalesce((p_payload->>'duration_days')::integer, duration_days),
        placements = v_placements,
        features = v_features,
        is_active = coalesce((p_payload->>'is_active')::boolean, is_active),
        sort_order = coalesce((p_payload->>'sort_order')::integer, sort_order),
        payment_account_id = v_payment_account_id,
        webpage_enabled = v_product_type = 'webpage',
        webpage_tier = v_tier
      WHERE id = v_id
      RETURNING * INTO v_after;
    END IF;
  ELSIF v_action IN ('archive', 'restore') THEN
    IF v_id IS NULL THEN RAISE EXCEPTION 'Package id is required.'; END IF;
    SELECT * INTO v_before FROM public.ad_packages WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Advertising package not found.'; END IF;
    UPDATE public.ad_packages
    SET is_active = (v_action = 'restore')
    WHERE id = v_id
    RETURNING * INTO v_after;
  ELSIF v_action = 'delete' THEN
    IF v_id IS NULL THEN RAISE EXCEPTION 'Package id is required.'; END IF;
    SELECT * INTO v_before FROM public.ad_packages WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Advertising package not found.'; END IF;
    IF EXISTS (SELECT 1 FROM public.ad_orders WHERE package_id = v_id)
       OR EXISTS (SELECT 1 FROM public.ad_subscriptions WHERE package_id = v_id) THEN
      RAISE EXCEPTION 'This package has order history. Archive it instead.';
    END IF;
    DELETE FROM public.ad_packages WHERE id = v_id RETURNING * INTO v_after;
  ELSE
    RAISE EXCEPTION 'Unsupported package action: %.', v_action;
  END IF;

  PERFORM private.audit_advertising_change(
    v_uid,
    'ad_package',
    coalesce(v_after.id, v_before.id)::text,
    'admin_ad_package_' || v_action,
    to_jsonb(v_before),
    to_jsonb(v_after)
  );
  RETURN CASE WHEN v_action = 'delete' THEN jsonb_build_object('deleted', true, 'id', v_id) ELSE to_jsonb(v_after) END;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_manage_ad_package_option(
  p_action text,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_action text := lower(trim(coalesce(p_action, '')));
  v_id uuid;
  v_package_id uuid;
  v_before public.ad_package_options%ROWTYPE;
  v_after public.ad_package_options%ROWTYPE;
  v_code text;
  v_placements text[];
  v_features jsonb;
BEGIN
  PERFORM private.require_admin(v_uid);
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN RAISE EXCEPTION 'Payload must be a JSON object.'; END IF;
  IF nullif(p_payload->>'id', '') IS NOT NULL THEN v_id := (p_payload->>'id')::uuid; END IF;

  IF v_action = 'upsert' THEN
    IF v_id IS NOT NULL THEN
      SELECT * INTO v_before FROM public.ad_package_options WHERE id = v_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Package option not found.'; END IF;
    END IF;
    v_package_id := coalesce((p_payload->>'package_id')::uuid, v_before.package_id);
    v_code := lower(regexp_replace(coalesce(nullif(trim(p_payload->>'code'), ''), v_before.code, ''), '[^a-zA-Z0-9_-]+', '-', 'g'));
    v_code := trim(both '-' FROM v_code);
    v_features := coalesce(p_payload->'features', v_before.features, '{}'::jsonb);

    IF p_payload ? 'additional_placements' THEN
      IF jsonb_typeof(p_payload->'additional_placements') <> 'array' THEN RAISE EXCEPTION 'additional_placements must be an array.'; END IF;
      SELECT coalesce(array_agg(DISTINCT value ORDER BY value), '{}'::text[])
      INTO v_placements
      FROM jsonb_array_elements_text(p_payload->'additional_placements') value
      WHERE nullif(trim(value), '') IS NOT NULL;
    ELSE
      v_placements := coalesce(v_before.additional_placements, '{}'::text[]);
    END IF;

    IF v_package_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.ad_packages WHERE id = v_package_id) THEN
      RAISE EXCEPTION 'A valid package is required.';
    END IF;
    IF v_code = '' OR coalesce(nullif(trim(p_payload->>'name'), ''), v_before.name) IS NULL THEN
      RAISE EXCEPTION 'Option code and name are required.';
    END IF;
    IF jsonb_typeof(v_features) NOT IN ('object', 'array') THEN RAISE EXCEPTION 'features must be an object or array.'; END IF;

    IF v_id IS NULL THEN
      INSERT INTO public.ad_package_options (
        package_id, code, name, description, price_delta, duration_days_delta,
        additional_placements, features, is_active, sort_order, created_by, updated_by
      ) VALUES (
        v_package_id,
        v_code,
        trim(p_payload->>'name'),
        nullif(trim(p_payload->>'description'), ''),
        coalesce((p_payload->>'price_delta')::numeric, 0),
        coalesce((p_payload->>'duration_days_delta')::integer, 0),
        v_placements,
        v_features,
        coalesce((p_payload->>'is_active')::boolean, true),
        coalesce((p_payload->>'sort_order')::integer, 0),
        v_uid,
        v_uid
      ) RETURNING * INTO v_after;
    ELSE
      UPDATE public.ad_package_options
      SET
        package_id = v_package_id,
        code = v_code,
        name = coalesce(nullif(trim(p_payload->>'name'), ''), name),
        description = CASE WHEN p_payload ? 'description' THEN nullif(trim(p_payload->>'description'), '') ELSE description END,
        price_delta = coalesce((p_payload->>'price_delta')::numeric, price_delta),
        duration_days_delta = coalesce((p_payload->>'duration_days_delta')::integer, duration_days_delta),
        additional_placements = v_placements,
        features = v_features,
        is_active = coalesce((p_payload->>'is_active')::boolean, is_active),
        sort_order = coalesce((p_payload->>'sort_order')::integer, sort_order),
        updated_by = v_uid
      WHERE id = v_id
      RETURNING * INTO v_after;
    END IF;
  ELSIF v_action IN ('archive', 'restore') THEN
    IF v_id IS NULL THEN RAISE EXCEPTION 'Option id is required.'; END IF;
    SELECT * INTO v_before FROM public.ad_package_options WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Package option not found.'; END IF;
    UPDATE public.ad_package_options
    SET is_active = (v_action = 'restore'), updated_by = v_uid
    WHERE id = v_id
    RETURNING * INTO v_after;
  ELSIF v_action = 'delete' THEN
    IF v_id IS NULL THEN RAISE EXCEPTION 'Option id is required.'; END IF;
    SELECT * INTO v_before FROM public.ad_package_options WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Package option not found.'; END IF;
    DELETE FROM public.ad_package_options WHERE id = v_id RETURNING * INTO v_after;
  ELSE
    RAISE EXCEPTION 'Unsupported package option action: %.', v_action;
  END IF;

  PERFORM private.audit_advertising_change(
    v_uid,
    'ad_package_option',
    coalesce(v_after.id, v_before.id)::text,
    'admin_ad_package_option_' || v_action,
    to_jsonb(v_before),
    to_jsonb(v_after)
  );
  RETURN CASE WHEN v_action = 'delete' THEN jsonb_build_object('deleted', true, 'id', v_id) ELSE to_jsonb(v_after) END;
END;
$$;
