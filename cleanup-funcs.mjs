import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        await client.connect();
        
        const sql = `
            DROP POLICY IF EXISTS "Admins have full access to listings" ON listings;
            DROP POLICY IF EXISTS "Listings visibility" ON listings;
            DROP POLICY IF EXISTS "Admins can view all profiles" ON profiles;
            DROP FUNCTION IF EXISTS public.is_admin();
            DROP FUNCTION IF EXISTS public.admin_get_listings(text, text, text, integer, integer);
            DROP FUNCTION IF EXISTS public.admin_update_listing(uuid, text, boolean, text, text, text, text, text, text, text, text, text, text, text);
        `;
        await client.query(sql);
        console.log("Successfully dropped lingering public admin functions.");
        
    } catch (e) {
        console.error("Error dropping functions:", e);
    } finally {
        await client.end();
    }
}
main();
