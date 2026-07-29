-- Keep a paid webpage's tier and market segment aligned with its active
-- subscription and parent listing without silently destroying published work.
--
-- Manual activation creates the subscription (and therefore its starter page)
-- before it writes the administrator-selected market segment to the listing.
-- Without this synchronization the starter page can retain the listing's old
-- segment. Editable drafts are reconciled to the exact paid tier and unsupported
-- fields are removed on downgrade. If an incompatible change reaches a
-- published page, the page is explicitly returned to draft review while its
-- tier, segment and content remain intact.

-- A payment destination may be saved as an inactive draft, but it must contain
-- enough information to complete a transfer before it can be activated. Any
-- incomplete legacy rows are safely archived instead of blocking deployment.
UPDATE public.payment_accounts
SET
  is_active = false,
  is_default = false,
  updated_at = clock_timestamp()
WHERE is_active = true
  AND (
    nullif(trim(bank_name), '') IS NULL
    OR nullif(trim(account_name), '') IS NULL
    OR nullif(trim(account_number), '') IS NULL
    OR nullif(trim(instructions), '') IS NULL
  );

ALTER TABLE public.payment_accounts
DROP CONSTRAINT IF EXISTS payment_accounts_active_details_check;

ALTER TABLE public.payment_accounts
ADD CONSTRAINT payment_accounts_active_details_check
CHECK (
  (
    NOT is_active
    OR (
      nullif(trim(bank_name), '') IS NOT NULL
      AND nullif(trim(account_name), '') IS NOT NULL
      AND nullif(trim(account_number), '') IS NOT NULL
      AND nullif(trim(instructions), '') IS NOT NULL
    )
  )
  AND (NOT is_default OR is_active)
);

