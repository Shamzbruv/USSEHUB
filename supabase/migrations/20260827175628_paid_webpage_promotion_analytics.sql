-- Turn an activated AJM webpage into an immediately useful, measurable
-- product. Approved listings receive a safe starter page, published pages
-- receive one network promotion, and both manual/admin activations and paid
-- orders flow through the same privacy-preserving analytics.

-- ---------------------------------------------------------------------------
-- 1. Customer-controlled promotion presentation.
-- ---------------------------------------------------------------------------

ALTER TABLE public.listing_webpages
  ADD COLUMN IF NOT EXISTS promotion_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS promotion_style text NOT NULL DEFAULT 'native',
  ADD COLUMN IF NOT EXISTS promotion_headline text,
  ADD COLUMN IF NOT EXISTS promotion_text text,
  ADD COLUMN IF NOT EXISTS promotion_cta_label text NOT NULL DEFAULT 'View business',
  ADD COLUMN IF NOT EXISTS starter_generated boolean NOT NULL DEFAULT false;

ALTER TABLE public.listing_webpages
  DROP CONSTRAINT IF EXISTS listing_webpages_promotion_style_check,
  DROP CONSTRAINT IF EXISTS listing_webpages_promotion_copy_check;

ALTER TABLE public.listing_webpages
  ADD CONSTRAINT listing_webpages_promotion_style_check
    CHECK (promotion_style IN ('native', 'banner', 'spotlight')),
  ADD CONSTRAINT listing_webpages_promotion_copy_check
    CHECK (
      char_length(coalesce(promotion_headline, '')) <= 120
      AND char_length(coalesce(promotion_text, '')) <= 500
      AND char_length(promotion_cta_label) BETWEEN 1 AND 40
    );

-- ---------------------------------------------------------------------------
-- 2. A promotion may originate from an order or a manually activated
--    subscription. Events retain an optional order reference for both cases.
-- ---------------------------------------------------------------------------

ALTER TABLE public.advertisements
  ALTER COLUMN order_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS subscription_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'advertisements_subscription_id_fkey'
      AND conrelid = 'public.advertisements'::regclass
  ) THEN
    ALTER TABLE public.advertisements
      ADD CONSTRAINT advertisements_subscription_id_fkey
      FOREIGN KEY (subscription_id)
      REFERENCES public.ad_subscriptions(id)
      ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.advertisements
  DROP CONSTRAINT IF EXISTS advertisements_source_check;

ALTER TABLE public.advertisements
  ADD CONSTRAINT advertisements_source_check
  CHECK (order_id IS NOT NULL OR subscription_id IS NOT NULL);

ALTER TABLE public.ad_events
  ALTER COLUMN order_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_advertisements_subscription
ON public.advertisements (subscription_id, status, expires_at)
WHERE subscription_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS advertisements_webpage_promotion_listing_key
ON public.advertisements (listing_id)
WHERE placement = 'webpage-network';

CREATE INDEX IF NOT EXISTS idx_ad_events_ad_day_type
ON public.ad_events (advertisement_id, occurred_on, event_type);

-- ---------------------------------------------------------------------------
-- 3. Activation creates a populated starter page for an approved listing.
--    Existing customer content is never overwritten. A completely blank
--    system-created draft is hydrated once so an upgrade is useful at once.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.ensure_active_webpage_draft()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tier text;
  v_market_segment text;
  v_created_by uuid;
  v_listing public.listings%ROWTYPE;
  v_page public.listing_webpages%ROWTYPE;
  v_is_blank boolean;
  v_reconciliation text;
  v_promotion_style text := 'native';
  v_apply_order_style boolean := false;
