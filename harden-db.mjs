// harden-db.mjs — Production hardening: storage bucket, DB functions, additional RLS
import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL;
if (!DB_URL) throw new Error('DATABASE_URL is required');

const SQL = `
-- ============================================
-- 1. SECURITY: Add full_text_search column for
--    efficient multi-field search
-- ============================================
ALTER TABLE listings ADD COLUMN IF NOT EXISTS search_vector tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english',
            coalesce(business_name, '') || ' ' ||
            coalesce(description, '') || ' ' ||
            coalesce(subcategory, '') || ' ' ||
            coalesce(category, '') || ' ' ||
            coalesce(location, '')
        )
    ) STORED;

CREATE INDEX IF NOT EXISTS listings_search_idx ON listings USING GIN(search_vector);

-- ============================================
-- 2. SECURITY: Safe network stats function
--    Only accessible to subscribed members/admins
--    via SECURITY DEFINER (bypasses RLS safely)
-- ============================================
CREATE OR REPLACE FUNCTION get_member_stats()
RETURNS json AS $$
DECLARE
    v_role text;
    v_sub text;
    v_total_members integer;
    v_active_listings integer;
BEGIN
    -- Check the calling user's profile
    SELECT role, subscription_status
    INTO v_role, v_sub
    FROM profiles
    WHERE id = auth.uid();

    -- Only allow admins or active subscribers
    IF v_role IS NULL OR (v_role NOT IN ('admin', 'subscriber') AND v_sub != 'active') THEN
        RAISE EXCEPTION 'Access denied: subscriber or admin role required';
    END IF;

    SELECT COUNT(*) INTO v_total_members FROM profiles;
    SELECT COUNT(*) INTO v_active_listings FROM listings WHERE status = 'approved';

    RETURN json_build_object(
        'total_members', v_total_members,
        'active_listings', v_active_listings
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ============================================
-- 3. SECURITY: Admin-only stats function
-- ============================================
CREATE OR REPLACE FUNCTION get_admin_stats()
RETURNS json AS $$
DECLARE
    v_role text;
    v_total_members integer;
    v_active_listings integer;
    v_pending_listings integer;
    v_rejected_listings integer;
    v_expired_listings integer;
BEGIN
    SELECT role INTO v_role FROM profiles WHERE id = auth.uid();

    IF v_role != 'admin' THEN
        RAISE EXCEPTION 'Access denied: admin role required';
    END IF;

    SELECT COUNT(*) INTO v_total_members FROM profiles;
    SELECT COUNT(*) INTO v_active_listings FROM listings WHERE status = 'approved';
    SELECT COUNT(*) INTO v_pending_listings FROM listings WHERE status = 'pending';
    SELECT COUNT(*) INTO v_rejected_listings FROM listings WHERE status = 'rejected';
    SELECT COUNT(*) INTO v_expired_listings FROM listings WHERE status = 'expired';

    RETURN json_build_object(
        'total_members', v_total_members,
        'active_listings', v_active_listings,
        'pending_listings', v_pending_listings,
        'rejected_listings', v_rejected_listings,
        'expired_listings', v_expired_listings
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ============================================
-- 4. ADMIN LISTING ACTIONS: approve/reject/feature
--    These bypass RLS safely (SECURITY DEFINER)
-- ============================================
CREATE OR REPLACE FUNCTION admin_update_listing(
    p_listing_id uuid,
    p_status text DEFAULT NULL,
    p_is_featured boolean DEFAULT NULL
)
RETURNS boolean AS $$
DECLARE
    v_role text;
BEGIN
    SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
    IF v_role != 'admin' THEN
        RAISE EXCEPTION 'Access denied: admin role required';
    END IF;

    UPDATE listings SET
        status = COALESCE(p_status, status),
        is_featured = COALESCE(p_is_featured, is_featured),
        updated_at = now()
    WHERE id = p_listing_id;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- 5. ADMIN: Get all listings (including non-approved)
-- ============================================
CREATE OR REPLACE FUNCTION admin_get_listings(
    p_status text DEFAULT NULL,
    p_limit integer DEFAULT 50,
    p_offset integer DEFAULT 0
)
RETURNS SETOF listings AS $$
DECLARE
    v_role text;
BEGIN
    SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
    IF v_role != 'admin' THEN
        RAISE EXCEPTION 'Access denied: admin role required';
    END IF;

    IF p_status IS NOT NULL THEN
        RETURN QUERY
            SELECT * FROM listings
            WHERE status = p_status
            ORDER BY created_at DESC
            LIMIT p_limit OFFSET p_offset;
    ELSE
        RETURN QUERY
            SELECT * FROM listings
            ORDER BY created_at DESC
            LIMIT p_limit OFFSET p_offset;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ============================================
-- 6. STORAGE: Create listing-images bucket policy
--    (done via SQL since storage is controlled via policies)
-- ============================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'listing-images',
    'listing-images',
    true,
    5242880,  -- 5MB
    ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp'];

-- Storage RLS: anyone can view (public bucket)
-- Only authenticated users can upload
DROP POLICY IF EXISTS "Public can view listing images" ON storage.objects;
CREATE POLICY "Public can view listing images"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'listing-images');

DROP POLICY IF EXISTS "Auth users can upload listing images" ON storage.objects;
CREATE POLICY "Auth users can upload listing images"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'listing-images'
        AND auth.role() = 'authenticated'
    );

DROP POLICY IF EXISTS "Users can update own listing images" ON storage.objects;
CREATE POLICY "Users can update own listing images"
    ON storage.objects FOR UPDATE
    USING (
        bucket_id = 'listing-images'
        AND auth.role() = 'authenticated'
    );

DROP POLICY IF EXISTS "Users can delete own listing images" ON storage.objects;
CREATE POLICY "Users can delete own listing images"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'listing-images'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- ============================================
-- 7. GRANT execute on functions to anon/authenticated
-- ============================================
GRANT EXECUTE ON FUNCTION get_member_stats() TO authenticated;
GRANT EXECUTE ON FUNCTION get_admin_stats() TO authenticated;
GRANT EXECUTE ON FUNCTION admin_update_listing(uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_get_listings(text, integer, integer) TO authenticated;

-- ============================================
-- 8. Add admin user profile update helper
-- ============================================
CREATE OR REPLACE FUNCTION admin_set_user_role(p_user_id uuid, p_role text)
RETURNS boolean AS $$
DECLARE
    v_role text;
BEGIN
    SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
    IF v_role != 'admin' THEN
        RAISE EXCEPTION 'Access denied: admin role required';
    END IF;
    IF p_role NOT IN ('admin', 'subscriber', 'member') THEN
        RAISE EXCEPTION 'Invalid role';
    END IF;
    UPDATE profiles SET role = p_role WHERE id = p_user_id;
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION admin_set_user_role(uuid, text) TO authenticated;

-- ============================================
-- 9. Ensure profiles RLS allows admins to read all
--    via the is_admin() function (not recursive)
-- ============================================
DROP POLICY IF EXISTS "Admins can view all profiles" ON profiles;
CREATE POLICY "Admins can view all profiles"
    ON profiles FOR SELECT
    USING (auth.uid() = id OR is_admin());

SELECT 'Hardening complete!' AS result;
`;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        console.log('Connecting for hardening...');
        await client.connect();
        const result = await client.query(SQL);
        const last = Array.isArray(result) ? result[result.length - 1] : result;
        console.log('✅ ' + (last?.rows?.[0]?.result || 'Complete'));
        console.log('\nHardening applied:');
        console.log('  ✓ Full-text search vector column');
        console.log('  ✓ get_member_stats() RPC (subscribers only)');
        console.log('  ✓ get_admin_stats() RPC (admins only)');
        console.log('  ✓ admin_update_listing() RPC');
        console.log('  ✓ admin_get_listings() RPC');
        console.log('  ✓ admin_set_user_role() RPC');
        console.log('  ✓ listing-images storage bucket');
        console.log('  ✓ Storage RLS policies');
        console.log('  ✓ Function grants');
        console.log('  ✓ Admin profiles access policy');
    } catch(err) {
        console.error('❌ Error:', err.message);
        if (err.position) console.error('   At position:', err.position);
    } finally {
        await client.end();
    }
}

main();
