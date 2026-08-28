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
        '20260728000001_webpage_activation_draft.sql',
        '20260728000002_webpage_segment_sync.sql',
        '20260827175628_paid_webpage_promotion_analytics.sql'
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

    await client.query('SAVEPOINT reject_incomplete_payment_destination');
    let incompleteDestinationError = null;
    try {
        await rpc(
            "SELECT public.admin_manage_advertising('bank_upsert', $1::jsonb) AS result",
            [JSON.stringify({
                code: `incomplete-bank-${nonce}`,
                label: 'Incomplete active destination',
                currency: 'JMD',
                is_active: true
            })]
        );
    } catch (error) {
        incompleteDestinationError = error;
        await client.query('ROLLBACK TO SAVEPOINT reject_incomplete_payment_destination');
    }
    await client.query('RELEASE SAVEPOINT reject_incomplete_payment_destination');
    check(
        /payment_accounts_active_details_check/i.test(incompleteDestinationError?.message || ''),
        'database rejects an active payment destination without complete transfer details'
    );

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

    const silverWebpagePkg = await rpc(
        "SELECT public.admin_manage_advertising('package_upsert', $1::jsonb) AS result",
        [JSON.stringify({
            code: `test-webpage-silver-${nonce}`,
            name: 'Transactional Silver webpage package',
            description: 'Rolled back after webpage downgrade verification',
            product_type: 'webpage',
            webpage_tier: 'silver',
            price: 3456,
            currency: 'JMD',
            duration_days: 30,
            placements: ['directory-webpage'],
            features: ['Silver webpage builder'],
            payment_account_id: account.id,
            is_active: true,
            sort_order: 9997
        })]
    );
    check(
        silverWebpagePkg?.id && silverWebpagePkg.webpage_tier === 'silver',
        'admin can create the Silver package used for downgrade reconciliation'
    );

    const platinumWebpagePkg = await rpc(
        "SELECT public.admin_manage_advertising('package_upsert', $1::jsonb) AS result",
        [JSON.stringify({
            code: `test-webpage-platinum-${nonce}`,
            name: 'Transactional Platinum webpage package',
            description: 'Rolled back after webpage reactivation verification',
            product_type: 'webpage',
            webpage_tier: 'platinum',
            price: 7890,
            currency: 'JMD',
            duration_days: 30,
            placements: ['directory-webpage'],
            features: ['Platinum webpage builder'],
            payment_account_id: account.id,
            is_active: true,
            sort_order: 9996
        })]
    );
    check(
        platinumWebpagePkg?.id && platinumWebpagePkg.webpage_tier === 'platinum',
        'admin can create the Platinum package used for reactivation reconciliation'
    );

    const adminConfig = await rpc('SELECT public.admin_get_ad_configuration() AS result');
    check(adminConfig?.packages?.some((item) => item.id === pkg.id), 'admin configuration includes active and inactive package detail');
    check(adminConfig?.packages?.some((item) => item.id === webpagePkg.id), 'admin configuration includes the Gold webpage package');
    check(adminConfig?.packages?.some((item) => item.id === silverWebpagePkg.id), 'admin configuration includes the Silver downgrade package');
    check(adminConfig?.packages?.some((item) => item.id === platinumWebpagePkg.id), 'admin configuration includes the Platinum reactivation package');
    check(adminConfig?.payment_accounts?.some((item) => item.id === account.id), 'admin configuration includes bank-transfer destinations');

    // Use an isolated member-owned listing instead of modifying one of the
    // project's real directory entries. It is removed by the final rollback.
    await client.query('RESET ROLE');
    const listingFixture = await client.query(
        `INSERT INTO public.listings (
            business_name, owner_user_id, listing_type, status, market_segment,
            published_at, approved_at, expires_at
         ) VALUES (
            $1, $2, 'basic', 'pending', 'local-business',
            NULL, NULL, now() + interval '1 year'
         ) RETURNING id`,
        [`Transactional webpage listing ${nonce}`, memberId]
    );
    const listingId = listingFixture.rows[0]?.id;
    check(Boolean(listingId), 'a rollback-only member-owned listing is available for the webpage order');

    const manualListingFixture = await client.query(
        `INSERT INTO public.listings (
            business_name, owner_user_id, listing_type, status, market_segment,
            published_at, approved_at, expires_at
         ) VALUES (
            $1, $2, 'basic', 'approved', 'local-business',
            now() - interval '1 day', now() - interval '1 day', now() + interval '1 year'
         ) RETURNING id`,
        [`Manual activation listing ${nonce}`, memberId]
    );
    const manualListingId = manualListingFixture.rows[0]?.id;
    check(Boolean(manualListingId), 'a second rollback-only listing is available for the exact admin activation path');

    const reconciliationListingFixture = await client.query(
        `INSERT INTO public.listings (
            business_name, owner_user_id, listing_type, status, market_segment,
            published_at, approved_at, expires_at
         ) VALUES (
            $1, $2, 'basic', 'approved', 'local-business',
            now() - interval '1 day', now() - interval '1 day', now() + interval '1 year'
         ) RETURNING id`,
        [`Tier reconciliation listing ${nonce}`, memberId]
    );
    const reconciliationListingId = reconciliationListingFixture.rows[0]?.id;
    check(Boolean(reconciliationListingId), 'an isolated listing is available for tier and segment reconciliation tests');

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
        [webpagePkg.id, listingId, [], 'Transactional Gold webpage order', JSON.stringify({ promotion_style: 'spotlight' })]
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
    const pendingWebpageActivation = await client.query(
        `SELECT
            s.id AS subscription_id,
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
    const pendingActivatedWebpage = pendingWebpageActivation.rows[0];
    check(
        pendingActivatedWebpage?.subscription_status === 'active'
            && pendingActivatedWebpage.user_id === memberId
            && pendingActivatedWebpage.listing_id === listingId
            && pendingActivatedWebpage.package_id === webpagePkg.id,
        'payment confirmation creates the correct active listing subscription'
    );
    check(
        pendingActivatedWebpage?.tier === 'gold'
            && pendingActivatedWebpage.page_status === 'draft'
            && pendingActivatedWebpage.market_segment === 'local-business',
        'payment confirmation safely provisions a draft while its directory listing is still pending'
    );
    const pendingPromotion = await client.query(
        "SELECT id FROM public.advertisements WHERE listing_id = $1 AND placement = 'webpage-network'",
        [listingId]
    );
    check(pendingPromotion.rowCount === 0, 'a pending directory listing is not delivered as a public advertisement');

    await become('authenticated', adminId);
    await client.query(
        `UPDATE public.listings
         SET status = 'approved', approved_at = clock_timestamp(), published_at = now() - interval '1 second'
         WHERE id = $1`,
        [listingId]
    );
    await client.query('RESET ROLE');
    const webpageActivation = await client.query(
        `SELECT
            s.id AS subscription_id,
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
        activatedWebpage?.tier === 'gold'
            && activatedWebpage.page_status === 'published'
            && activatedWebpage.market_segment === 'local-business',
        'approving the directory listing publishes its safe paid starter page and unlocks promotion'
    );

    const webpagePromotionQuery = await client.query(
        `SELECT
            id,
            order_id,
            subscription_id,
            status,
            placement,
            cta_url,
            creative_metadata
         FROM public.advertisements
         WHERE listing_id = $1
           AND placement = 'webpage-network'`,
        [listingId]
    );
    const webpagePromotion = webpagePromotionQuery.rows[0];
    check(
        webpagePromotion?.status === 'active'
            && webpagePromotion.order_id === webpageOrder.id
            && webpagePromotion.subscription_id === activatedWebpage.subscription_id
            && webpagePromotion.creative_metadata?.source === 'paid_webpage'
            && webpagePromotion.creative_metadata?.format === 'spotlight',
        'paid webpage approval creates one active network promotion using the format selected with the order'
    );
    check(
        webpagePromotion?.cta_url === `https://www.ussehub.com/ajm-business-page?listing=${listingId}`,
        'the paid webpage promotion links to the extensionless business-page route without losing its listing ID'
    );

    await become('anon');
    const webpageDelivery = await rpc("SELECT public.get_active_advertisements('webpage-network', 20) AS result");
    const deliveredWebpage = webpageDelivery?.advertisements?.find((item) => item.id === webpagePromotion.id);
    check(
        deliveredWebpage?.listing_id === listingId && deliveredWebpage.rotation_key === undefined,
        'public delivery includes the active webpage promotion without exposing its internal rotation key'
    );
    const firstWebpageView = await rpc(
        "SELECT public.record_webpage_event($1::uuid, 'view', $2, $3::jsonb) AS result",
        [listingId, `webpage-session-${nonce}`, JSON.stringify({ page: 'integration-test' })]
    );
    const duplicateWebpageView = await rpc(
        "SELECT public.record_webpage_event($1::uuid, 'view', $2, $3::jsonb) AS result",
        [listingId, `webpage-session-${nonce}`, JSON.stringify({ page: 'integration-test' })]
    );
    const webpageClick = await rpc(
        "SELECT public.record_webpage_event($1::uuid, 'click', $2, $3::jsonb) AS result",
        [listingId, `webpage-session-${nonce}`, JSON.stringify({ action: 'website' })]
    );
    const webpageLead = await rpc(
        "SELECT public.record_webpage_event($1::uuid, 'lead', $2, $3::jsonb) AS result",
        [listingId, `webpage-session-${nonce}`, JSON.stringify({ action: 'contact-form' })]
    );
    check(
        firstWebpageView?.recorded === true
            && duplicateWebpageView?.deduplicated === true
            && webpageClick?.recorded === true
            && webpageLead?.recorded === true,
        'webpage views, clicks and leads are recorded with privacy-preserving daily deduplication'
    );
    const anonymousPublishedPage = await client.query(
        'SELECT listing_id FROM public.listing_webpages WHERE listing_id = $1',
        [listingId]
    );
    check(anonymousPublishedPage.rowCount === 1, 'anonymous visitors can read the published paid webpage');

    await become('authenticated', memberId);
    const ownerPage = await client.query(
        'SELECT tier, page_status FROM public.listing_webpages WHERE listing_id = $1',
        [listingId]
    );
    check(
        ownerPage.rows[0]?.tier === 'gold' && ownerPage.rows[0]?.page_status === 'published',
        'listing owner can read their published starter webpage'
    );
    const ownerUpdate = await client.query(
        `UPDATE public.listing_webpages
         SET
           tagline = $2,
           promotion_style = 'banner',
           promotion_headline = 'Owner-controlled banner',
           promotion_cta_label = 'See our services',
           starter_generated = false
         WHERE listing_id = $1
         RETURNING tagline, promotion_style`,
        [listingId, `Owner-edited Gold page ${nonce}`]
    );
    check(
        ownerUpdate.rows[0]?.tagline === `Owner-edited Gold page ${nonce}`
            && ownerUpdate.rows[0]?.promotion_style === 'banner',
        'listing owner can update webpage content and choose the network promotion format'
    );

    const pausedPromotion = await client.query(
        `UPDATE public.listing_webpages
         SET page_status = 'draft'
         WHERE listing_id = $1
         RETURNING page_status`,
        [listingId]
    );
    check(pausedPromotion.rows[0]?.page_status === 'draft', 'listing owner can save the webpage as a draft');
    await client.query('RESET ROLE');
    const pausedPromotionState = await client.query(
        "SELECT status FROM public.advertisements WHERE listing_id = $1 AND placement = 'webpage-network'",
        [listingId]
    );
    check(pausedPromotionState.rows[0]?.status === 'paused', 'saving a webpage as a draft immediately pauses network delivery');

    await become('authenticated', memberId);
    await client.query(
        "UPDATE public.listing_webpages SET page_status = 'published' WHERE listing_id = $1",
        [listingId]
    );
    const memberPerformance = await rpc('SELECT public.get_my_ad_performance(30) AS result');
    const memberWebpagePerformance = memberPerformance?.advertisements?.find((item) => item.listing_id === listingId);
    check(
        Number(memberPerformance?.kpis?.active_webpages) >= 1
            && Number(memberPerformance?.kpis?.live_campaigns) >= 1
            && Number(memberPerformance?.kpis?.impressions) >= 1
            && Number(memberPerformance?.kpis?.clicks) >= 1
            && Number(memberPerformance?.kpis?.leads) >= 1,
        'member reporting summarizes active webpages, live campaigns, impressions, clicks and leads'
    );
    check(
        memberWebpagePerformance?.format === 'banner'
            && Number(memberWebpagePerformance?.impressions) === 1
            && Number(memberWebpagePerformance?.clicks) === 1
            && Number(memberWebpagePerformance?.leads) === 1,
        'member reporting includes per-webpage format and engagement totals'
    );

    await become('authenticated', adminId);
    const pausedWebpageOrder = await rpc(
        "SELECT public.admin_manage_advertising('pause_ad', $1::jsonb) AS result",
        [JSON.stringify({ order_id: webpageOrder.id, reason: 'Transactional webpage pause test' })]
    );
    check(pausedWebpageOrder?.status === 'paused', 'admin can pause an approved paid webpage order');
    await client.query('RESET ROLE');
    const pausedWebpageLifecycle = await client.query(
        `SELECT a.status AS promotion_status, s.status AS subscription_status
         FROM public.advertisements a
         JOIN public.ad_subscriptions s ON s.id = a.subscription_id
         WHERE a.listing_id = $1
           AND a.placement = 'webpage-network'`,
        [listingId]
    );
    check(
        pausedWebpageLifecycle.rows[0]?.promotion_status === 'paused'
            && pausedWebpageLifecycle.rows[0]?.subscription_status === 'paused',
        'pausing a paid webpage keeps its promotion paused rather than incorrectly cancelling it'
    );

    await become('authenticated', adminId);
    const resumedWebpageOrder = await rpc(
        "SELECT public.admin_manage_advertising('resume_ad', $1::jsonb) AS result",
        [JSON.stringify({ order_id: webpageOrder.id })]
    );
    check(resumedWebpageOrder?.status === 'approved', 'admin can resume a paused paid webpage order');
    await client.query('RESET ROLE');
    const resumedWebpagePromotion = await client.query(
        "SELECT status, creative_metadata FROM public.advertisements WHERE listing_id = $1 AND placement = 'webpage-network'",
        [listingId]
    );
    check(
        resumedWebpagePromotion.rows[0]?.status === 'active'
            && resumedWebpagePromotion.rows[0]?.creative_metadata?.format === 'banner',
        'resuming the paid webpage restores delivery without overwriting the member’s newer format choice'
    );

    // Reproduce the exact AJM Paid Webpage modal lifecycle from the client's
    // screenshots. This path must not depend on an Edge Function.
    await become('authenticated', adminId);
    const manualActivation = await rpc(
        "SELECT public.admin_manage_listing_webpage('activate', $1::jsonb) AS result",
        [JSON.stringify({
            listing_id: manualListingId,
            package_code: webpagePkg.code,
            market_segment: 'professional-services',
            duration_days: 45,
            payment_reference: `MANUAL-${nonce}`
        })]
    );
    check(
        manualActivation?.subscriptions?.some((subscription) => subscription.status === 'active'),
        'AJM Paid Webpage activation returns an active subscription without an Edge Function'
    );

    await client.query('RESET ROLE');
    const manualState = await client.query(
        `SELECT
            l.market_segment AS listing_segment,
            l.requested_tier,
            s.id AS subscription_id,
            s.status AS subscription_status,
            s.expires_at,
            w.tier,
            w.market_segment AS webpage_segment,
            w.page_status
         FROM public.listings l
         JOIN public.ad_subscriptions s ON s.listing_id = l.id
         JOIN public.listing_webpages w ON w.listing_id = l.id
         WHERE l.id = $1
         ORDER BY s.created_at DESC, s.id DESC
         LIMIT 1`,
        [manualListingId]
    );
    const manuallyActivated = manualState.rows[0];
    check(
        manuallyActivated?.subscription_status === 'active'
            && manuallyActivated.requested_tier === 'gold'
            && manuallyActivated.tier === 'gold'
            && manuallyActivated.page_status === 'published',
        'manual activation publishes the correct safe Gold starter webpage'
    );
    check(
        manuallyActivated?.listing_segment === 'professional-services'
            && manuallyActivated.webpage_segment === 'professional-services',
        'manual activation synchronizes the administrator-selected segment to the starter webpage'
    );

    const manualPromotionQuery = await client.query(
        `SELECT order_id, subscription_id, status
         FROM public.advertisements
         WHERE listing_id = $1
           AND placement = 'webpage-network'`,
        [manualListingId]
    );
    check(
        manualPromotionQuery.rows[0]?.order_id === null
            && manualPromotionQuery.rows[0]?.subscription_id === manuallyActivated.subscription_id
            && manualPromotionQuery.rows[0]?.status === 'active',
        'admin-activated webpages receive tracked network promotion even when no customer order exists'
    );

    const firstManualExpiry = new Date(manuallyActivated.expires_at).getTime();
    await become('authenticated', adminId);
    const manualRenewal = await rpc(
        "SELECT public.admin_manage_listing_webpage('renew', $1::jsonb) AS result",
        [JSON.stringify({
            listing_id: manualListingId,
            duration_days: 60,
            market_segment: 'professional-services',
            payment_reference: `RENEW-${nonce}`
        })]
    );
    const renewedManualSubscription = manualRenewal?.subscriptions?.find((subscription) => subscription.status === 'active');
    check(
        new Date(renewedManualSubscription?.expires_at).getTime() > firstManualExpiry,
        'AJM Paid Webpage renewal extends the active access term'
    );

    const manualCancellation = await rpc(
        "SELECT public.admin_manage_listing_webpage('cancel', $1::jsonb) AS result",
        [JSON.stringify({
            listing_id: manualListingId,
            reason: 'Transactional manual cancellation test'
        })]
    );
    check(
        manualCancellation?.subscriptions?.some((subscription) => subscription.status === 'cancelled')
            && manualCancellation?.listing?.requested_tier === null,
        'AJM Paid Webpage cancellation removes paid access and the requested tier'
    );

    await client.query('RESET ROLE');
    const cancelledManualPromotion = await client.query(
        "SELECT status FROM public.advertisements WHERE listing_id = $1 AND placement = 'webpage-network'",
        [manualListingId]
    );
    check(
        ['cancelled', 'expired'].includes(cancelledManualPromotion.rows[0]?.status),
        'cancelling a manual webpage entitlement stops its network promotion'
    );

    const manualAudit = await client.query(
        `SELECT
            (SELECT count(*)::integer
             FROM public.admin_audit_log
             WHERE entity_id = $1
               AND action LIKE 'admin_listing_webpage_%') AS audit_count,
            (SELECT count(*)::integer
             FROM public.notification_outbox
             WHERE template_key IN (
               'ajm_webpage_activated',
               'ajm_webpage_renewed',
               'ajm_webpage_cancelled'
             )
               AND recipient_email = (SELECT lower(email) FROM public.profiles WHERE id = $2)) AS notification_count`,
        [manualListingId, memberId]
    );
    check(manualAudit.rows[0]?.audit_count === 3, 'every manual webpage lifecycle action is recorded in the admin audit log');
    check(manualAudit.rows[0]?.notification_count >= 3, 'manual activation, renewal and cancellation each queue a customer email');

    // Exercise an existing draft through cancellation, reactivation, downgrade,
    // segment reassignment and upgrade. The active package is the exact tier
    // source of truth, and lower tiers must never retain unavailable fields.
    await become('authenticated', adminId);
    await rpc(
        "SELECT public.admin_manage_listing_webpage('activate', $1::jsonb) AS result",
        [JSON.stringify({
            listing_id: reconciliationListingId,
            package_code: platinumWebpagePkg.code,
            market_segment: 'professional-services',
            duration_days: 30,
            payment_reference: `PLATINUM-${nonce}`
        })]
    );

    const premiumGallery = [
        'https://example.com/gallery-1.jpg',
        'https://example.com/gallery-2.jpg',
        'https://example.com/gallery-3.jpg',
        'https://example.com/gallery-4.jpg',
        'https://example.com/gallery-5.jpg'
    ];
    await client.query(
        `UPDATE public.listing_webpages
         SET
           page_status = 'draft',
           starter_generated = false,
           segment_content = $2::jsonb,
           gallery_urls = $3::text[],
           hero_media_url = 'https://example.com/hero.jpg',
           video_url = 'https://example.com/video.mp4',
           map_embed_url = 'https://example.com/map',
           offer_title = 'Premium offer',
           offer_details = 'Premium offer details',
           offer_code = 'PREMIUM',
           testimonials = '[{"quote":"Excellent"}]'::jsonb,
           lead_form_enabled = true,
           booking_url = 'https://example.com/book',
           virtual_tour_url = 'https://example.com/tour',
           call_tracking_phone = '+1-876-555-0100',
           live_chat_url = 'https://example.com/chat'
         WHERE listing_id = $1`,
        [
            reconciliationListingId,
            JSON.stringify({
                'professional-services': {
                    credentials: 'Licensed transactional specialist',
                    intake_url: 'https://example.com/intake'
                }
            }),
            premiumGallery
        ]
    );

    await rpc(
        "SELECT public.admin_manage_listing_webpage('cancel', $1::jsonb) AS result",
        [JSON.stringify({
            listing_id: reconciliationListingId,
            reason: 'Transactional reactivation test'
        })]
    );
    await rpc(
        "SELECT public.admin_manage_listing_webpage('activate', $1::jsonb) AS result",
        [JSON.stringify({
            listing_id: reconciliationListingId,
            package_code: silverWebpagePkg.code,
            market_segment: 'b2b-supplier',
            duration_days: 30,
            payment_reference: `SILVER-${nonce}`
        })]
    );

    await client.query('RESET ROLE');
    const silverReconciliation = await client.query(
        `SELECT
           w.tier,
           w.market_segment,
           w.segment_content,
           coalesce(array_length(w.gallery_urls, 1), 0) AS gallery_count,
           w.hero_media_url,
           w.video_url,
           w.map_embed_url,
           w.offer_title,
           w.offer_details,
           w.offer_code,
           jsonb_array_length(w.testimonials) AS testimonial_count,
           w.lead_form_enabled,
           w.booking_url,
           w.virtual_tour_url,
           w.call_tracking_phone,
           w.live_chat_url,
           p.webpage_tier AS active_tier
         FROM public.listing_webpages w
         JOIN public.ad_subscriptions s
           ON s.listing_id = w.listing_id
          AND s.status = 'active'
         JOIN public.ad_packages p ON p.id = s.package_id
         WHERE w.listing_id = $1
         ORDER BY s.created_at DESC, s.id DESC
         LIMIT 1`,
        [reconciliationListingId]
    );
    const silverPage = silverReconciliation.rows[0];
    check(
        silverPage?.tier === 'silver'
            && silverPage.active_tier === 'silver'
            && silverPage.market_segment === 'b2b-supplier'
            && JSON.stringify(silverPage.segment_content) === '{}',
        'cancelled Platinum draft reactivates at the exact Silver tier and selected segment'
    );
    check(
        Number(silverPage?.gallery_count) === 3
            && silverPage.hero_media_url === null
            && silverPage.video_url === null
            && silverPage.map_embed_url === null
            && silverPage.offer_title === null
            && silverPage.offer_details === null
            && silverPage.offer_code === null
            && Number(silverPage.testimonial_count) === 0
            && silverPage.lead_form_enabled === false
            && silverPage.booking_url === null
            && silverPage.virtual_tour_url === null
            && silverPage.call_tracking_phone === null
            && silverPage.live_chat_url === null,
        'Silver downgrade truncates the gallery and removes every unsupported Gold and Platinum field'
    );

    await become('authenticated', adminId);
    await rpc(
        "SELECT public.admin_manage_listing_webpage('activate', $1::jsonb) AS result",
        [JSON.stringify({
            listing_id: reconciliationListingId,
            package_code: platinumWebpagePkg.code,
            market_segment: 'hospitality-events',
            duration_days: 30,
            payment_reference: `UPGRADE-${nonce}`
        })]
    );

    await client.query('RESET ROLE');
    const platinumUpgrade = await client.query(
        `SELECT w.tier, w.market_segment, w.segment_content, p.webpage_tier AS active_tier
         FROM public.listing_webpages w
         JOIN public.ad_subscriptions s
           ON s.listing_id = w.listing_id
          AND s.status = 'active'
         JOIN public.ad_packages p ON p.id = s.package_id
         WHERE w.listing_id = $1
         ORDER BY s.created_at DESC, s.id DESC
         LIMIT 1`,
        [reconciliationListingId]
    );
    check(
        platinumUpgrade.rows[0]?.tier === 'platinum'
            && platinumUpgrade.rows[0]?.active_tier === 'platinum'
            && platinumUpgrade.rows[0]?.market_segment === 'hospitality-events'
            && JSON.stringify(platinumUpgrade.rows[0]?.segment_content) === '{}',
        'switching an existing draft upgrades it to the exact Platinum tier and new segment'
    );

    // A package conflict on a published page must preserve authored content.
    // The system unpublishes it for explicit review instead of silently
    // truncating premium fields or clearing segment-specific content.
    await become('authenticated', adminId);
    const publishedSegmentContent = {
        'hospitality-events': {
            availability_url: 'https://example.com/availability',
            portfolio_url: 'https://example.com/portfolio'
        }
    };
    await client.query(
        `UPDATE public.listing_webpages
         SET
           page_status = 'published',
           segment_content = $2::jsonb,
           gallery_urls = $3::text[],
           booking_url = 'https://example.com/published-booking'
         WHERE listing_id = $1`,
        [reconciliationListingId, JSON.stringify(publishedSegmentContent), premiumGallery]
    );
    await rpc(
        "SELECT public.admin_manage_listing_webpage('activate', $1::jsonb) AS result",
        [JSON.stringify({
            listing_id: reconciliationListingId,
            package_code: silverWebpagePkg.code,
            market_segment: 'local-business',
            duration_days: 30,
            payment_reference: `PUBLISHED-DOWNGRADE-${nonce}`
        })]
    );

    await client.query('RESET ROLE');
    const preservedPublishedPage = await client.query(
        `SELECT
           l.requested_tier,
           w.tier,
           w.market_segment,
           w.page_status,
           w.segment_content,
           w.gallery_urls,
           w.booking_url,
           p.webpage_tier AS active_tier
         FROM public.listings l
         JOIN public.listing_webpages w ON w.listing_id = l.id
         JOIN public.ad_subscriptions s
           ON s.listing_id = l.id
          AND s.status = 'active'
         JOIN public.ad_packages p ON p.id = s.package_id
         WHERE l.id = $1
         ORDER BY s.created_at DESC, s.id DESC
         LIMIT 1`,
        [reconciliationListingId]
    );
    const preservedPage = preservedPublishedPage.rows[0];
    check(
        preservedPage?.requested_tier === 'silver'
            && preservedPage.active_tier === 'silver'
            && preservedPage.page_status === 'draft'
            && preservedPage.tier === 'platinum'
            && preservedPage.market_segment === 'hospitality-events',
        'an incompatible published page is explicitly unpublished for package review'
    );
    check(
        preservedPage?.segment_content?.['hospitality-events']?.availability_url
            === publishedSegmentContent['hospitality-events'].availability_url
            && preservedPage?.segment_content?.['hospitality-events']?.portfolio_url
                === publishedSegmentContent['hospitality-events'].portfolio_url
            && preservedPage.gallery_urls?.length === premiumGallery.length
            && preservedPage.booking_url === 'https://example.com/published-booking',
        'published segment content, gallery and Platinum fields remain intact after the package conflict'
    );

    const reconciliationAudit = await client.query(
        `SELECT
           count(*) FILTER (
             WHERE action = 'listing_webpage_draft_reconciled'
           )::integer AS draft_reconciliations,
           count(*) FILTER (
             WHERE action = 'listing_webpage_unpublished_for_package_review'
               AND before_state->>'page_status' = 'published'
               AND after_state->>'page_status' = 'draft'
           )::integer AS protected_unpublishes
         FROM public.admin_audit_log
         WHERE entity_type = 'listing_webpage'
           AND entity_id = $1`,
        [reconciliationListingId]
    );
    check(
        reconciliationAudit.rows[0]?.draft_reconciliations >= 4,
        'draft tier and segment reconciliations retain complete before/after audit snapshots'
    );
    check(
        reconciliationAudit.rows[0]?.protected_unpublishes === 1,
        'published-content protection is explicitly recorded in the admin audit log'
    );

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

    const adminDelivery = await rpc('SELECT public.get_admin_advertisement_delivery(30) AS result');
    const trackedWebpagePromotion = adminDelivery?.advertisements?.find((item) => item.listing_id === listingId);
    check(
        trackedWebpagePromotion?.placement === 'webpage-network'
            && Number(trackedWebpagePromotion?.impressions) === 1
            && Number(trackedWebpagePromotion?.clicks) === 1
            && Number(trackedWebpagePromotion?.leads) === 1
            && Number(trackedWebpagePromotion?.ctr) === 100,
        'admin campaign delivery exposes webpage impressions, clicks, leads and click-through rate'
    );

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
