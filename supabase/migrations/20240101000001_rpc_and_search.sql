-- ============================================
-- RPC AND SEARCH FUNCTIONS MIGRATION
-- ============================================

-- 1. Search Public Listings RPC
CREATE OR REPLACE FUNCTION public.search_public_listings(
    p_query text DEFAULT NULL,
    p_parish text DEFAULT NULL,
    p_location_text text DEFAULT NULL,
    p_group_slug text DEFAULT NULL,
    p_category_slug text DEFAULT NULL,
    p_limit integer DEFAULT 50,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    id uuid,
    business_name text,
    slug text,
    description text,
    category_group_name text,
    category_option_name text,
    parish text,
    location_display text,
    contact_phone text,
    email text,
    website text,
    is_featured boolean,
    published_at timestamptz,
    total_count bigint
) AS $$
DECLARE
    v_group_id bigint;
    v_category_id bigint;
    v_tsquery tsquery;
BEGIN
    -- Resolve taxonomy IDs if slugs are provided
    IF p_group_slug IS NOT NULL THEN
        SELECT cg.id INTO v_group_id FROM public.category_groups cg WHERE cg.slug = p_group_slug AND cg.is_active = true;
    END IF;

    IF p_category_slug IS NOT NULL AND v_group_id IS NOT NULL THEN
        SELECT co.id INTO v_category_id FROM public.category_options co WHERE co.slug = p_category_slug AND co.group_id = v_group_id AND co.is_active = true;
    END IF;

    -- Prepare tsquery for text search
    IF p_query IS NOT NULL AND p_query != '' THEN
        v_tsquery := websearch_to_tsquery('english', p_query);
    END IF;

    RETURN QUERY
    WITH filtered_listings AS (
        SELECT l.*, count(*) OVER() as _total_count
        FROM public.listings l
        WHERE l.status = 'approved'
          AND (l.published_at IS NULL OR l.published_at <= now())
          AND (l.expires_at IS NULL OR l.expires_at > now())
          AND (v_group_id IS NULL OR l.category_group_id = v_group_id)
          AND (v_category_id IS NULL OR l.category_option_id = v_category_id)
          AND (p_parish IS NULL OR p_parish = '' OR l.parish = p_parish)
          AND (p_location_text IS NULL OR p_location_text = '' OR l.location_display ILIKE '%' || p_location_text || '%')
          AND (
              v_tsquery IS NULL
              OR l.search_document @@ v_tsquery
              OR l.business_name ILIKE '%' || p_query || '%'
          )
    )
    SELECT 
        fl.id,
        fl.business_name,
        fl.slug,
        fl.description,
        cg.name as category_group_name,
        co.name as category_option_name,
        fl.parish,
        fl.location_display,
        fl.contact_phone,
        fl.email,
        fl.website,
        fl.is_featured,
        fl.published_at,
        fl._total_count
    FROM filtered_listings fl
    LEFT JOIN public.category_groups cg ON fl.category_group_id = cg.id
    LEFT JOIN public.category_options co ON fl.category_option_id = co.id
    ORDER BY 
        fl.is_featured DESC,
        (CASE WHEN v_tsquery IS NOT NULL THEN ts_rank(fl.search_document, v_tsquery) ELSE 0 END) DESC,
        fl.published_at DESC,
        fl.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '';

-- 2. Get Public Listing Detail
CREATE OR REPLACE FUNCTION public.get_public_listing_detail(p_slug text)
RETURNS TABLE (
    id uuid,
    business_name text,
    slug text,
    description text,
    category_group_name text,
    category_option_name text,
    parish text,
    location_display text,
    contact_phone text,
    whatsapp text,
    email text,
    website text,
    is_featured boolean,
    published_at timestamptz
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        l.id, l.business_name, l.slug, l.description, cg.name, co.name, l.parish, l.location_display,
        l.contact_phone, l.whatsapp, l.email, l.website, l.is_featured, l.published_at
    FROM public.listings l
    LEFT JOIN public.category_groups cg ON l.category_group_id = cg.id
    LEFT JOIN public.category_options co ON l.category_option_id = co.id
    WHERE l.slug = p_slug
      AND l.status = 'approved'
      AND (l.expires_at IS NULL OR l.expires_at > now())
      AND (l.published_at IS NULL OR l.published_at <= now());
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '';

-- 3. Get My Listings
CREATE OR REPLACE FUNCTION public.get_my_listings(
    p_status text DEFAULT NULL,
    p_limit integer DEFAULT 50,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    id uuid,
    business_name text,
    status text,
    created_at timestamptz,
    total_count bigint
) AS $$
BEGIN
    RETURN QUERY
    WITH user_listings AS (
        SELECT l.id, l.business_name, l.status, l.created_at, count(*) OVER() as _total_count
        FROM public.listings l
        WHERE l.owner_user_id = (SELECT auth.uid())
          AND (p_status IS NULL OR l.status = p_status)
    )
    SELECT * FROM user_listings
    ORDER BY created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '';

-- 4. Get My Membership State
CREATE OR REPLACE FUNCTION public.get_my_membership_state()
RETURNS json AS $$
DECLARE
    v_role text;
    v_has_active boolean;
BEGIN
    SELECT role INTO v_role FROM public.profiles WHERE id = (SELECT auth.uid());
    
    v_has_active := private.has_active_membership((SELECT auth.uid()));

    RETURN json_build_object(
        'role', v_role,
        'has_active_membership', v_has_active
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '';

-- Apply grants safely
GRANT EXECUTE ON FUNCTION public.search_public_listings(text, text, text, text, text, integer, integer) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_public_listing_detail(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_my_listings(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_membership_state() TO authenticated;
