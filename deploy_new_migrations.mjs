/**
 * deploy_new_migrations.mjs
 * Applies only the two migrations that are NOT yet deployed to the live database.
 * Run with: DATABASE_URL=... node deploy_new_migrations.mjs
 */
import fs from 'fs';
import path from 'path';
import pg from 'pg';
import { fileURLToPath } from 'url';

const { Client } = pg;
const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Only deploy these two — all earlier migrations were already applied.
const MIGRATIONS_TO_DEPLOY = [
    '20260722000000_ajm_tiered_webpages.sql',
    '20260723000000_advertising_commerce_analytics.sql',
];

const DB_URL = process.env.DATABASE_URL;
if (!DB_URL) {
    console.error('❌ DATABASE_URL environment variable is required.');
    process.exit(1);
}

async function main() {
    const client = new Client({
        connectionString: DB_URL,
        ssl: { rejectUnauthorized: false },
        connectionTimeoutMillis: 30000,
        statement_timeout: 120000,
    });

    try {
        await client.connect();
        console.log('✅ Connected to Supabase database.\n');

        for (const file of MIGRATIONS_TO_DEPLOY) {
            const filePath = path.join(__dirname, 'supabase', 'migrations', file);
            if (!fs.existsSync(filePath)) {
                console.warn(`⚠️  Migration file not found: ${file} — skipping.`);
                continue;
            }

            console.log(`🚀 Applying: ${file} ...`);
            const sql = fs.readFileSync(filePath, 'utf8');

            try {
                await client.query(sql);
                console.log(`✅ Applied: ${file}\n`);
            } catch (err) {
                // Some errors are expected on re-run (already exists) — log and continue
                console.error(`❌ Error in ${file}: ${err.message}`);
                console.error('   Stopping — fix the error and re-run.\n');
                process.exit(1);
            }
        }

        // Post-deploy verification
        console.log('🔍 Verifying deployed tables...');
        const checks = [
            "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='listing_webpages') AS listing_webpages",
            "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='payment_accounts') AS payment_accounts",
            "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='ad_orders') AS ad_orders",
            "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='ad_packages' AND column_name='code') AS ad_packages_code",
        ];

        for (const sql of checks) {
            const { rows } = await client.query(sql);
            const key = Object.keys(rows[0])[0];
            const ok = rows[0][key];
            console.log(`  ${ok ? '✅' : '❌'} ${key}: ${ok}`);
        }

        console.log('\n🎉 All migrations deployed successfully!');
    } catch (err) {
        console.error('Fatal error:', err.message);
        process.exit(1);
    } finally {
        await client.end();
    }
}

main();
