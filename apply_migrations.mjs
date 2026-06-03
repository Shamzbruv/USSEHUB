import fs from 'fs';
import path from 'path';
import pg from 'pg';
import { fileURLToPath } from 'url';

const { Client } = pg;
const __dirname = path.dirname(fileURLToPath(import.meta.url));

const DB_URL = process.env.DATABASE_URL || 'postgresql://postgres.zcptuqrlovflcpqszery:Shambizonly1@@aws-1-us-east-1.pooler.supabase.com:6543/postgres';

async function main() {
    const client = new Client({ connectionString: DB_URL, ssl: { rejectUnauthorized: false } });
    try {
        await client.connect();
        const migrationsDir = path.join(__dirname, 'supabase', 'migrations');
        const files = fs.readdirSync(migrationsDir).sort();
        
        for (const file of files) {
            if (file.endsWith('.sql')) {
                console.log(`Applying migration: ${file}...`);
                const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
                await client.query(sql);
                console.log(`✅ Applied ${file}`);
            }
        }
        console.log('All migrations applied successfully!');
    } catch (e) {
        console.error('Migration failed:', e);
    } finally {
        await client.end();
    }
}
main();
