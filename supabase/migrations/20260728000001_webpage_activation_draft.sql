-- Ensure an activated paid webpage has an editable draft immediately.
-- The subscription remains the source of truth for access and publication;
-- this trigger only creates a missing starter row and never overwrites content.

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

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.listing_webpages (
    listing_id,
    tier,
    market_segment,
    page_status,
    created_by
  ) VALUES (
    NEW.listing_id,
    v_tier,
    v_market_segment,
    'draft',
    v_created_by
  )
  ON CONFLICT (listing_id) DO UPDATE
  SET tier = EXCLUDED.tier
  WHERE private.ajm_tier_rank(EXCLUDED.tier)
      > private.ajm_tier_rank(listing_webpages.tier);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ensure_active_webpage_draft
ON public.ad_subscriptions;

CREATE TRIGGER trg_ensure_active_webpage_draft
AFTER INSERT OR UPDATE OF status, package_id, listing_id, user_id
ON public.ad_subscriptions
FOR EACH ROW
EXECUTE FUNCTION private.ensure_active_webpage_draft();

REVOKE ALL ON FUNCTION private.ensure_active_webpage_draft()
FROM PUBLIC, anon, authenticated;

-- Backfill only subscriptions that were already active before this trigger was
-- installed. The service-role claim is transaction-local and restored even if
-- the backfill fails, allowing the existing webpage validation trigger to run
-- without granting callers a bypass.
DO $$
DECLARE
  v_previous_claims text := current_setting('request.jwt.claims', true);
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);

  INSERT INTO public.listing_webpages (
    listing_id,
    tier,
    market_segment,
    page_status,
    created_by
  )
  SELECT DISTINCT ON (s.listing_id)
    s.listing_id,
    lower(p.webpage_tier),
    coalesce(l.market_segment, 'local-business'),
    'draft',
    CASE WHEN pr.id IS NOT NULL THEN s.user_id ELSE NULL END
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
  ORDER BY
    s.listing_id,
    private.ajm_tier_rank(p.webpage_tier) DESC,
    s.created_at DESC NULLS LAST
  ON CONFLICT (listing_id) DO UPDATE
  SET tier = EXCLUDED.tier
  WHERE private.ajm_tier_rank(EXCLUDED.tier)
      > private.ajm_tier_rank(listing_webpages.tier);

  PERFORM set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', coalesce(v_previous_claims, ''), true);
  RAISE;
END;
$$;
