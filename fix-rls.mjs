// fix-rls.mjs — Fix the infinite recursion in RLS policies
import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL;
if (!DB_URL) throw new Error('DATABASE_URL is required');

const SQL = `
-- ============================================
-- FIX: Remove circular admin policy on profiles
-- The admin check was causing infinite recursion
-- ============================================
DROP POLICY IF EXISTS "Admins can see all profiles" ON profiles;

-- Create a security definer function to safely check admin role
-- This avoids the recursive RLS check
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean AS $$
    SELECT EXISTS (
        SELECT 1 FROM profiles
        WHERE id = auth.uid() AND role = 'admin'
    );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Re-add admin policy for listings using the function
DROP POLICY IF EXISTS "Admins have full access to listings" ON listings;
CREATE POLICY "Admins have full access to listings"
    ON listings FOR ALL
    USING (is_admin());

-- For profiles, admins can read all via service role (frontend will use service role for admin ops)
-- Public users can read their own profiles only
-- This is already covered by the existing owner policy

-- ============================================
-- FIX: The "users can see own listings" policy
-- conflicts with "approved listings are public"
-- Combine them into a single SELECT policy
-- ============================================
DROP POLICY IF EXISTS "Approved listings are public" ON listings;
DROP POLICY IF EXISTS "Users can see own listings" ON listings;

-- Single combined SELECT policy: either approved OR own listing
CREATE POLICY "Listings visibility"
    ON listings FOR SELECT
    USING (
        status = 'approved'
        OR auth.uid() = user_id
        OR is_admin()
    );

SELECT 'RLS fix complete!' AS result;
`;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        console.log('Connecting to fix RLS...');
        await client.connect();
        const result = await client.query(SQL);
        const last = Array.isArray(result) ? result[result.length - 1] : result;
        console.log('✅ ' + (last?.rows?.[0]?.result || 'RLS policies fixed'));
    } catch(err) {
        console.error('❌ Error:', err.message);
    } finally {
        await client.end();
    }
}

main();
