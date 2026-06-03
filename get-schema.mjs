import pg from 'pg';
const { Client } = pg;

const DB_URL = process.env.DATABASE_URL || 'postgresql://postgres.zcptuqrlovflcpqszery:Shambizonly1@@aws-1-us-east-1.pooler.supabase.com:6543/postgres';

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        await client.connect();
        const res = await client.query(`
            SELECT table_name, column_name, data_type 
            FROM information_schema.columns 
            WHERE table_schema = 'public'
            ORDER BY table_name, ordinal_position;
        `);
        console.log(JSON.stringify(res.rows, null, 2));
    } catch (e) {
        console.error(e);
    } finally {
        await client.end();
    }
}
main();
