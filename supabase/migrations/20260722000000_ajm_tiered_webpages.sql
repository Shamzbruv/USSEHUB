-- AJM paid mini-webpages: Silver, Gold and Platinum
-- The directory remains available to free members. A published mini-webpage
-- requires an active listing-specific ad subscription or an administrator.

ALTER TABLE public.ad_packages
ADD COLUMN IF NOT EXISTS code text,
ADD COLUMN IF NOT EXISTS webpage_enabled boolean NOT NULL DEFAULT false,
ADD COLUMN IF NOT EXISTS webpage_tier text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'ad_packages_code_key'
      AND conrelid = 'public.ad_packages'::regclass
  ) THEN
    ALTER TABLE public.ad_packages
    ADD CONSTRAINT ad_packages_code_key UNIQUE (code);
  END IF;
END $$;

ALTER TABLE public.ad_packages
DROP CONSTRAINT IF EXISTS ad_packages_webpage_tier_check;

ALTER TABLE public.ad_packages
ADD CONSTRAINT ad_packages_webpage_tier_check
CHECK (webpage_tier IS NULL OR webpage_tier IN ('silver', 'gold', 'platinum'));

ALTER TABLE public.listings
ADD COLUMN IF NOT EXISTS market_segment text;

ALTER TABLE public.listings
DROP CONSTRAINT IF EXISTS listings_market_segment_check;

ALTER TABLE public.listings
ADD CONSTRAINT listings_market_segment_check
CHECK (
  market_segment IS NULL OR market_segment IN (
    'local-business',
    'professional-services',
    'b2b-supplier',
    'hospitality-events',
    'automotive-collectibles'
  )
);

ALTER TABLE public.listings
DROP CONSTRAINT IF EXISTS listings_requested_tier_check;

UPDATE public.listings
SET requested_tier = NULL
WHERE requested_tier IS NOT NULL
  AND lower(requested_tier) NOT IN ('silver', 'gold', 'platinum');

UPDATE public.listings
SET requested_tier = lower(requested_tier)
WHERE requested_tier IS NOT NULL;

ALTER TABLE public.listings
ADD CONSTRAINT listings_requested_tier_check
CHECK (requested_tier IS NULL OR requested_tier IN ('silver', 'gold', 'platinum'));

CREATE TABLE IF NOT EXISTS public.listing_webpages (
  listing_id uuid PRIMARY KEY REFERENCES public.listings(id) ON DELETE CASCADE,
  tier text NOT NULL CHECK (tier IN ('silver', 'gold', 'platinum')),
  market_segment text NOT NULL CHECK (
    market_segment IN (
      'local-business',
      'professional-services',
      'b2b-supplier',
      'hospitality-events',
      'automotive-collectibles'
    )
  ),
  page_status text NOT NULL DEFAULT 'draft' CHECK (page_status IN ('draft', 'published')),
  tagline text,
  logo_url text,
  address text,
  about_text text,
  business_hours jsonb NOT NULL DEFAULT '{}'::jsonb,
  gallery_urls text[] NOT NULL DEFAULT '{}'::text[],
  hero_media_url text,
  video_url text,
  map_embed_url text,
  offer_title text,
  offer_details text,
  offer_code text,
  testimonials jsonb NOT NULL DEFAULT '[]'::jsonb,
  lead_form_enabled boolean NOT NULL DEFAULT false,
  booking_url text,
  virtual_tour_url text,
  call_tracking_phone text,
  live_chat_url text,
  created_by uuid REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz
);

ALTER TABLE public.listing_webpages
DROP CONSTRAINT IF EXISTS listing_webpages_content_shape_check;

ALTER TABLE public.listing_webpages
ADD CONSTRAINT listing_webpages_content_shape_check
CHECK (
  jsonb_typeof(business_hours) = 'object'
  AND jsonb_typeof(testimonials) = 'array'
);

CREATE INDEX IF NOT EXISTS idx_listing_webpages_status_tier
ON public.listing_webpages (page_status, tier);