BEGIN
  IF NEW.status IS DISTINCT FROM 'active'
     OR NEW.listing_id IS NULL
     OR NEW.package_id IS NULL
     OR NEW.user_id IS NULL
     OR (NEW.expires_at IS NOT NULL AND NEW.expires_at <= now()) THEN
    RETURN NEW;
  END IF;

  SELECT
    lower(p.webpage_tier),
    coalesce(l.market_segment, 'local-business'),
    CASE WHEN pr.id IS NOT NULL THEN NEW.user_id ELSE NULL END
  INTO v_tier, v_market_segment, v_created_by
  FROM public.ad_packages p
  JOIN public.listings l
    ON l.id = NEW.listing_id
   AND l.owner_user_id = NEW.user_id
  LEFT JOIN public.profiles pr ON pr.id = NEW.user_id
  WHERE p.id = NEW.package_id
    AND p.is_active = true
    AND p.webpage_enabled = true
    AND lower(p.webpage_tier) IN ('silver', 'gold', 'platinum');

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF NEW.ad_order_id IS NOT NULL THEN
    IF TG_OP = 'INSERT' THEN
      v_apply_order_style := true;
    ELSE
      v_apply_order_style := NEW.ad_order_id IS DISTINCT FROM OLD.ad_order_id
        OR NEW.package_id IS DISTINCT FROM OLD.package_id;
    END IF;
  END IF;

  IF v_apply_order_style THEN
    SELECT CASE
      WHEN o.creative_snapshot->>'promotion_style' IN ('native', 'banner', 'spotlight')
        THEN o.creative_snapshot->>'promotion_style'
      ELSE 'native'
    END
    INTO v_promotion_style
    FROM public.ad_orders o
    WHERE o.id = NEW.ad_order_id;
    v_promotion_style := coalesce(v_promotion_style, 'native');
  END IF;

  SELECT * INTO v_listing
  FROM public.listings
  WHERE id = NEW.listing_id
    AND owner_user_id = NEW.user_id;

  SELECT * INTO v_page
  FROM public.listing_webpages
  WHERE listing_id = NEW.listing_id
  FOR UPDATE;

  -- Untouched starter content can safely follow a changed package without the
  -- published-content protection intended for customer-authored pages.
  IF FOUND
     AND v_page.starter_generated
     AND v_page.page_status = 'published'
     AND (
       v_page.tier IS DISTINCT FROM v_tier
       OR v_page.market_segment IS DISTINCT FROM v_market_segment
     ) THEN
    UPDATE public.listing_webpages
    SET page_status = 'draft'
    WHERE listing_id = NEW.listing_id;
  END IF;

  -- Retain the established exact-tier reconciliation behavior. In particular,
  -- authored drafts are safely downgraded and incompatible published pages are
  -- returned to review without losing their premium content.
  v_reconciliation := private.reconcile_listing_webpage_draft(
    NEW.listing_id,
    v_tier,
    v_market_segment,
    v_created_by,
    'active_subscription'
  );

  SELECT * INTO v_page
  FROM public.listing_webpages
  WHERE listing_id = NEW.listing_id
  FOR UPDATE;

  v_is_blank := v_page.page_status = 'draft'
    AND (
      v_page.starter_generated
      OR (
        nullif(trim(coalesce(v_page.tagline, '')), '') IS NULL
        AND nullif(trim(coalesce(v_page.logo_url, '')), '') IS NULL
        AND nullif(trim(coalesce(v_page.address, '')), '') IS NULL
        AND nullif(trim(coalesce(v_page.about_text, '')), '') IS NULL
        AND coalesce(array_length(v_page.gallery_urls, 1), 0) = 0
      )
    );

  UPDATE public.listing_webpages
  SET
    tier = CASE
      WHEN private.ajm_tier_rank(v_tier) > private.ajm_tier_rank(tier) THEN v_tier
      ELSE tier
    END,
    market_segment = CASE WHEN v_is_blank THEN v_market_segment ELSE market_segment END,
    page_status = CASE
      WHEN v_is_blank AND v_listing.status = 'approved' THEN 'published'
      ELSE page_status
    END,
    tagline = CASE
      WHEN v_is_blank THEN left(nullif(trim(coalesce(v_listing.description, '')), ''), 140)
      ELSE tagline
    END,
    logo_url = CASE
      WHEN v_is_blank THEN nullif(trim(coalesce(v_listing.image_url, '')), '')
      ELSE logo_url
    END,
    address = CASE
      WHEN v_is_blank THEN nullif(trim(coalesce(v_listing.location, '')), '')
      ELSE address
    END,
    about_text = CASE
      WHEN v_is_blank THEN nullif(trim(coalesce(v_listing.description, '')), '')
      ELSE about_text
    END,
    gallery_urls = CASE
      WHEN v_is_blank AND nullif(trim(coalesce(v_listing.image_url, '')), '') IS NOT NULL
        THEN ARRAY[v_listing.image_url]
      WHEN v_is_blank THEN '{}'::text[]
      ELSE gallery_urls
    END,
    starter_generated = CASE WHEN v_is_blank THEN true ELSE starter_generated END,
    promotion_style = CASE WHEN v_is_blank THEN v_promotion_style ELSE promotion_style END,
    updated_at = CASE WHEN v_is_blank THEN clock_timestamp() ELSE updated_at END
  WHERE listing_id = NEW.listing_id
    AND v_is_blank;

  -- A newly purchased package carries the format selected at checkout even
  -- when an authored page already exists. Routine pause/resume updates do not
  -- reapply the old order snapshot over a newer builder choice.
  IF v_apply_order_style AND NOT v_is_blank THEN
    UPDATE public.listing_webpages
    SET promotion_style = v_promotion_style
    WHERE listing_id = NEW.listing_id
      AND promotion_style IS DISTINCT FROM v_promotion_style;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.ensure_active_webpage_draft()
