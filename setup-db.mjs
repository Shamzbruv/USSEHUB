// setup-db.mjs — Run this to create the required Supabase tables
// Usage: node setup-db.mjs
import pg from 'pg';
const { Client } = pg;

const DB_URL = 'postgresql://postgres.zcptuqrlovflcpqszery:ussehub2026@aws-1-us-east-1.pooler.supabase.com:6543/postgres';

const SQL = `
-- ============================================
-- PROFILES TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS profiles (
    id uuid REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    full_name text,
    email text,
    role text DEFAULT 'member' CHECK (role IN ('admin', 'subscriber', 'member')),
    subscription_status text DEFAULT 'inactive' CHECK (subscription_status IN ('active', 'inactive')),
    created_at timestamptz DEFAULT now()
);

-- Auto-create profile on user signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name, role, subscription_status)
    VALUES (
        new.id,
        new.email,
        COALESCE(new.raw_user_meta_data->>'full_name', ''),
        'member',
        'inactive'
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE PROCEDURE handle_new_user();

-- ============================================
-- LISTINGS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS listings (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    business_name text NOT NULL,
    category text,
    subcategory text,
    description text,
    location text,
    phone text,
    whatsapp text,
    email text,
    website text,
    image_url text,
    listing_type text DEFAULT 'basic' CHECK (listing_type IN ('basic', 'advanced', 'featured', 'banner')),
    status text DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'expired')),
    is_featured boolean DEFAULT false,
    user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    extra_notes text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS listings_updated_at ON listings;
CREATE TRIGGER listings_updated_at
    BEFORE UPDATE ON listings
    FOR EACH ROW EXECUTE PROCEDURE update_updated_at();

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================

-- PROFILES RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public profiles are viewable by owner" ON profiles;
CREATE POLICY "Public profiles are viewable by owner"
    ON profiles FOR SELECT
    USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update own profile" ON profiles;
CREATE POLICY "Users can update own profile"
    ON profiles FOR UPDATE
    USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can insert own profile" ON profiles;
CREATE POLICY "Users can insert own profile"
    ON profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Admins can see all profiles" ON profiles;
CREATE POLICY "Admins can see all profiles"
    ON profiles FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    );

-- LISTINGS RLS
ALTER TABLE listings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Approved listings are public" ON listings;
CREATE POLICY "Approved listings are public"
    ON listings FOR SELECT
    USING (status = 'approved');

DROP POLICY IF EXISTS "Users can see own listings" ON listings;
CREATE POLICY "Users can see own listings"
    ON listings FOR SELECT
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own listings" ON listings;
CREATE POLICY "Users can insert own listings"
    ON listings FOR INSERT
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own pending listings" ON listings;
CREATE POLICY "Users can update own pending listings"
    ON listings FOR UPDATE
    USING (auth.uid() = user_id AND status = 'pending');

DROP POLICY IF EXISTS "Admins have full access to listings" ON listings;
CREATE POLICY "Admins have full access to listings"
    ON listings FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    );

-- ============================================
-- SEED DATA (demo approved listings)
-- ============================================
INSERT INTO listings (business_name, category, subcategory, description, location, phone, email, website, status, is_featured, listing_type)
VALUES
    ('Pure Ice', 'food', 'Frozen Products', 'Ice Cubes, Ice Blocks, Cold Storage Solutions for commercial and residential use.', 'st-elizabeth', '+1-876-567-0098', 'info@pureice.com', 'https://www.pureice.com', 'approved', true, 'featured'),
    ('USSE Consultancy', 'services', 'Corporate Advisory', 'Market Research, Strategic Planning, Real Estate advisory services across Jamaica.', 'kingston', '+1-876-555-0101', 'connect@usse.com', 'https://www.usse.com', 'approved', true, 'featured'),
    ('Negril Yoga Centre', 'health', 'Health & Wellness', 'Retreats, Daily Yoga Sessions, Organic Cafe in the heart of Negril.', 'westmoreland', '+1-876-957-4323', 'peace@negrilyoga.com', 'https://www.negrilyoga.com', 'approved', false, 'basic'),
    ('Aloe Jamaica Agency', 'services', 'Creative Design', 'Creative Design, Web Development and Digital Marketing services.', 'kingston', NULL, 'info@aloejamaica.com', NULL, 'approved', false, 'basic'),
    ('PISTOL Operations', 'services', 'Logistics & IT', 'Logistics, IT Infrastructure, and HR Systems management.', 'st-james', NULL, 'ops@pistol.com', NULL, 'approved', false, 'basic')
ON CONFLICT DO NOTHING;

SELECT 'Database setup complete!' AS result;
`;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        console.log('Connecting to Supabase database...');
        await client.connect();
        console.log('Connected! Running setup SQL...');
        const result = await client.query(SQL);
        const lastResult = result[result.length - 1];
        console.log('✅ ' + (lastResult?.rows?.[0]?.result || 'Done'));
        console.log('\nTables created:');
        console.log('  ✓ profiles');
        console.log('  ✓ listings');
        console.log('  ✓ RLS policies applied');
        console.log('  ✓ Seed data inserted');
        console.log('  ✓ Triggers created');
    } catch(err) {
        console.error('❌ Error:', err.message);
        if (err.message.includes('already exists')) {
            console.log('(Some objects may already exist — this is fine)');
        }
    } finally {
        await client.end();
    }
}

main();
