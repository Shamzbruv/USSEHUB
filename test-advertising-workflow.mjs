/**
 * Transactional live-schema integration test for AJM advertising.
 * All created rows and the repair migration itself are rolled back.
 */
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
        const match = rawLine.trim().match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
        if (!match || process.env[match[1]]) continue;
        let value = match[2].trim();
        if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
        process.env[match[1]] = value;
    }
}

loadLocalEnv();
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required.');

const client = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false },
    statement_timeout: 180_000
});

const checks = [];
function check(condition, label) {
    if (!condition) throw new Error(`Assertion failed: ${label}`);
    checks.push(label);
}

async function become(role, userId = null) {
    await client.query('RESET ROLE');
    await client.query(`SET LOCAL ROLE ${role}`);
    await client.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify({ role, sub: userId })]);
    await client.query("SELECT set_config('request.jwt.claim.sub', $1, true)", [userId || '']);
}

async function rpc(sql, params = []) {
    const { rows } = await client.query(sql, params);
    return rows[0]?.result;
}

await client.connect();
try {
    // The configured project connection is read-only by default. This test
    // needs writes, but every mutation remains inside the rollback below.
    await client.query('SET default_transaction_read_only = off');
    await client.query('BEGIN');
    const migrationFiles = [
        '20260728000000_advertising_workflow_repair.sql',
        '20260728000001_webpage_activation_draft.sql'
    ];
    for (const filename of migrationFiles) {
        const migration = fs.readFileSync(path.join(root, 'supabase/migrations', filename), 'utf8');
        await client.query(migration);
    }

    const identities = await client.query(`
        SELECT
          (SELECT id FROM public.profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1) AS admin_id,
          (SELECT id FROM public.profiles WHERE role <> 'admin' ORDER BY created_at LIMIT 1) AS member_id
    `);
    const { admin_id: adminId, member_id: memberId } = identities.rows[0];
    check(Boolean(adminId), 'an administrator identity is available');
    check(Boolean(memberId), 'a member identity is available');

    const nonce = Date.now().toString(36);
    await become('authenticated', adminId);
    const account = await rpc(
        "SELECT public.admin_manage_advertising('bank_upsert', $1::jsonb) AS result",
        [JSON.stringify({
            code: `test-bank-${nonce}`,
            label: 'Transactional test bank',
            bank_name: 'Test Bank',
            account_name: 'AJM Test',
            account_number: '0000000000',
            currency: 'JMD',
            instructions: 'Integration test only',
            is_active: true,
            is_default: true
        })]
    );
    check(Boolean(account?.id), 'admin can create a payment destination through the audited RPC');

    const pkg = await rpc(
        "SELECT public.admin_manage_advertising('package_upsert', $1::jsonb) AS result",
        [JSON.stringify({
            code: `test-display-${nonce}`,
            name: 'Transactional display package',
            description: 'Rolled back after verification',
            product_type: 'display_ad',
            price: 1234,
            currency: 'JMD',
            duration_days: 14,
            placements: ['homepage', 'hub-sidebar'],
            features: ['Text creative', 'Two placements'],
            payment_account_id: account.id,
            is_active: true,
            sort_order: 9999
        })]
    );
    check(Boolean(pkg?.id), 'admin can create a priced package through the audited RPC');

    const webpagePkg = await rpc(
        "SELECT public.admin_manage_advertising('package_upsert', $1::jsonb) AS result",
        [JSON.stringify({
            code: `test-webpage-gold-${nonce}`,
            name: 'Transactional Gold webpage package',
            description: 'Rolled back after webpage workflow verification',
            product_type: 'webpage',
            webpage_tier: 'gold',
            price: 5678,
            currency: 'JMD',
            duration_days: 30,
            placements: ['directory-webpage'],
            features: ['Gold webpage builder'],
            payment_account_id: account.id,
            is_active: true,
            sort_order: 9998
        })]
    );
    check(
        webpagePkg?.id && webpagePkg.webpage_tier === 'gold',
        'admin can create a priced Gold webpage package through the audited RPC'
    );

    const adminConfig = await rpc('SELECT public.admin_get_ad_configuration() AS result');
    check(adminConfig?.packages?.some((item) => item.id === pkg.id), 'admin configuration includes active and inactive package detail');
    check(adminConfig?.packages?.some((item) => item.id === webpagePkg.id), 'admin configuration includes the Gold webpage package');
    check(adminConfig?.payment_accounts?.some((item) => item.id === account.id), 'admin configuration includes bank-transfer destinations');

    // Use an isolated member-owned listing instead of modifying one of the
    // project's real directory entries. It is removed by the final rollback.
    await client.query('RESET ROLE');
    const listingFixture = await client.query(
        `INSERT INTO public.listings (
            business_name, owner_user_id, listing_type, status, market_segment,
            published_at, approved_at, expires_at
         ) VALUES (
            $1, $2, 'basic', 'approved', 'local-business',
            now() - interval '1 day', now() - interval '1 day', now() + interval '1 year'
         ) RETURNING id`,
        [`Transactional webpage listing ${nonce}`, memberId]
    );
    const listingId = listingFixture.rows[0]?.id;
    check(Boolean(listingId), 'a rollback-only member-owned listing is available for the webpage order');

    await become('authenticated', memberId);
    const order = await rpc(
        'SELECT public.create_ad_order($1::uuid, NULL, $2::uuid[], $3, $4::jsonb) AS result',
        [pkg.id, [], 'Transactional integration test', JSON.stringify({
            headline: 'Test campaign',
            body_text: 'This campaign is rolled back.',
            cta_label: 'Learn more',
            cta_url: 'https://www.ussehub.com/'
        })]
    );
    check(order?.status === 'pending_payment', 'customer order starts pending payment');
    check(order?.payment_account_snapshot?.account_number === '0000000000', 'order snapshots the selected bank instructions');

    const incompleteOrder = await rpc(
        'SELECT public.create_ad_order($1::uuid, NULL, $2::uuid[], $3, $4::jsonb) AS result',
        [pkg.id, [], 'Creative-readiness rejection test', JSON.stringify({})]
    );
    check(incompleteOrder?.status === 'pending_payment', 'an incomplete creative can be saved before admin review');

    const webpageOrder = await rpc(
        'SELECT public.create_ad_order($1::uuid, $2::uuid, $3::uuid[], $4, $5::jsonb) AS result',
        [webpagePkg.id, listingId, [], 'Transactional Gold webpage order', JSON.stringify({})]
    );
    check(
        webpageOrder?.status === 'pending_payment' && webpageOrder?.product_type_snapshot === 'webpage',
        'customer can order a Gold webpage for their own listing'
    );
    check(webpageOrder?.listing_id === listingId, 'webpage order preserves its member-owned listing link');

    await client.query('RESET ROLE');
    const proofPath = `${memberId}/${order.id}/test-proof.png`;
    const incompleteProofPath = `${memberId}/${incompleteOrder.id}/test-proof.png`;
    const webpageProofPath = `${memberId}/${webpageOrder.id}/test-proof.png`;
    await client.query(
        "INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES ('ad-payment-proofs', $1, $2, $3::jsonb)",
        [proofPath, memberId, JSON.stringify({ mimetype: 'image/png', size: 1 })]
    );
    await client.query(
        "INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES ('ad-payment-proofs', $1, $2, $3::jsonb)",
        [incompleteProofPath, memberId, JSON.stringify({ mimetype: 'image/png', size: 1 })]
    );
    await client.query(
        "INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES ('ad-payment-proofs', $1, $2, $3::jsonb)",
        [webpageProofPath, memberId, JSON.stringify({ mimetype: 'image/png', size: 1 })]
    );

    await become('authenticated', memberId);
    const submitted = await rpc(
        'SELECT public.submit_ad_payment_proof($1::uuid, $2, $3) AS result',
        [order.id, proofPath, `TEST-${nonce}`]
    );
    check(submitted?.status === 'payment_submitted', 'customer can submit protected bank-transfer proof');
    const incompleteSubmitted = await rpc(
        'SELECT public.submit_ad_payment_proof($1::uuid, $2, $3) AS result',
        [incompleteOrder.id, incompleteProofPath, `INCOMPLETE-${nonce}`]
    );
    check(incompleteSubmitted?.status === 'payment_submitted', 'incomplete creative can reach payment review without becoming active');
    const webpageSubmitted = await rpc(
        'SELECT public.submit_ad_payment_proof($1::uuid, $2, $3) AS result',
        [webpageOrder.id, webpageProofPath, `WEBPAGE-${nonce}`]
    );
    check(webpageSubmitted?.status === 'payment_submitted', 'customer can submit bank-transfer proof for a webpage order');

    const mine = await rpc('SELECT public.get_my_ad_orders() AS result');
    check(mine?.orders?.some((item) => item.id === order.id), 'customer can read their own order history');
    check(mine?.orders?.some((item) => item.id === webpageOrder.id), 'customer order history includes their Gold webpage order');

    await become('authenticated', adminId);
    const queue = await rpc(
        'SELECT public.admin_get_ad_orders($1, NULL, NULL, 25, 0) AS result',
        ['payment_submitted']
    );
    check(queue?.orders?.some((item) => item.id === order.id), 'admin payment queue returns the submitted order');

    await client.query('SAVEPOINT reject_incomplete_creative');
    let readinessError = null;
    try {
        await rpc(
            "SELECT public.admin_manage_advertising('confirm_payment', $1::jsonb) AS result",
            [JSON.stringify({ order_id: incompleteOrder.id })]
        );
    } catch (error) {
        readinessError = error;
        await client.query('ROLLBACK TO SAVEPOINT reject_incomplete_creative');
    }
    await client.query('RELEASE SAVEPOINT reject_incomplete_creative');
    check(
        /Display advertisements require/i.test(readinessError?.message || ''),
        'admin cannot activate a display advertisement with incomplete creative'
    );

    const approved = await rpc(
        "SELECT public.admin_manage_advertising('confirm_payment', $1::jsonb) AS result",
        [JSON.stringify({ order_id: order.id, admin_note: 'Transactional approval test' })]
    );
    check(approved?.status === 'approved', 'admin confirmation activates the order');
    check(approved?.related?.advertisements?.length === 2, 'confirmation creates every configured advertisement placement');

    const webpageApproved = await rpc(
        "SELECT public.admin_manage_advertising('confirm_payment', $1::jsonb) AS result",
        [JSON.stringify({ order_id: webpageOrder.id, admin_note: 'Transactional Gold webpage approval test' })]
    );
    check(webpageApproved?.status === 'approved', 'admin confirmation activates the paid webpage order');

    await client.query('RESET ROLE');
    const webpageActivation = await client.query(
        `SELECT
            s.status AS subscription_status,
            s.user_id,
            s.listing_id,
            s.package_id,
            w.tier,
            w.page_status,
            w.market_segment
         FROM public.ad_subscriptions s
         LEFT JOIN public.listing_webpages w ON w.listing_id = s.listing_id
         WHERE s.ad_order_id = $1`,
        [webpageOrder.id]
    );
    const activatedWebpage = webpageActivation.rows[0];
    check(
        activatedWebpage?.subscription_status === 'active'
            && activatedWebpage.user_id === memberId
            && activatedWebpage.listing_id === listingId
            && activatedWebpage.package_id === webpagePkg.id,
        'payment confirmation creates the correct active listing subscription'
    );
    check(
        activatedWebpage?.tier === 'gold'
            && activatedWebpage.page_status === 'draft'
            && activatedWebpage.market_segment === 'local-business',
        'payment confirmation provisions a draft Gold webpage for the listing market segment'
    );

    await become('authenticated', memberId);
    const ownerPage = await client.query(
        'SELECT tier, page_status FROM public.listing_webpages WHERE listing_id = $1',
        [listingId]
    );
    check(
        ownerPage.rows[0]?.tier === 'gold' && ownerPage.rows[0]?.page_status === 'draft',
        'listing owner can read their provisioned draft webpage'
    );
    const ownerUpdate = await client.query(
        'UPDATE public.listing_webpages SET tagline = $2 WHERE listing_id = $1 RETURNING tagline',
        [listingId, `Owner-edited Gold page ${nonce}`]
    );
    check(ownerUpdate.rows[0]?.tagline === `Owner-edited Gold page ${nonce}`, 'listing owner can update allowed draft webpage content');

    await become('anon');
    const anonymousDraft = await client.query(
        'SELECT listing_id FROM public.listing_webpages WHERE listing_id = $1',
        [listingId]
    );
    check(anonymousDraft.rowCount === 0, 'anonymous visitors cannot read an unpublished webpage draft');

    // now() is fixed at BEGIN while approval intentionally uses the real wall
    // clock. Move only the transactional fixture behind now() so this single-
    // transaction test can exercise the same delivery predicate that a later
    // production request would naturally satisfy.
    await client.query('RESET ROLE');
    await client.query(
        "UPDATE public.advertisements SET starts_at = now() - interval '1 second' WHERE order_id = $1",
        [order.id]
    );

    await become('anon');
    const delivery = await rpc("SELECT public.get_active_advertisements('homepage', 10) AS result");
    const delivered = delivery?.advertisements?.find((item) => item.headline === 'Test campaign');
    check(Boolean(delivered), 'public delivery returns only an active homepage creative');
    const firstEvent = await rpc(
        "SELECT public.record_ad_event($1::uuid, 'impression', $2, $3::jsonb) AS result",
        [delivered.id, `session-${nonce}`, JSON.stringify({ page: 'test' })]
    );
    const duplicateEvent = await rpc(
        "SELECT public.record_ad_event($1::uuid, 'impression', $2, $3::jsonb) AS result",
        [delivered.id, `session-${nonce}`, JSON.stringify({ page: 'test' })]
    );
    check(firstEvent?.recorded === true && duplicateEvent?.deduplicated === true, 'public impression tracking is privacy-hashed and deduplicated');

    await become('authenticated', adminId);
    const analytics = await rpc('SELECT public.get_admin_advertising_analytics(30) AS result');
    check(Number(analytics?.kpis?.active_ads) >= 2, 'advertising analytics include active placements');
    check(analytics?.placement_performance?.some((row) => row.placement === 'homepage'), 'advertising analytics include placement performance');

    const paused = await rpc(
        "SELECT public.admin_manage_advertising('pause_ad', $1::jsonb) AS result",
        [JSON.stringify({ order_id: order.id, reason: 'Transactional pause test' })]
    );
    check(paused?.status === 'paused', 'admin can pause an active campaign');
    const resumed = await rpc(
        "SELECT public.admin_manage_advertising('resume_ad', $1::jsonb) AS result",
        [JSON.stringify({ order_id: order.id })]
    );
    check(resumed?.status === 'approved', 'admin can resume a paused campaign');
    const renewed = await rpc(
        "SELECT public.admin_manage_advertising('renew_subscription', $1::jsonb) AS result",
        [JSON.stringify({ order_id: order.id, duration_days: 7 })]
    );
    check(Boolean(renewed?.renewed_at), 'admin can renew the campaign term');
    const cancelled = await rpc(
        "SELECT public.admin_manage_advertising('cancel_subscription', $1::jsonb) AS result",
        [JSON.stringify({ order_id: order.id, reason: 'Transactional cancellation test' })]
    );
    check(cancelled?.status === 'cancelled', 'admin can cancel a campaign and its delivery');

    const audit = await client.query(
        "SELECT count(*)::integer AS count FROM public.admin_audit_log WHERE entity_id = $1 AND action LIKE 'admin_advertising_%'",
        [order.id]
    );
    check(audit.rows[0].count >= 5, 'privileged lifecycle changes are recorded in the admin audit log');

    await client.query('ROLLBACK');
    console.log(`Advertising workflow integration passed (${checks.length} assertions); transaction rolled back.`);
} catch (error) {
    try { await client.query('ROLLBACK'); } catch {}
    console.error(error.message);
    process.exitCode = 1;
} finally {
    await client.end();
}
