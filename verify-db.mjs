import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        await client.connect();
        
        console.log("--- RLS POLICIES ---");
        const policies = await client.query(`
            SELECT schemaname, tablename, policyname, roles, cmd, qual, with_check 
            FROM pg_policies 
            WHERE schemaname = 'public';
        `);
        console.log(JSON.stringify(policies.rows, null, 2));

        console.log("--- FUNCTIONS ---");
        const functions = await client.query(`
            SELECT p.proname as function_name, n.nspname as schema_name, p.prosecdef as is_security_definer
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname IN ('public', 'private')
              AND p.proname NOT IN ('update_search_document', 'update_updated_at', 'handle_new_user');
        `);
        console.log(JSON.stringify(functions.rows, null, 2));
        
    } catch (e) {
        console.error(e);
    } finally {
        await client.end();
    }
}
main();
