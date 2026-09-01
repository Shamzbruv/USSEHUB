-- A starter-generated webpage was using the listing's small logo/promo-card
-- graphic as its hero banner image. The hero is a full-width, ~680px-tall
-- section rendered with object-fit:cover, so a small low-resolution graphic
-- (a business's logo card is typically a few hundred pixels wide) gets
-- cropped to a fraction of itself and scaled up hugely — reported by a real
-- client as the page appearing "several times zoomed in". The logo already
-- displays correctly, small, via object-fit:contain in its own card; a
-- starter page should not also promote that same image to hero/gallery
-- duty. Leaving no hero image falls back to the template's neutral gradient
-- background, which reads as intentional rather than broken.

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
    -- A starter page has, at most, the listing's own logo/promo graphic —
    -- never a dedicated wide photo. It is shown correctly (small, contained)
    -- as the logo; it must not also be seeded into the gallery, where the
    -- hero banner would otherwise pick it up and crop/scale it into an
    -- oversized, distorted mess.
    gallery_urls = CASE WHEN v_is_blank THEN '{}'::text[] ELSE gallery_urls END,
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

-- One-time cleanup: any starter-generated page already created by the prior
-- version of this trigger (e.g. Squaddy Barber Services) had its logo
-- duplicated into gallery_urls. Only touch rows the system generated and
-- only when the gallery is nothing but that same duplicate — an owner's own
-- deliberate gallery choice via the builder is never modified. This runs as
-- service_role so validate_ajm_listing_webpage()'s ownership check (correctly
-- meant to stop an ordinary session from editing someone else's page) does
-- not also block this administrative backfill.
DO $$
DECLARE
  v_previous_claims text := current_setting('request.jwt.claims', true);
  v_listing_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);

  UPDATE public.listing_webpages
  SET gallery_urls = '{}'::text[]
  WHERE starter_generated = true
    AND gallery_urls = ARRAY[logo_url];

  -- Re-sync each affected listing's network promotion so its
  -- creative_metadata (media_url) reflects the corrected page state at once.
  FOR v_listing_id IN
    SELECT listing_id FROM public.listing_webpages WHERE starter_generated = true
  LOOP
    PERFORM private.sync_listing_webpage_promotion(v_listing_id);
  END LOOP;

  PERFORM set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
  RAISE;
END $$;
