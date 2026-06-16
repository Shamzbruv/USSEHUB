import fs from 'fs';
import path from 'path';
import pg from 'pg';
import { fileURLToPath } from 'url';

const { Client } = pg;
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DB_URL = process.env.DATABASE_URL;

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        await client.connect();
        const sql = fs.readFileSync(path.join(__dirname, 'supabase', 'seed.sql'), 'utf8');
        await client.query(sql);
        console.log('✅ Seed data applied successfully!');
    } catch (e) {
        console.error('Seed failed:', e);
    } finally {
        await client.end();
    }
}
main();
