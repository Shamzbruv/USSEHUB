import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        await client.connect();
        
        const functions = await client.query(`
            SELECT p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')' as signature
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = 'public'
              AND p.proname IN ('is_admin', 'admin_get_listings', 'admin_update_listing');
        `);
        console.log(JSON.stringify(functions.rows, null, 2));
        
    } catch (e) {
        console.error(e);
    } finally {
        await client.end();
    }
}
main();
