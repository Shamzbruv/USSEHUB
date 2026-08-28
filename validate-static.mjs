import fs from 'fs';
import vm from 'vm';
import { execFileSync } from 'child_process';

const htmlFiles = [
    'index.html',
    'ajm-advertising-hub.html',
    'ajm-admin-panel.html',
    'ajm-ad-management.html',
    'master-admin.html',
    'ajm-webpage-builder.html',
    'ajm-business-page.html',
    'ajm-aloe-jamaica.html',
    'usse-consultancy.html',
    'pistol-operations-logistics.html'
];

const errors = [];
const assert = (condition, message) => { if (!condition) errors.push(message); };

for (const filename of htmlFiles) {
    const source = fs.readFileSync(filename, 'utf8');
    let scriptNumber = 0;
    for (const match of source.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/gi)) {
        scriptNumber += 1;
        const attributes = match[1];
        const body = match[2];
        if (/\bsrc\s*=|application\/ld\+json/i.test(attributes) || !body.trim()) continue;
        try {
            if (/\btype=["']module["']/i.test(attributes)) {
                new vm.SourceTextModule(body, { identifier: `${filename}#script-${scriptNumber}` });
            } else {
                new vm.Script(body, { filename: `${filename}#script-${scriptNumber}` });
            }
        } catch (error) {
            errors.push(`${filename} script ${scriptNumber}: ${error.message}`);
        }
    }

    const ids = [...source.matchAll(/(?:^|\s)id\s*=\s*["']([^"']+)["']/gi)].map((match) => match[1]);
    const duplicates = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
    assert(!duplicates.length, `${filename} contains duplicate DOM ids: ${duplicates.join(', ')}`);
}

const trackedText = [
    ...htmlFiles,
    'taxonomy.js',
    'deploy_new_migrations.mjs',
    ...fs.readdirSync('supabase/migrations').map((name) => `supabase/migrations/${name}`)
].filter((filename) => fs.statSync(filename).isFile()).map((filename) => fs.readFileSync(filename, 'utf8')).join('\n');

const serveConfig = JSON.parse(fs.readFileSync('serve.json', 'utf8'));
assert(serveConfig.cleanUrls === false, 'serve.json must not redirect explicit .html URLs and discard their query strings.');
const rewriteSources = new Set((serveConfig.rewrites || []).map((rewrite) => rewrite.source));
for (const route of ['/ajm-advertising-hub', '/ajm-business-page', '/ajm-webpage-builder']) {
    assert(rewriteSources.has(route), `serve.json is missing the extensionless ${route} rewrite.`);
}
assert(!/["'`](?:\.\/)?(?:ajm-advertising-hub|ajm-business-page|ajm-webpage-builder)\.html\?/.test(trackedText), 'A query-bearing AJM route still uses .html and will lose its query string during clean-URL redirects.');

assert(!/\bre_[A-Za-z0-9_-]{20,}\b/.test(trackedText), 'A Resend-style secret appears in tracked source.');
assert(fs.existsSync('supabase/migrations/20260728000000_advertising_workflow_repair.sql'), 'The advertising workflow repair migration is missing.');
assert(fs.existsSync('supabase/migrations/20260728000001_webpage_activation_draft.sql'), 'The webpage activation follow-up migration is missing.');
assert(fs.existsSync('supabase/migrations/20260728000002_webpage_segment_sync.sql'), 'The webpage market-segment synchronization migration is missing.');
assert(fs.existsSync('supabase/migrations/20260827175628_paid_webpage_promotion_analytics.sql'), 'The paid webpage promotion and analytics migration is missing.');

const hub = fs.readFileSync('ajm-advertising-hub.html', 'utf8');
assert(hub.includes("rpc('get_ad_catalog'"), 'Hub does not use the safe package catalogue RPC.');
assert(hub.includes("rpc('create_ad_order'"), 'Hub does not create advertising orders through the RPC.');
assert(hub.includes("rpc('submit_ad_payment_proof'"), 'Hub does not submit bank-transfer proof through the RPC.');
assert(hub.includes('id="adv-webpage-promotion-style"'), 'Webpage checkout does not let the member choose a promotion format.');
assert(!/from\(['"]ad_orders['"]\)[\s\S]{0,160}\.(?:insert|update|delete)\(/.test(hub), 'Hub directly mutates protected ad_orders.');
assert(hub.includes('window.getCategoryFilterValues?.(category)'), 'Hub category filtering does not preserve legacy listing matches.');
for (const category of [
    'GENERAL',
    'PROPERTY MANAGEMENT SERVICES',
    'FINANCIAL SERVICES',
    'NGO / SERVICE CLUBS',
    'REAL ESTATE',
    'FOOD & BEVERAGE',
    'FARMING & AGRICULTURE',
    'CONSTRUCTION',
    'AUTO CARE SERVICES',
    'ENTERTAINMENT'
]) {
    const htmlCategory = category.replaceAll('&', '&amp;');
    assert(hub.includes(`filterByCategory('${htmlCategory}'`), `Hub is missing the current ${category} browse card.`);
}
assert(!hub.includes('data-category="jobs"'), 'Hub still presents Jobs & Careers as a current 2026 category.');

const manager = fs.readFileSync('ajm-ad-management.html', 'utf8');
for (const rpc of ['admin_get_ad_configuration', 'admin_get_ad_orders', 'admin_manage_advertising', 'get_admin_advertising_analytics']) {
    assert(manager.includes(rpc), `Dedicated admin manager does not call ${rpc}.`);
}

const adminPanel = fs.readFileSync('ajm-admin-panel.html', 'utf8');
assert(adminPanel.includes("rpc('admin_manage_listing_webpage'"), 'Admin panel does not use the database-backed paid webpage lifecycle RPC.');
assert(!adminPanel.includes("functions.invoke('admin-ad-subscriptions'"), 'Admin panel still invokes the obsolete paid webpage Edge Function.');

const builder = fs.readFileSync('ajm-webpage-builder.html', 'utf8');
for (const field of ['promotion-enabled', 'promotion-style', 'promotion-headline', 'promotion-text', 'promotion-cta']) {
    assert(builder.includes(`id="${field}"`), `Webpage builder is missing the ${field} control.`);
}

const businessPage = fs.readFileSync('ajm-business-page.html', 'utf8');
assert(businessPage.includes("rpc('record_webpage_event'"), 'Paid business page does not record its own engagement.');

const networkModule = fs.readFileSync('assets/ajm-ad-delivery.mjs', 'utf8');
assert(networkModule.includes("const DEFAULT_PLACEMENT = 'webpage-network'"), 'Shared ad delivery does not use the paid webpage network placement.');
for (const filename of ['ajm-aloe-jamaica.html', 'usse-consultancy.html', 'pistol-operations-logistics.html']) {
    const source = fs.readFileSync(filename, 'utf8');
    assert(source.includes("from './assets/ajm-ad-delivery.mjs'"), `${filename} is missing shared paid webpage ad delivery.`);
}

try {
    execFileSync('git', ['diff', '--check'], { stdio: 'pipe' });
} catch (error) {
    errors.push(`git diff --check failed: ${String(error.stdout || error.message).trim()}`);
}

if (errors.length) {
    console.error(`Validation failed (${errors.length}):`);
    errors.forEach((error) => console.error(`- ${error}`));
    process.exit(1);
}

console.log(`Validation passed: ${htmlFiles.length} HTML entry points, inline JavaScript, commerce RPC wiring, duplicate ids, secrets and whitespace.`);
