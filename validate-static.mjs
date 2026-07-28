import fs from 'fs';
import vm from 'vm';
import { execFileSync } from 'child_process';

const htmlFiles = [
    'index.html',
    'ajm-advertising-hub.html',
    'ajm-admin-panel.html',
    'ajm-ad-management.html',
    'ajm-webpage-builder.html',
    'ajm-business-page.html'
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
    'deploy_new_migrations.mjs',
    ...fs.readdirSync('supabase/migrations').map((name) => `supabase/migrations/${name}`)
].filter((filename) => fs.statSync(filename).isFile()).map((filename) => fs.readFileSync(filename, 'utf8')).join('\n');

assert(!/\bre_[A-Za-z0-9_-]{20,}\b/.test(trackedText), 'A Resend-style secret appears in tracked source.');
assert(fs.existsSync('supabase/migrations/20260728000000_advertising_workflow_repair.sql'), 'The advertising workflow repair migration is missing.');
assert(fs.existsSync('supabase/migrations/20260728000001_webpage_activation_draft.sql'), 'The webpage activation follow-up migration is missing.');

const hub = fs.readFileSync('ajm-advertising-hub.html', 'utf8');
assert(hub.includes("rpc('get_ad_catalog'"), 'Hub does not use the safe package catalogue RPC.');
assert(hub.includes("rpc('create_ad_order'"), 'Hub does not create advertising orders through the RPC.');
assert(hub.includes("rpc('submit_ad_payment_proof'"), 'Hub does not submit bank-transfer proof through the RPC.');
assert(!/from\(['"]ad_orders['"]\)[\s\S]{0,160}\.(?:insert|update|delete)\(/.test(hub), 'Hub directly mutates protected ad_orders.');

const manager = fs.readFileSync('ajm-ad-management.html', 'utf8');
for (const rpc of ['admin_get_ad_configuration', 'admin_get_ad_orders', 'admin_manage_advertising', 'get_admin_advertising_analytics']) {
    assert(manager.includes(rpc), `Dedicated admin manager does not call ${rpc}.`);
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
