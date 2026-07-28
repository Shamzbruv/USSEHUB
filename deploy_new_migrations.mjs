/**
 * Transactional AJM schema deployer.
 *
 * Dry-run (default): node deploy_new_migrations.mjs
 * Apply:             node deploy_new_migrations.mjs --apply
 *
 * DATABASE_URL and RESEND_API_KEY may be supplied by the environment or the
 * ignored local .env file. Secret values are parameterized and never logged.
 */
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import pg from 'pg';
import { fileURLToPath } from 'url';

const { Client } = pg;
const root = path.dirname(fileURLToPath(import.meta.url));

function loadLocalEnv() {
    const filename = path.join(root, '.env');
    if (!fs.existsSync(filename)) return;
    for (const rawLine of fs.readFileSync(filename, 'utf8').split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line || line.startsWith('#')) continue;
        const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
        if (!match || process.env[match[1]]) continue;
        let value = match[2].trim();
        if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
            value = value.slice(1, -1);
        }
        process.env[match[1]] = value;
    }
}

loadLocalEnv();

const apply = process.argv.includes('--apply');
const skipSecrets = process.argv.includes('--skip-secrets');
const databaseUrl = process.env.DATABASE_URL;
const migrations = [
    '20260722000000_ajm_tiered_webpages.sql',
    '20260723000000_advertising_commerce_analytics.sql',
    '20260728000000_advertising_workflow_repair.sql',
    '20260728000001_webpage_activation_draft.sql'
];

if (!databaseUrl) {
    console.error('DATABASE_URL is required (environment or ignored .env file).');
    process.exit(1);
}

function checksum(text) {
    return crypto.createHash('sha256').update(text).digest('hex');
}

async function upsertVaultSecret(client, name, value, description) {
    if (!value) return false;
    const existing = await client.query('SELECT id FROM vault.secrets WHERE name = $1 LIMIT 1', [name]);
    if (existing.rowCount) {
        await client.query('SELECT vault.update_secret($1, $2, $3, $4)', [existing.rows[0].id, value, name, description]);
    } else {
        await client.query('SELECT vault.create_secret($1, $2, $3)', [value, name, description]);
    }
    return true;
}

async function validateResendKey(apiKey) {
    try {
        // An empty email request cannot send mail. A usable sending key reaches
        // payload validation (4xx), while an invalid key is rejected at auth.
        const response = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: {
                Authorization: `Bearer ${apiKey}`,
                'Content-Type': 'application/json'
            },
            body: '{}'
        });
        const payload = await response.json().catch(() => ({}));
        if (response.status === 401 && /api key is invalid/i.test(String(payload.message || ''))) return false;
        if ([400, 422].includes(response.status)) return true;
        return null;
    } catch {
        return null;
    }
}

async function main() {
    const client = new Client({
        connectionString: databaseUrl,
        ssl: { rejectUnauthorized: false },
        connectionTimeoutMillis: 30_000,
        statement_timeout: 180_000
    });

    await client.connect();
    try {
        // This project connection defaults to read-only. Deployment is an
        // explicit write operation, so opt this session into writes before
        // opening the all-or-nothing migration transaction.
        await client.query('SET default_transaction_read_only = off');
        await client.query('BEGIN');
        await client.query('SELECT pg_advisory_xact_lock($1)', [2026072800]);
        await client.query(`
            CREATE SCHEMA IF NOT EXISTS private;
            CREATE TABLE IF NOT EXISTS private.ajm_schema_migrations (
                filename text PRIMARY KEY,
                checksum text NOT NULL,
                applied_at timestamptz NOT NULL DEFAULT now()
            )
        `);

        for (const filename of migrations) {
            const fullPath = path.join(root, 'supabase', 'migrations', filename);
            if (!fs.existsSync(fullPath)) throw new Error(`Required migration is missing: ${filename}`);
            const sql = fs.readFileSync(fullPath, 'utf8');
            const digest = checksum(sql);
            const installed = await client.query(
                'SELECT checksum FROM private.ajm_schema_migrations WHERE filename = $1',
                [filename]
            );

            if (installed.rowCount) {
                if (installed.rows[0].checksum !== digest) {
                    throw new Error(`Applied migration was modified after deployment: ${filename}`);
                }
                console.log(`✓ already recorded: ${filename}`);
                continue;
            }

            console.log(`→ validating: ${filename}`);
            await client.query(sql);
            await client.query(
                'INSERT INTO private.ajm_schema_migrations (filename, checksum) VALUES ($1, $2)',
                [filename, digest]
            );
        }

        await client.query("NOTIFY pgrst, 'reload schema'");
        if (apply) {
            await client.query('COMMIT');
            console.log('✓ schema transaction committed');
        } else {
            await client.query('ROLLBACK');
            console.log('✓ dry-run succeeded; all schema changes were rolled back');
            return;
        }

        if (!skipSecrets) {
            const resendKey = process.env.RESEND_API_KEY;
            const resendFrom = process.env.RESEND_FROM_EMAIL || 'USSE Hub System <admin@ussehub.com>';
            if (!resendKey) {
                console.warn('! RESEND_API_KEY is absent; schema is live but ad emails remain disabled.');
            } else {
                const resendKeyStatus = await validateResendKey(resendKey);
                if (resendKeyStatus === false) {
                    console.warn('! RESEND_API_KEY was rejected by Resend; the existing Vault configuration was left unchanged.');
                } else {
                    if (resendKeyStatus === null) {
                        console.warn('! Resend key validation was inconclusive; storing the supplied deployment value.');
                    }
                    await client.query('BEGIN');
                    await upsertVaultSecret(client, 'RESEND_API_KEY', resendKey, 'AJM advertising notification dispatch');
                    await upsertVaultSecret(client, 'RESEND_FROM_EMAIL', resendFrom, 'Verified sender for AJM advertising notifications');
                    await client.query('COMMIT');
                    console.log('✓ Resend Vault configuration updated (values not printed)');
                }
            }
        }

        const verification = await client.query(`
            SELECT
              to_regclass('public.listing_webpages') IS NOT NULL AS listing_webpages,
              to_regclass('public.ad_orders') IS NOT NULL AS ad_orders,
              to_regclass('public.advertisements') IS NOT NULL AS advertisements,
              to_regprocedure('public.admin_manage_advertising(text,jsonb)') IS NOT NULL AS admin_lifecycle,
              to_regprocedure('public.get_active_advertisements(text,integer)') IS NOT NULL AS public_delivery,
              (SELECT count(*) FROM public.listings WHERE status = 'approved') AS approved_listings
        `);
        console.log('Verification:', verification.rows[0]);
    } catch (error) {
        try { await client.query('ROLLBACK'); } catch {}
        console.error(`Deployment failed: ${error.message}`);
        process.exitCode = 1;
    } finally {
        await client.end();
    }
}

await main();