CREATE OR REPLACE FUNCTION private.ajm_tier_rank(p_tier text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_tier, ''))
    WHEN 'silver' THEN 1
    WHEN 'gold' THEN 2
    WHEN 'platinum' THEN 3
    ELSE 0
  END;
$$;

CREATE OR REPLACE FUNCTION private.can_manage_listing_webpage(
  p_listing_id uuid,
  p_tier text,
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
    OR (
      EXISTS (
        SELECT 1
        FROM public.listings l
        WHERE l.id = p_listing_id
          AND l.owner_user_id = p_uid
      )
      AND EXISTS (
        SELECT 1
        FROM public.ad_subscriptions s
        JOIN public.ad_packages p ON p.id = s.package_id
        WHERE s.user_id = p_uid
          AND s.listing_id = p_listing_id
          AND s.status = 'active'
          AND (s.expires_at IS NULL OR s.expires_at > now())
          AND p.is_active = true
          AND p.webpage_enabled = true
          AND private.ajm_tier_rank(p.webpage_tier) >= private.ajm_tier_rank(p_tier)
      )
    );
$$;

CREATE OR REPLACE FUNCTION private.has_active_listing_webpage_subscription(
  p_listing_id uuid,
  p_tier text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.ad_subscriptions s
    JOIN public.ad_packages p ON p.id = s.package_id
    JOIN public.listings l ON l.id = s.listing_id AND l.owner_user_id = s.user_id
    WHERE s.listing_id = p_listing_id
      AND s.status = 'active'
      AND (s.expires_at IS NULL OR s.expires_at > now())
      AND p.is_active = true
      AND p.webpage_enabled = true
      AND private.ajm_tier_rank(p.webpage_tier) >= private.ajm_tier_rank(p_tier)
  );
$$;

CREATE OR REPLACE FUNCTION public.validate_ajm_listing_webpage()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_is_service_role boolean;
  v_gallery_count integer;
BEGIN
  v_is_service_role := coalesce(
    coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb->>'role' = 'service_role',
    false
  );

  IF NOT v_is_service_role
     AND NOT private.can_manage_listing_webpage(NEW.listing_id, NEW.tier, auth.uid()) THEN
    RAISE EXCEPTION 'An active % webpage subscription is required for this listing.', NEW.tier;
  END IF;

  v_gallery_count := coalesce(array_length(NEW.gallery_urls, 1), 0);

  IF NEW.tier = 'silver' AND v_gallery_count > 3 THEN
    RAISE EXCEPTION 'Silver webpages support up to 3 gallery images.';
  ELSIF NEW.tier = 'gold' AND v_gallery_count > 12 THEN
    RAISE EXCEPTION 'Gold webpages support up to 12 gallery images.';
  ELSIF NEW.tier = 'platinum' AND v_gallery_count > 24 THEN
    RAISE EXCEPTION 'Platinum webpages support up to 24 gallery images.';
  END IF;

  IF NEW.tier = 'silver' AND (
    nullif(NEW.hero_media_url, '') IS NOT NULL
    OR nullif(NEW.video_url, '') IS NOT NULL
    OR nullif(NEW.map_embed_url, '') IS NOT NULL
    OR nullif(NEW.offer_title, '') IS NOT NULL
    OR NEW.lead_form_enabled
    OR jsonb_array_length(NEW.testimonials) > 0
    OR nullif(NEW.booking_url, '') IS NOT NULL
    OR nullif(NEW.virtual_tour_url, '') IS NOT NULL
    OR nullif(NEW.call_tracking_phone, '') IS NOT NULL
    OR nullif(NEW.live_chat_url, '') IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'One or more selected features require a Gold or Platinum webpage.';
  END IF;

  IF NEW.tier = 'gold' AND (
    nullif(NEW.booking_url, '') IS NOT NULL
    OR nullif(NEW.virtual_tour_url, '') IS NOT NULL
    OR nullif(NEW.call_tracking_phone, '') IS NOT NULL
    OR nullif(NEW.live_chat_url, '') IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Booking, virtual tour, tracked call and live chat require Platinum.';
  END IF;

  NEW.updated_at := now();
  IF NEW.created_by IS NULL THEN
    NEW.created_by := auth.uid();
  END IF;

  IF NEW.page_status = 'published' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.published_at := now();
    ELSIF OLD.page_status <> 'published' THEN
      NEW.published_at := now();
    END IF;
  ELSIF NEW.page_status = 'draft' THEN
    NEW.published_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_ajm_listing_webpage ON public.listing_webpages;
CREATE TRIGGER trg_validate_ajm_listing_webpage
BEFORE INSERT OR UPDATE ON public.listing_webpages
FOR EACH ROW EXECUTE FUNCTION public.validate_ajm_listing_webpage();

ALTER TABLE public.listing_webpages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Published AJM webpages are public" ON public.listing_webpages;
CREATE POLICY "Published AJM webpages are public"
ON public.listing_webpages FOR SELECT
USING (
  (
    page_status = 'published'
    AND EXISTS (
      SELECT 1
      FROM public.listings l
      WHERE l.id = listing_id
        AND l.status = 'approved'
        AND (l.expires_at IS NULL OR l.expires_at > now())
        AND (l.published_at IS NULL OR l.published_at <= now())
    )
    AND private.has_active_listing_webpage_subscription(listing_id, tier)
  )
  OR EXISTS (
    SELECT 1 FROM public.listings l
    WHERE l.id = listing_id AND l.owner_user_id = auth.uid()
  )
  OR private.is_admin(auth.uid())
);

DROP POLICY IF EXISTS "Paid owners create AJM webpages" ON public.listing_webpages;
CREATE POLICY "Paid owners create AJM webpages"
ON public.listing_webpages FOR INSERT
WITH CHECK (private.can_manage_listing_webpage(listing_id, tier, auth.uid()));

DROP POLICY IF EXISTS "Paid owners update AJM webpages" ON public.listing_webpages;
CREATE POLICY "Paid owners update AJM webpages"
ON public.listing_webpages FOR UPDATE
USING (private.can_manage_listing_webpage(listing_id, tier, auth.uid()))
WITH CHECK (private.can_manage_listing_webpage(listing_id, tier, auth.uid()));

DROP POLICY IF EXISTS "Admins delete AJM webpages" ON public.listing_webpages;
CREATE POLICY "Admins delete AJM webpages"
ON public.listing_webpages FOR DELETE
USING (private.is_admin(auth.uid()));

GRANT SELECT ON public.listing_webpages TO anon, authenticated;
GRANT INSERT, UPDATE ON public.listing_webpages TO authenticated;
GRANT DELETE ON public.listing_webpages TO authenticated;

INSERT INTO public.ad_packages (
  code,
  name,
  price,
  duration_days,
  features,
  is_active,
  webpage_enabled,
  webpage_tier
)
VALUES
  (
    'ajm-webpage-silver',
    'AJM Silver Webpage',
    NULL,
    30,
    '["Business profile", "Contact and address", "About section", "Business hours", "Up to 3 photos"]'::jsonb,
    true,
    true,
    'silver'
  ),
  (
    'ajm-webpage-gold',
    'AJM Gold Webpage',
    NULL,
    30,
    '["Everything in Silver", "Hero and video gallery", "Google Map", "Reviews", "Lead form", "Offers and coupons"]'::jsonb,
    true,
    true,
    'gold'
  ),
  (
    'ajm-webpage-platinum',
    'AJM Platinum Webpage',
    NULL,
    30,
    '["Everything in Gold", "Cinematic cover", "Virtual tour", "Booking", "Featured testimonials", "Tracked calls", "Live chat"]'::jsonb,
    true,
    true,
    'platinum'
  )
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  duration_days = EXCLUDED.duration_days,
  features = EXCLUDED.features,
  is_active = EXCLUDED.is_active,
  webpage_enabled = EXCLUDED.webpage_enabled,
  webpage_tier = EXCLUDED.webpage_tier;