FROM PUBLIC, anon, authenticated;

-- Manual activation selects the market segment in the same RPC, immediately
-- after inserting the subscription. An untouched starter can follow that
-- administrator-selected segment without being mistaken for authored live
-- content and unnecessarily returned to draft review.
CREATE OR REPLACE FUNCTION private.sync_listing_webpage_market_segment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_page public.listing_webpages%ROWTYPE;
  v_after public.listing_webpages%ROWTYPE;
  v_active_tier text;
  v_created_by uuid;
BEGIN
  IF NEW.market_segment IS NULL
     OR NEW.market_segment IS NOT DISTINCT FROM OLD.market_segment THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_page
  FROM public.listing_webpages
  WHERE listing_id = NEW.id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT lower(p.webpage_tier), s.user_id
  INTO v_active_tier, v_created_by
  FROM public.ad_subscriptions s
  JOIN public.ad_packages p ON p.id = s.package_id
  WHERE s.listing_id = NEW.id
    AND s.status = 'active'
    AND (s.expires_at IS NULL OR s.expires_at > now())
    AND p.is_active = true
    AND p.webpage_enabled = true
    AND lower(p.webpage_tier) IN ('silver', 'gold', 'platinum')
  ORDER BY s.created_at DESC NULLS LAST, s.id DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_page.starter_generated
     AND v_page.tier IS NOT DISTINCT FROM v_active_tier THEN
    UPDATE public.listing_webpages
    SET
      market_segment = NEW.market_segment,
      segment_content = '{}'::jsonb,
      updated_at = clock_timestamp()
    WHERE listing_id = NEW.id
    RETURNING * INTO v_after;

    PERFORM private.audit_advertising_change(
      auth.uid(),
      'listing_webpage',
      NEW.id::text,
      'listing_webpage_starter_segment_synced',
      to_jsonb(v_page),
      to_jsonb(v_after)
    );
    RETURN NEW;
  END IF;

  -- A package switch may just have unpublished incompatible authored content.
  -- Its old tier is the preservation marker; a later review must decide how
  -- to reconcile it rather than silently removing premium fields here.
  IF v_page.page_status = 'draft'
     AND v_page.tier IS DISTINCT FROM v_active_tier THEN
    RETURN NEW;
  END IF;

  PERFORM private.reconcile_listing_webpage_draft(
    NEW.id,
    v_active_tier,
    NEW.market_segment,
    v_created_by,
    'listing_market_segment_changed'
  );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.sync_listing_webpage_market_segment()
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. One network promotion is synchronized from each active, published paid
--    webpage. It is paused automatically when a page becomes a draft and
--    cancelled/expired when access ends.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.sync_listing_webpage_promotion(
  p_listing_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_listing public.listings%ROWTYPE;
  v_page public.listing_webpages%ROWTYPE;
  v_subscription public.ad_subscriptions%ROWTYPE;
  v_package public.ad_packages%ROWTYPE;
  v_ad public.advertisements%ROWTYPE;
  v_media_url text;
  v_expires timestamptz;
BEGIN
  IF p_listing_id IS NULL THEN
    RETURN jsonb_build_object('active', false, 'reason', 'missing_listing');
  END IF;

  SELECT * INTO v_listing
  FROM public.listings
  WHERE id = p_listing_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('active', false, 'reason', 'listing_not_found');
  END IF;

  SELECT s.* INTO v_subscription
  FROM public.ad_subscriptions s
  JOIN public.ad_packages p ON p.id = s.package_id
  WHERE s.listing_id = p_listing_id
    AND s.user_id = v_listing.owner_user_id
    AND s.status IN ('active', 'paused')
    AND (s.expires_at IS NULL OR s.expires_at > now())
    AND p.is_active = true
    AND p.product_type = 'webpage'
    AND p.webpage_enabled = true
  ORDER BY
    CASE WHEN s.status = 'active' THEN 0 ELSE 1 END,
    private.ajm_tier_rank(p.webpage_tier) DESC,
    s.created_at DESC,
    s.id
  LIMIT 1;

  IF NOT FOUND THEN
    UPDATE public.advertisements
    SET
      status = CASE WHEN expires_at <= now() THEN 'expired' ELSE 'cancelled' END,
      updated_at = now()
    WHERE listing_id = p_listing_id
      AND placement = 'webpage-network'
      AND status IN ('active', 'paused');
    RETURN jsonb_build_object('active', false, 'reason', 'no_active_subscription');
  END IF;

  SELECT * INTO v_package
  FROM public.ad_packages
  WHERE id = v_subscription.package_id;

  IF v_subscription.status = 'paused' THEN
    UPDATE public.advertisements
    SET
      order_id = v_subscription.ad_order_id,
      subscription_id = v_subscription.id,
      package_id = v_subscription.package_id,
      status = 'paused',
      expires_at = coalesce(v_subscription.expires_at, expires_at),
      updated_at = now()
    WHERE listing_id = p_listing_id
      AND placement = 'webpage-network'
      AND status IN ('active', 'paused');
    RETURN jsonb_build_object('active', false, 'paused', true, 'reason', 'subscription_paused');
  END IF;

  SELECT * INTO v_page
  FROM public.listing_webpages
  WHERE listing_id = p_listing_id;

  IF NOT FOUND
     OR v_page.page_status <> 'published'
     OR NOT v_page.promotion_enabled
     OR v_listing.status <> 'approved'
     OR (v_listing.expires_at IS NOT NULL AND v_listing.expires_at <= now()) THEN
    UPDATE public.advertisements
    SET status = 'paused', updated_at = now()
    WHERE listing_id = p_listing_id
      AND placement = 'webpage-network'
      AND status = 'active';
    RETURN jsonb_build_object('active', false, 'reason', 'page_not_publishable');
  END IF;

  v_media_url := coalesce(
    nullif(trim(coalesce(v_page.hero_media_url, '')), ''),
    nullif(trim(coalesce(v_page.logo_url, '')), ''),
    nullif(trim(coalesce(v_listing.image_url, '')), '')
  );
  v_expires := coalesce(v_subscription.expires_at, now() + interval '10 years');

  INSERT INTO public.advertisements (
    order_id,
    subscription_id,
    user_id,
    listing_id,
    package_id,
    placement,
    status,
    headline,
    body_text,
    cta_label,
    cta_url,
    creative_path,
    creative_metadata,
    starts_at,
    expires_at
  ) VALUES (
    v_subscription.ad_order_id,
    v_subscription.id,
    v_listing.owner_user_id,
    v_listing.id,
    v_package.id,
    'webpage-network',
    'active',
    left(coalesce(
      nullif(trim(coalesce(v_page.promotion_headline, '')), ''),
      nullif(trim(coalesce(v_listing.business_name, '')), ''),
      'Featured AJM business'
    ), 240),
    left(coalesce(
      nullif(trim(coalesce(v_page.promotion_text, '')), ''),
      nullif(trim(coalesce(v_page.tagline, '')), ''),
      nullif(trim(coalesce(v_page.about_text, '')), ''),
      nullif(trim(coalesce(v_listing.description, '')), ''),
      'Discover this Jamaican business on AJM.'
    ), 500),
    left(coalesce(nullif(trim(v_page.promotion_cta_label), ''), 'View business'), 80),
    'https://www.ussehub.com/ajm-business-page?listing=' || v_listing.id::text,
    v_media_url,
    jsonb_strip_nulls(jsonb_build_object(
      'source', 'paid_webpage',
      'format', v_page.promotion_style,
      'media_url', v_media_url,
      'media_type', 'image',
      'tier', v_page.tier
    )),
    now(),
    v_expires
  )
  ON CONFLICT (listing_id) WHERE placement = 'webpage-network'
  DO UPDATE SET
    order_id = EXCLUDED.order_id,
    subscription_id = EXCLUDED.subscription_id,
    user_id = EXCLUDED.user_id,
    package_id = EXCLUDED.package_id,
    status = 'active',
    headline = EXCLUDED.headline,
    body_text = EXCLUDED.body_text,
    cta_label = EXCLUDED.cta_label,
    cta_url = EXCLUDED.cta_url,
    creative_path = EXCLUDED.creative_path,
    creative_metadata = EXCLUDED.creative_metadata,
    starts_at = CASE
      WHEN advertisements.status = 'active' THEN advertisements.starts_at
      ELSE EXCLUDED.starts_at
    END,
    expires_at = EXCLUDED.expires_at,
    updated_at = now()
  RETURNING * INTO v_ad;

  RETURN jsonb_build_object(
    'active', true,
    'advertisement_id', v_ad.id,
    'listing_id', v_ad.listing_id,
    'style', v_page.promotion_style,
    'expires_at', v_ad.expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION private.trigger_listing_webpage_promotion_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.sync_listing_webpage_promotion(
    CASE WHEN TG_OP = 'DELETE' THEN OLD.listing_id ELSE NEW.listing_id END
  );
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_listing_webpage_promotion
ON public.listing_webpages;

CREATE TRIGGER trg_sync_listing_webpage_promotion
AFTER INSERT OR UPDATE OR DELETE
ON public.listing_webpages
FOR EACH ROW
EXECUTE FUNCTION private.trigger_listing_webpage_promotion_sync();

DROP TRIGGER IF EXISTS trg_sync_paid_webpage_subscription_promotion
ON public.ad_subscriptions;

CREATE TRIGGER trg_sync_paid_webpage_subscription_promotion
AFTER INSERT OR UPDATE OR DELETE
ON public.ad_subscriptions
FOR EACH ROW
EXECUTE FUNCTION private.trigger_listing_webpage_promotion_sync();

CREATE OR REPLACE FUNCTION private.trigger_listing_promotion_eligibility_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'approved'
     AND NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE public.listing_webpages w
    SET
      page_status = 'published',
      updated_at = clock_timestamp()
    WHERE w.listing_id = NEW.id
      AND w.starter_generated
      AND w.page_status = 'draft'
      AND EXISTS (
        SELECT 1
        FROM public.ad_subscriptions s
        JOIN public.ad_packages p ON p.id = s.package_id
        WHERE s.listing_id = NEW.id
          AND s.user_id = NEW.owner_user_id
          AND s.status = 'active'
          AND (s.expires_at IS NULL OR s.expires_at > now())
          AND p.is_active = true
          AND p.product_type = 'webpage'
          AND p.webpage_enabled = true
      );
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status
     OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
     OR NEW.business_name IS DISTINCT FROM OLD.business_name
     OR NEW.description IS DISTINCT FROM OLD.description
     OR NEW.image_url IS DISTINCT FROM OLD.image_url THEN
    PERFORM private.sync_listing_webpage_promotion(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_listing_promotion_eligibility
ON public.listings;

CREATE TRIGGER trg_sync_listing_promotion_eligibility
AFTER UPDATE OF status, expires_at, business_name, description, image_url
ON public.listings
FOR EACH ROW
EXECUTE FUNCTION private.trigger_listing_promotion_eligibility_sync();

REVOKE ALL ON FUNCTION private.sync_listing_webpage_promotion(uuid)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.trigger_listing_webpage_promotion_sync()
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.trigger_listing_promotion_eligibility_sync()
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Public delivery uses a rotating ordering window rather than newest-first
--    starvation. Paid webpage promotions must still be active and published.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_active_advertisements(
  p_placement text DEFAULT NULL,
  p_limit integer DEFAULT 12
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'advertisements', coalesce(
      jsonb_agg(to_jsonb(delivery) - 'rotation_key' ORDER BY delivery.rotation_key, delivery.id),
      '[]'::jsonb
    )
  )
  FROM (
    SELECT
      a.id,
      CASE
        WHEN l.status = 'approved'
          AND (l.expires_at IS NULL OR l.expires_at > now())
          AND (l.published_at IS NULL OR l.published_at <= now())
          THEN a.listing_id
        ELSE NULL
      END AS listing_id,
      a.placement,
      a.headline,
      a.body_text,
      a.cta_label,
      a.cta_url,
      a.creative_path,
      a.creative_metadata,
      a.starts_at,
      a.expires_at,
      p.name AS package_name,
      CASE
        WHEN l.status = 'approved'
          AND (l.expires_at IS NULL OR l.expires_at > now())
          AND (l.published_at IS NULL OR l.published_at <= now())
          THEN l.business_name
        ELSE NULL
      END AS business_name,
      md5(
        a.id::text || ':' ||
        floor(extract(epoch FROM now()) / 900)::bigint::text || ':' ||
        coalesce(p_placement, '*')
      ) AS rotation_key
    FROM public.advertisements a
    JOIN public.ad_packages p ON p.id = a.package_id
    LEFT JOIN public.listings l ON l.id = a.listing_id
    WHERE a.status = 'active'
      AND a.starts_at <= now()
      AND a.expires_at > now()
      AND (nullif(trim(p_placement), '') IS NULL OR a.placement = trim(p_placement))
      AND (
        a.placement <> 'webpage-network'
        OR (
          l.status = 'approved'
          AND (l.expires_at IS NULL OR l.expires_at > now())
          AND (l.published_at IS NULL OR l.published_at <= now())
          AND EXISTS (
            SELECT 1
            FROM public.listing_webpages w
            WHERE w.listing_id = a.listing_id
              AND w.page_status = 'published'
              AND w.promotion_enabled = true
          )
          AND EXISTS (
            SELECT 1
            FROM public.ad_subscriptions s
            JOIN public.ad_packages sp ON sp.id = s.package_id
            WHERE s.id = a.subscription_id
              AND s.status = 'active'
              AND (s.expires_at IS NULL OR s.expires_at > now())
              AND sp.is_active = true
              AND sp.product_type = 'webpage'
              AND sp.webpage_enabled = true
          )
        )
      )
    ORDER BY rotation_key, a.id
    LIMIT greatest(1, least(coalesce(p_limit, 12), 50))
  ) delivery;
$$;

-- ---------------------------------------------------------------------------
-- 6. Public webpage engagement is attached to the listing's active network
--    promotion, preserving the same daily anonymous-session deduplication.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.record_webpage_event(
  p_listing_id uuid,
  p_event_type text,
  p_session_token text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_advertisement_id uuid;
  v_event_type text := lower(trim(coalesce(p_event_type, '')));
BEGIN
  IF v_event_type NOT IN ('view', 'click', 'lead', 'call', 'chat', 'booking') THEN
    RAISE EXCEPTION 'Unsupported webpage event type.';
  END IF;

  SELECT a.id INTO v_advertisement_id
  FROM public.advertisements a
  JOIN public.listings l ON l.id = a.listing_id
  JOIN public.listing_webpages w ON w.listing_id = a.listing_id
  JOIN public.ad_subscriptions s ON s.id = a.subscription_id
  WHERE a.listing_id = p_listing_id
    AND a.placement = 'webpage-network'
    AND a.status = 'active'
    AND a.starts_at <= now()
    AND a.expires_at > now()
    AND l.status = 'approved'
    AND (l.expires_at IS NULL OR l.expires_at > now())
    AND (l.published_at IS NULL OR l.published_at <= now())
    AND w.page_status = 'published'
    AND w.promotion_enabled = true
    AND s.status = 'active'
    AND (s.expires_at IS NULL OR s.expires_at > now())
  LIMIT 1;

  IF v_advertisement_id IS NULL THEN
    RETURN jsonb_build_object('recorded', false, 'reason', 'no_active_webpage_promotion');
  END IF;

  RETURN public.record_ad_event(
    v_advertisement_id,
    v_event_type,
    p_session_token,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('listing_id', p_listing_id)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Member reporting now covers display campaigns and paid webpage
--    promotions, with a bounded reporting range and summary KPIs.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.get_my_ad_performance();

CREATE FUNCTION public.get_my_ad_performance(
  p_days integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_days integer := greatest(1, least(coalesce(p_days, 30), 3650));
  v_since date;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication is required.' USING ERRCODE = '42501';
  END IF;

  v_since := (timezone('UTC', now()))::date - (v_days - 1);

  SELECT jsonb_build_object(
    'days', v_days,
    'generated_at', clock_timestamp(),
    'kpis', jsonb_build_object(
      'active_webpages', (
        SELECT count(DISTINCT s.listing_id)
        FROM public.ad_subscriptions s
        JOIN public.ad_packages p ON p.id = s.package_id
        WHERE s.user_id = v_uid
          AND s.status = 'active'
          AND (s.expires_at IS NULL OR s.expires_at > now())
          AND p.product_type = 'webpage'
          AND p.webpage_enabled = true
      ),
      'live_campaigns', (
        SELECT count(*)
        FROM public.advertisements a
        WHERE a.user_id = v_uid
          AND a.status = 'active'
          AND a.starts_at <= now()
          AND a.expires_at > now()
      ),
      'impressions', coalesce(events.impressions, 0),
      'clicks', coalesce(events.clicks, 0),
      'leads', coalesce(events.leads, 0),
      'ctr', CASE
        WHEN coalesce(events.impressions, 0) = 0 THEN 0
        ELSE round(100.0 * events.clicks / events.impressions, 2)
      END
    ),
    'advertisements', coalesce(rows.advertisements, '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      count(e.id) FILTER (WHERE e.event_type IN ('impression', 'view')) AS impressions,
      count(e.id) FILTER (WHERE e.event_type = 'click') AS clicks,
      count(e.id) FILTER (WHERE e.event_type IN ('lead', 'call', 'chat', 'booking')) AS leads
    FROM public.advertisements a
    LEFT JOIN public.ad_events e
      ON e.advertisement_id = a.id
     AND e.occurred_on >= v_since
    WHERE a.user_id = v_uid
  ) events
  CROSS JOIN LATERAL (
    SELECT jsonb_agg(row_data ORDER BY (row_data->>'starts_at') DESC) AS advertisements
    FROM (
      SELECT jsonb_build_object(
        'advertisement_id', a.id,
        'order_id', a.order_id,
        'order_number', o.order_number,
        'package_name', p.name,
        'product_type', p.product_type,
        'placement', a.placement,
        'format', coalesce(a.creative_metadata->>'format', 'native'),
        'status', a.status,
        'headline', a.headline,
        'listing_id', a.listing_id,
        'business_name', l.business_name,
        'starts_at', a.starts_at,
        'expires_at', a.expires_at,
        'impressions', coalesce(ev.impressions, 0),
        'clicks', coalesce(ev.clicks, 0),
        'leads', coalesce(ev.leads, 0),
        'ctr', CASE
          WHEN coalesce(ev.impressions, 0) = 0 THEN 0
          ELSE round(100.0 * ev.clicks / ev.impressions, 2)
        END
      ) AS row_data
      FROM public.advertisements a
      JOIN public.ad_packages p ON p.id = a.package_id
      LEFT JOIN public.ad_orders o ON o.id = a.order_id
      LEFT JOIN public.listings l ON l.id = a.listing_id
      LEFT JOIN LATERAL (
        SELECT
          count(*) FILTER (WHERE e.event_type IN ('impression', 'view')) AS impressions,
          count(*) FILTER (WHERE e.event_type = 'click') AS clicks,
          count(*) FILTER (WHERE e.event_type IN ('lead', 'call', 'chat', 'booking')) AS leads
        FROM public.ad_events e
        WHERE e.advertisement_id = a.id
          AND e.occurred_on >= v_since
      ) ev ON true
      WHERE a.user_id = v_uid
    ) ranked
  ) rows;

  RETURN v_result;
END;
$$;

-- Admin campaign rows include their delivery totals instead of requiring the
-- frontend to infer nonexistent columns from the raw advertisements table.
CREATE OR REPLACE FUNCTION public.get_admin_advertisement_delivery(
  p_days integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_days integer := greatest(1, least(coalesce(p_days, 30), 3650));
  v_since date := (timezone('UTC', now()))::date - (v_days - 1);
  v_result jsonb;
BEGIN
  PERFORM private.require_admin(auth.uid());

  SELECT jsonb_build_object(
    'days', v_days,
    'advertisements', coalesce(jsonb_agg(to_jsonb(rows) ORDER BY rows.created_at DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      a.*,
      p.name AS package_name,
      p.product_type,
      l.business_name,
      coalesce(ev.impressions, 0) AS impressions,
      coalesce(ev.clicks, 0) AS clicks,
      coalesce(ev.leads, 0) AS leads,
      CASE
        WHEN coalesce(ev.impressions, 0) = 0 THEN 0
        ELSE round(100.0 * ev.clicks / ev.impressions, 2)
      END AS ctr
    FROM public.advertisements a
    JOIN public.ad_packages p ON p.id = a.package_id
    LEFT JOIN public.listings l ON l.id = a.listing_id
    LEFT JOIN LATERAL (
      SELECT
        count(*) FILTER (WHERE e.event_type IN ('impression', 'view')) AS impressions,
        count(*) FILTER (WHERE e.event_type = 'click') AS clicks,
        count(*) FILTER (WHERE e.event_type IN ('lead', 'call', 'chat', 'booking')) AS leads
      FROM public.ad_events e
      WHERE e.advertisement_id = a.id
        AND e.occurred_on >= v_since
    ) ev ON true
  ) rows;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_active_advertisements(text, integer)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_webpage_event(uuid, text, text, jsonb)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_my_ad_performance(integer)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_admin_advertisement_delivery(integer)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_active_advertisements(text, integer)
TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_webpage_event(uuid, text, text, jsonb)
TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_ad_performance(integer)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_advertisement_delivery(integer)
TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Upgrade blank legacy drafts, then synchronize all current entitlements.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_previous_claims text := current_setting('request.jwt.claims', true);
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);

  UPDATE public.listing_webpages w
  SET
    tier = lower(p.webpage_tier),
    market_segment = coalesce(l.market_segment, 'local-business'),
    page_status = CASE WHEN l.status = 'approved' THEN 'published' ELSE 'draft' END,
    tagline = left(nullif(trim(coalesce(l.description, '')), ''), 140),
    logo_url = nullif(trim(coalesce(l.image_url, '')), ''),
    address = nullif(trim(coalesce(l.location, '')), ''),
    about_text = nullif(trim(coalesce(l.description, '')), ''),
    gallery_urls = CASE
      WHEN nullif(trim(coalesce(l.image_url, '')), '') IS NULL THEN '{}'::text[]
      ELSE ARRAY[l.image_url]
    END,
    starter_generated = true,
    updated_at = clock_timestamp()
  FROM public.listings l
  JOIN LATERAL (
    SELECT s.package_id
    FROM public.ad_subscriptions s
    JOIN public.ad_packages sp ON sp.id = s.package_id
    WHERE s.listing_id = l.id
      AND s.user_id = l.owner_user_id
      AND s.status = 'active'
      AND (s.expires_at IS NULL OR s.expires_at > now())
      AND sp.product_type = 'webpage'
      AND sp.webpage_enabled = true
    ORDER BY private.ajm_tier_rank(sp.webpage_tier) DESC, s.created_at DESC
    LIMIT 1
  ) active_subscription ON true
  JOIN public.ad_packages p ON p.id = active_subscription.package_id
  WHERE w.listing_id = l.id
    AND w.page_status = 'draft'
    AND nullif(trim(coalesce(w.tagline, '')), '') IS NULL
    AND nullif(trim(coalesce(w.logo_url, '')), '') IS NULL
    AND nullif(trim(coalesce(w.address, '')), '') IS NULL
    AND nullif(trim(coalesce(w.about_text, '')), '') IS NULL
    AND coalesce(array_length(w.gallery_urls, 1), 0) = 0;

  PERFORM private.sync_listing_webpage_promotion(w.listing_id)
  FROM public.listing_webpages w;

  PERFORM set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
  RAISE;
END;
$$;