CREATE OR REPLACE FUNCTION private.reconcile_listing_webpage_draft(
  p_listing_id uuid,
  p_tier text,
  p_market_segment text,
  p_created_by uuid DEFAULT NULL,
  p_reason text DEFAULT 'subscription_activation'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tier text := lower(trim(coalesce(p_tier, '')));
  v_before public.listing_webpages%ROWTYPE;
  v_after public.listing_webpages%ROWTYPE;
BEGIN
  IF v_tier NOT IN ('silver', 'gold', 'platinum') THEN
    RAISE EXCEPTION 'A valid webpage tier is required for reconciliation.';
  END IF;
  IF p_market_segment NOT IN (
    'local-business', 'professional-services', 'b2b-supplier',
    'hospitality-events', 'automotive-collectibles'
  ) THEN
    RAISE EXCEPTION 'A valid market segment is required for reconciliation.';
  END IF;

  SELECT * INTO v_before
  FROM public.listing_webpages
  WHERE listing_id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.listing_webpages (
      listing_id,
      tier,
      market_segment,
      page_status,
      created_by
    ) VALUES (
      p_listing_id,
      v_tier,
      p_market_segment,
      'draft',
      p_created_by
    )
    ON CONFLICT (listing_id) DO NOTHING;

    IF FOUND THEN
      RETURN 'created';
    END IF;

    SELECT * INTO v_before
    FROM public.listing_webpages
    WHERE listing_id = p_listing_id
    FOR UPDATE;
  END IF;

  IF v_before.page_status = 'published'
     AND (
       v_before.tier IS DISTINCT FROM v_tier
       OR v_before.market_segment IS DISTINCT FROM p_market_segment
     ) THEN
    -- Publishing is a deliberate act. Do not silently truncate galleries,
    -- remove paid features, or clear segment content on a live page. Taking the
    -- page back to draft makes the package conflict explicit while preserving
    -- every authored field for an administrator to review.
    UPDATE public.listing_webpages
    SET page_status = 'draft'
    WHERE listing_id = p_listing_id
    RETURNING * INTO v_after;

    PERFORM private.audit_advertising_change(
      auth.uid(),
      'listing_webpage',
      p_listing_id::text,
      'listing_webpage_unpublished_for_package_review',
      to_jsonb(v_before),
      to_jsonb(v_after) || jsonb_build_object(
        'requested_tier', v_tier,
        'requested_market_segment', p_market_segment,
        'reconciliation_reason', p_reason
      )
    );
    RETURN 'unpublished_for_review';
  END IF;

  IF v_before.page_status <> 'draft'
     OR (
       v_before.tier IS NOT DISTINCT FROM v_tier
       AND v_before.market_segment IS NOT DISTINCT FROM p_market_segment
     ) THEN
    RETURN 'unchanged';
  END IF;

  -- Drafts follow the exact active package, including downgrades. Truncating
  -- and clearing below prevents a lower-tier page from retaining fields that
  -- its package cannot display. The complete before-state is retained in the
  -- administrator audit log for traceability.
  UPDATE public.listing_webpages
  SET
    tier = v_tier,
    market_segment = p_market_segment,
    segment_content = CASE
      WHEN market_segment IS DISTINCT FROM p_market_segment THEN '{}'::jsonb
      ELSE segment_content
    END,
    gallery_urls = CASE v_tier
      WHEN 'silver' THEN coalesce(gallery_urls[1:3], '{}'::text[])
      WHEN 'gold' THEN coalesce(gallery_urls[1:12], '{}'::text[])
      ELSE coalesce(gallery_urls[1:24], '{}'::text[])
    END,
    hero_media_url = CASE WHEN v_tier = 'silver' THEN NULL ELSE hero_media_url END,
    video_url = CASE WHEN v_tier = 'silver' THEN NULL ELSE video_url END,
    map_embed_url = CASE WHEN v_tier = 'silver' THEN NULL ELSE map_embed_url END,
    offer_title = CASE WHEN v_tier = 'silver' THEN NULL ELSE offer_title END,
    offer_details = CASE WHEN v_tier = 'silver' THEN NULL ELSE offer_details END,
    offer_code = CASE WHEN v_tier = 'silver' THEN NULL ELSE offer_code END,
    testimonials = CASE WHEN v_tier = 'silver' THEN '[]'::jsonb ELSE testimonials END,
    lead_form_enabled = CASE WHEN v_tier = 'silver' THEN false ELSE lead_form_enabled END,
    booking_url = CASE WHEN v_tier = 'platinum' THEN booking_url ELSE NULL END,
    virtual_tour_url = CASE WHEN v_tier = 'platinum' THEN virtual_tour_url ELSE NULL END,
    call_tracking_phone = CASE WHEN v_tier = 'platinum' THEN call_tracking_phone ELSE NULL END,
    live_chat_url = CASE WHEN v_tier = 'platinum' THEN live_chat_url ELSE NULL END,
    created_by = coalesce(created_by, p_created_by),
    updated_at = clock_timestamp()
  WHERE listing_id = p_listing_id
  RETURNING * INTO v_after;

  PERFORM private.audit_advertising_change(
    auth.uid(),
    'listing_webpage',
    p_listing_id::text,
    'listing_webpage_draft_reconciled',
    to_jsonb(v_before),
    to_jsonb(v_after) || jsonb_build_object('reconciliation_reason', p_reason)
  );
  RETURN 'reconciled';
END;
$$;

REVOKE ALL ON FUNCTION private.reconcile_listing_webpage_draft(
  uuid, text, text, uuid, text
) FROM PUBLIC, anon, authenticated;

-- Replace the earlier upgrade-only starter trigger. Reactivating or switching
-- packages now reconciles an existing draft to the exact active tier.
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
BEGIN
  IF NEW.status IS DISTINCT FROM 'active'
     OR NEW.listing_id IS NULL
     OR NEW.package_id IS NULL
     OR NEW.user_id IS NULL THEN
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

  IF FOUND THEN
    PERFORM private.reconcile_listing_webpage_draft(
      NEW.listing_id,
      v_tier,
      v_market_segment,
      v_created_by,
      'active_subscription'
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.ensure_active_webpage_draft()
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.sync_listing_webpage_market_segment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_page_tier text;
  v_page_status text;
  v_active_tier text;
  v_created_by uuid;
BEGIN
  IF NEW.market_segment IS NULL
     OR NEW.market_segment IS NOT DISTINCT FROM OLD.market_segment THEN
    RETURN NEW;
  END IF;

  SELECT tier, page_status
  INTO v_page_tier, v_page_status
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

  -- A package switch may just have unpublished an incompatible live page. Its
  -- old tier is the preservation marker; do not immediately treat that page as
  -- a disposable draft and erase the content in this second trigger.
  IF v_page_status = 'draft' AND v_page_tier IS DISTINCT FROM v_active_tier THEN
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

DROP TRIGGER IF EXISTS trg_sync_listing_webpage_market_segment
ON public.listings;

CREATE TRIGGER trg_sync_listing_webpage_market_segment
AFTER UPDATE OF market_segment ON public.listings
FOR EACH ROW
WHEN (OLD.market_segment IS DISTINCT FROM NEW.market_segment)
EXECUTE FUNCTION private.sync_listing_webpage_market_segment();

REVOKE ALL ON FUNCTION private.sync_listing_webpage_market_segment()
FROM PUBLIC, anon, authenticated;

-- Reconcile drafts created during the short interval between the activation
-- deployment and this follow-up. Published conflicts are only unpublished for
-- review; their authored data remains untouched. The service-role claim is
-- transaction-local and restored.
DO $$
DECLARE
  v_previous_claims text := current_setting('request.jwt.claims', true);
  v_subscription record;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);

  FOR v_subscription IN
    SELECT DISTINCT ON (s.listing_id)
      s.listing_id,
      lower(p.webpage_tier) AS tier,
      l.market_segment,
      CASE WHEN pr.id IS NOT NULL THEN s.user_id ELSE NULL END AS created_by
    FROM public.ad_subscriptions s
    JOIN public.ad_packages p
      ON p.id = s.package_id
     AND p.is_active = true
     AND p.webpage_enabled = true
     AND lower(p.webpage_tier) IN ('silver', 'gold', 'platinum')
    JOIN public.listings l
      ON l.id = s.listing_id
     AND l.owner_user_id = s.user_id
    LEFT JOIN public.profiles pr ON pr.id = s.user_id
    WHERE s.status = 'active'
      AND (s.expires_at IS NULL OR s.expires_at > now())
      AND l.market_segment IS NOT NULL
    ORDER BY s.listing_id, s.created_at DESC NULLS LAST, s.id DESC
  LOOP
    PERFORM private.reconcile_listing_webpage_draft(
      v_subscription.listing_id,
      v_subscription.tier,
      v_subscription.market_segment,
      v_subscription.created_by,
      'migration_backfill'
    );
  END LOOP;

  PERFORM set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
  RAISE;
END;
$$;
