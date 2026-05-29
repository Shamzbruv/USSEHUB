// fix-admin-stats-rpc.mjs — Ensure admin stats RPC blocks anon users
import pg from 'pg';
const { Client } = pg;

const DB_URL = 'postgresql://postgres.zcptuqrlovflcpqszery:ussehub2026@aws-1-us-east-1.pooler.supabase.com:6543/postgres';

const SQL = `
-- Fix: admin stats must return error if no auth session (anon)
CREATE OR REPLACE FUNCTION get_admin_stats()
RETURNS json AS $$
DECLARE
    v_user_id uuid;
    v_role text;
    v_total_members integer;
    v_active_listings integer;
    v_pending_listings integer;
    v_rejected_listings integer;
    v_expired_listings integer;
BEGIN
    -- Get current user
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Access denied: authentication required';
    END IF;

    -- Verify admin role
    SELECT role INTO v_role FROM profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role != 'admin' THEN
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

-- Fix: member stats must also block truly anonymous (null auth.uid)
CREATE OR REPLACE FUNCTION get_member_stats()
RETURNS json AS $$
DECLARE
    v_user_id uuid;
    v_role text;
    v_sub text;
    v_total_members integer;
    v_active_listings integer;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Access denied: authentication required';
    END IF;

    SELECT role, subscription_status
    INTO v_role, v_sub
    FROM profiles
    WHERE id = v_user_id;

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

-- Revoke from anon role, keep for authenticated only
REVOKE EXECUTE ON FUNCTION get_admin_stats() FROM anon;
REVOKE EXECUTE ON FUNCTION get_member_stats() FROM anon;
GRANT EXECUTE ON FUNCTION get_admin_stats() TO authenticated;
GRANT EXECUTE ON FUNCTION get_member_stats() TO authenticated;

-- Also revoke admin_update_listing and admin_get_listings from anon
REVOKE EXECUTE ON FUNCTION admin_update_listing(uuid, text, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_get_listings(text, integer, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_set_user_role(uuid, text) FROM anon;

-- Storage bucket: ensure listing-images exists with correct settings
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'listing-images',
    'listing-images',
    true,
    5242880,
    ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
    public = true,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp'];

SELECT 'RPC security hardened!' AS result;
`;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        console.log('Connecting for RPC security fix...');
        await client.connect();
        const result = await client.query(SQL);
        const last = Array.isArray(result) ? result[result.length - 1] : result;
        console.log('✅ ' + (last?.rows?.[0]?.result || 'Done'));
        console.log('\nFixed:');
        console.log('  ✓ get_admin_stats() — now blocks null auth.uid() (anon)');
        console.log('  ✓ get_member_stats() — now blocks null auth.uid() (anon)');
        console.log('  ✓ All admin RPCs revoked from anon role');
        console.log('  ✓ listing-images bucket confirmed');
    } catch(err) {
        console.error('❌ Error:', err.message);
    } finally {
        await client.end();
    }
}

main();
