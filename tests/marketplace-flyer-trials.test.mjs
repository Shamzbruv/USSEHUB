process.on('uncaughtException',e=>{console.error(e.message,e.where||'',e.query||'');process.exit(1)});process.on('unhandledRejection',e=>{console.error(e.message,e.where||'',e.query||'');process.exit(1)});
import assert from'node:assert/strict';import fs from'node:fs';import{PGlite}from'@electric-sql/pglite';
import{MARKET_CATEGORIES,marketCard,marketplacePreviewOrder,marketplacePreviewTile,secureUrl,validateMarketImage}from'../assets/usse-marketplace-core.mjs';
import{renderMarketplace,marketplaceImage,marketplaceVideo}from'../server/marketplace.mjs';
const db=new PGlite(),admin=crypto.randomUUID(),member=crypto.randomUUID(),other=crypto.randomUUID(),lid=crypto.randomUUID(),silver=crypto.randomUUID(),platinum=crypto.randomUUID(),banner=crypto.randomUUID();
await db.exec(`CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;CREATE SCHEMA auth;CREATE SCHEMA private;CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$SELECT nullif(current_setting('test.uid',true),'')::uuid$$;
CREATE TABLE public.profiles(id uuid PRIMARY KEY,role text,account_status text);CREATE TABLE auth.users(id uuid PRIMARY KEY,email_confirmed_at timestamptz);
CREATE FUNCTION private.app_is_admin(uid uuid) RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=uid AND role='admin' AND account_status='active')$$;
CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);CREATE TABLE storage.objects(id uuid DEFAULT gen_random_uuid(),bucket_id text,name text,metadata jsonb);ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.listings(id uuid PRIMARY KEY,owner_user_id uuid,status text,expires_at timestamptz,published_at timestamptz,business_name text,market_segment text,description text,image_url text,location text);
CREATE TABLE public.ad_packages(id uuid PRIMARY KEY,name text,product_type text,placements text[],webpage_tier text,is_active boolean DEFAULT true,webpage_enabled boolean DEFAULT false,sort_order int);
CREATE TABLE public.ad_subscriptions(id uuid PRIMARY KEY,user_id uuid,listing_id uuid,package_id uuid,status text,payment_method text,payment_reference text,expires_at timestamptz);
CREATE TABLE public.advertisements(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),subscription_id uuid,user_id uuid,listing_id uuid,package_id uuid,placement text,headline text,body_text text,cta_label text,cta_url text,creative_metadata jsonb,starts_at timestamptz,expires_at timestamptz,status text DEFAULT 'active');
CREATE TABLE public.ad_events(id uuid DEFAULT gen_random_uuid(),advertisement_id uuid,event_type text,occurred_on date DEFAULT current_date,metadata jsonb DEFAULT '{}');
CREATE TABLE public.listing_webpages(listing_id uuid PRIMARY KEY,tier text,market_segment text,page_status text,tagline text,logo_url text,address text,about_text text,created_by uuid,starter_generated boolean,gallery_urls text[] DEFAULT '{}',booking_url text,virtual_tour_url text,call_tracking_phone text,live_chat_url text,hero_media_url text,video_url text,map_embed_url text,offer_title text,offer_details text,offer_code text,testimonials jsonb DEFAULT '[]',lead_form_enabled boolean DEFAULT false);
CREATE FUNCTION private.ensure_active_webpage_draft() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
 RETURN NEW;
END $f$;
CREATE TRIGGER test_ensure AFTER INSERT ON public.ad_subscriptions FOR EACH ROW EXECUTE FUNCTION private.ensure_active_webpage_draft();
CREATE FUNCTION private.sync_listing_webpage_promotion(uuid) RETURNS jsonb LANGUAGE sql AS $$SELECT '{}'::jsonb$$;
CREATE FUNCTION private.can_manage_listing_webpage(uuid,text,uuid) RETURNS boolean LANGUAGE sql AS $$SELECT true$$;
CREATE FUNCTION private.ajm_tier_rank(text) RETURNS int LANGUAGE sql AS $$SELECT CASE $1 WHEN 'silver' THEN 1 WHEN 'gold' THEN 2 WHEN 'platinum' THEN 3 ELSE 0 END$$;
GRANT USAGE ON SCHEMA public,private,auth,storage TO anon,authenticated;GRANT SELECT,INSERT ON storage.objects TO anon,authenticated;`);
await db.exec('GRANT SELECT ON public.listing_webpages,public.ad_subscriptions,public.advertisements TO authenticated;GRANT INSERT ON public.ad_events TO authenticated;');
await db.query(`INSERT INTO public.profiles VALUES($1,'admin','active'),($2,'member','active'),($3,'member','active')`,[admin,member,other]);await db.exec('INSERT INTO auth.users SELECT id,now() FROM public.profiles');
await db.query(`INSERT INTO public.listings VALUES($1,$2,'approved',null,null,'Real test business','local-business','Actual business information for tests',null,'Kingston')`,[lid,member]);
await db.query(`INSERT INTO public.ad_packages VALUES($1,'Silver','webpage','{}','silver',true,true,10),($2,'Platinum','webpage','{}','platinum',true,true,20),($3,'Banner','display_ad',ARRAY['marketplace-top'],null,true,false,30)`,[silver,platinum,banner]);
await db.exec(fs.readFileSync('supabase/migrations/20261110153000_marketplace_flyers_and_complimentary_trials.sql','utf8'));
async function as(uid='',role='authenticated'){await db.exec(`RESET ROLE;SELECT set_config('test.uid','${uid}',false);SET ROLE ${role};`);}async function call(name,action,payload={}){return(await db.query(`SELECT public.${name}($1,$2::jsonb) AS r`,[action,JSON.stringify(payload)])).rows[0].r;}const manage=(a,p)=>call('manage_marketplace',a,p),trial=(a,p)=>call('manage_ajm_trials',a,p),browse=async p=>(await db.query('SELECT public.marketplace_public($1) r',[p||{}])).rows[0].r;
const payload={id:crypto.randomUUID(),request_id:crypto.randomUUID(),business_name:'A real test business',title:'Products for local customers',tagline:'Suppliers serving Jamaican businesses',category:MARKET_CATEGORIES[0],contact_url:'https://example.test',mime:'image/png',file_size:50,permission_confirmed:true,display_days:30};
await as('','anon');await assert.rejects(manage('reserve',payload),/permission denied/);await assert.rejects(trial('catalog'),/permission denied/);
await as(member);await assert.rejects(trial('catalog'),/administrator/);await assert.rejects(manage('reserve',{...payload,ajm_sponsored:true}),/administrators/);await assert.rejects(manage('reserve',{...payload,mime:'image/svg+xml'}),/5 MB/);await assert.rejects(manage('reserve',{...payload,file_size:5242881}),/5 MB/);await assert.rejects(manage('reserve',{...payload,contact_url:'https://user:secret@example.test'}),/secure/);await assert.rejects(manage('reserve',{...payload,permission_confirmed:false}),/permission/);
const reserved=await manage('reserve',payload);assert.equal((await manage('reserve',payload)).path,reserved.path);await assert.rejects(manage('reserve',{...payload,title:'Changed request'}),/already used/);await assert.rejects(manage('submit',{id:payload.id}),/incomplete/);
await as(other);await assert.rejects(manage('submit',{id:payload.id}),/own flyers/);await assert.rejects(db.query('INSERT INTO storage.objects(bucket_id,name,metadata) VALUES($1,$2,$3)',['marketplace-flyers',reserved.path,{mimetype:'image/png',size:50}]),/row-level security/);
await as(member);await db.query('INSERT INTO storage.objects(bucket_id,name,metadata) VALUES($1,$2,$3)',['marketplace-flyers',reserved.path,{mimetype:'image/png',size:50}]);assert.equal((await manage('submit',{id:payload.id})).status,'pending');assert.equal((await manage('submit',{id:payload.id})).duplicate,true);await assert.rejects(manage('review',{id:payload.id,status:'published'}),/Administrator/);
const second={...payload,id:crypto.randomUUID(),request_id:crypto.randomUUID()},two=await manage('reserve',second);await db.query('INSERT INTO storage.objects(bucket_id,name,metadata) VALUES($1,$2,$3)',['marketplace-flyers',two.path,{mimetype:'image/png',size:50}]);await assert.rejects(manage('submit',{id:second.id}),/seven days/);
await as('','anon');assert.equal((await browse()).total,0);assert.equal((await db.query("SELECT * FROM storage.objects WHERE name=$1",[reserved.path])).rows.length,0);
await as(admin);await manage('review',{id:payload.id,status:'published'});await as('','anon');assert.equal((await browse()).total,1);assert.equal((await db.query("SELECT * FROM storage.objects WHERE name=$1",[reserved.path])).rows.length,1);assert(!JSON.stringify(await browse()).includes(member));
await as(member);await manage('withdraw',{id:payload.id});await as('','anon');assert.equal((await browse()).total,0);assert.equal((await db.query("SELECT * FROM storage.objects WHERE name=$1",[reserved.path])).rows.length,0);
await db.exec('RESET ROLE');
await db.exec(fs.readFileSync('supabase/migrations/20261114190000_marketplace_quick_publish_edit.sql', 'utf8'));
await as(admin);
const quickPoster = {
    ...payload,
    id: crypto.randomUUID(),
    request_id: crypto.randomUUID(),
    title: 'Marketplace flyer',
    business_name: 'Business details on flyer',
    tagline: 'See the flyer for details.',
    category: 'General',
    contact_url: '',
    ajm_sponsored: true
};
const posterPath = (await manage('reserve', quickPoster)).path;
await db.query('INSERT INTO storage.objects(bucket_id,name,metadata) VALUES($1,$2,$3)', [
    'marketplace-flyers', posterPath, { mimetype: 'image/png', size: 50 }
]);
assert.equal((await manage('submit', { id: quickPoster.id })).status, 'published');
const original = (await manage('list')).rows.find(row => row.id === quickPoster.id);
const edit = {
    id: quickPoster.id,
    expected_updated_at: original.updated_at,
    title: 'New Marketplace title',
    business_name: 'Verified business name',
    tagline: 'Updated description for customers',
    category: 'Business Services',
    contact_url: 'https://example.test/contact',
    image_path: 'ignored.png',
    status: 'withdrawn'
};
await as(member);
await assert.rejects(manage('edit', edit), /own flyers/);
await as(admin);
await assert.rejects(manage('edit', { ...edit, contact_url: 'javascript:alert(1)' }), /secure/);
const saved = await manage('edit', edit);
assert.equal((await manage('edit', edit)).updated_at, saved.updated_at, 'Retrying cannot change the revision');
await assert.rejects(manage('edit', { ...edit, title: 'Stale edit' }), /changed since you opened/);
const updated = (await manage('list')).rows.find(row => row.id === quickPoster.id);
for (const name of ['image_path', 'published_at', 'expires_at', 'submitted_at', 'owner_id', 'status', 'ajm_sponsored']) {
    assert.equal(updated[name], original[name], name + ' must survive text edits');
}
await as('', 'anon');
await assert.rejects(manage('edit', edit), /permission denied/);
assert.equal((await browse({ id: quickPoster.id })).rows[0].title, edit.title);
assert.equal((await browse({ category: 'Business Services', search: 'Updated description' })).rows[0].contact_url, edit.contact_url);

await as(member);
const memberPoster = { ...payload, id: crypto.randomUUID(), request_id: crypto.randomUUID() };
const memberPath = (await manage('reserve', memberPoster)).path;
await db.exec("RESET ROLE;UPDATE public.marketplace_flyers SET submitted_at=now()-interval '8 days' WHERE status='withdrawn'");
await as(member);
await db.query('INSERT INTO storage.objects(bucket_id,name,metadata) VALUES($1,$2,$3)', [
    'marketplace-flyers', memberPath, { mimetype: 'image/png', size: 50 }
]);
assert.equal((await manage('submit', { id: memberPoster.id })).status, 'pending');
await as(admin);
await manage('review', { id: memberPoster.id, status: 'published' });
await as(member);
await assert.rejects(manage('edit', { ...edit, id: memberPoster.id }), /administrators/);
await db.exec('RESET ROLE');
await db.exec(fs.readFileSync('supabase/migrations/20261115010000_marketplace_segments_mini_ads.sql', 'utf8'));
await db.exec(fs.readFileSync('supabase/migrations/20261118203534_admin_business_taxonomy.sql', 'utf8'));
const catalog = async () => (await db.query('SELECT public.business_taxonomy() result')).rows[0].result;
const addChoice = async (scope, parent, name) => (await db.query(
    'SELECT public.add_business_taxonomy_entry($1,$2,$3) result', [scope, parent, name]
)).rows[0].result;
await as('', 'anon');
assert.ok((await catalog()).marketplace['Transport & Logistics'].includes('Car Rental Services'));
assert.ok((await catalog()).marketplace['Events & Entertainment'].includes('Gospel Concerts'));
await assert.rejects(db.query('SELECT * FROM private.business_taxonomies'), /permission denied/);
await assert.rejects(addChoice('marketplace', [], 'Unauthorized category'), /permission denied/);
await as(member);
await assert.rejects(addChoice('marketplace', [], 'Unauthorized category'), /administrator/);
await as(admin);
await assert.rejects(addChoice('marketplace', ['Missing parent'], 'New service'), /parent category/);
await assert.rejects(addChoice('marketplace', [], '__proto__'), /name between/);
await assert.rejects(addChoice('marketplace', ['General', 'Missing level'], 'New service'), /valid parent/);
await addChoice('marketplace', [], 'New market category');
const expanded = await addChoice('marketplace', ['New market category'], 'New service');
assert.deepEqual(expanded['New market category'], ['New service']);
assert.deepEqual(await addChoice('marketplace', ['New market category'], 'NEW SERVICE'), expanded, 'Retries and case variants do not create duplicates');
await addChoice('directory', [], 'NEW DIRECTORY CATEGORY');
await addChoice('directory', ['NEW DIRECTORY CATEGORY'], 'NEW SUBCATEGORY');
await addChoice('directory', ['NEW DIRECTORY CATEGORY', 'NEW SUBCATEGORY'], 'NEW SPECIALIZATION');
await addChoice('directory', ['NEW DIRECTORY CATEGORY', 'NEW SUBCATEGORY', 'NEW SPECIALIZATION'], 'NEW TYPE');
assert.deepEqual((await catalog()).directory['NEW DIRECTORY CATEGORY']['NEW SUBCATEGORY'], {
    tertiary: ['NEW SPECIALIZATION'], specific: ['NEW TYPE']
});
await assert.rejects(addChoice('directory', ['NEW DIRECTORY CATEGORY', 'MISSING'], 'Invalid specialization'), /selected category/);
const newCategoryDraft = { ...quickPoster, id: crypto.randomUUID(), request_id: crypto.randomUUID(), category: 'New market category', segment: 'New service' };
assert.match((await manage('reserve', newCategoryDraft)).path, /\.png$/);
await assert.rejects(manage('reserve', { ...newCategoryDraft, id: crypto.randomUUID(), segment: 'Gospel Concerts' }), /selected category/);

await as(member);
const memberOriginal = (await manage('list')).rows.find(row => row.id === memberPoster.id);
const corrected = {
    ...edit, id: memberPoster.id, expected_updated_at: memberOriginal.updated_at,
    category: 'Fashion & Retail', segment: 'Retail Clothing'
};
assert.equal((await manage('edit', corrected)).status, 'pending');
assert.equal((await browse({ id: memberPoster.id })).total, 0);
await as(other);
await assert.rejects(manage('edit', corrected), /own flyers/);
await as(admin);
await manage('review', { id: memberPoster.id, status: 'published' });
const memberUpdated = (await manage('list')).rows.find(row => row.id === memberPoster.id);
assert.equal(memberUpdated.expires_at, memberOriginal.expires_at);
assert.equal(memberUpdated.published_at, memberOriginal.published_at);
assert.equal((await browse({ category: 'Fashion & Retail', segment: 'Retail Clothing' })).total, 1);
await assert.rejects(manage('edit', { ...corrected, segment: 'Haulage Services' }), /selected category/);
await manage('withdraw', { id: memberPoster.id });

const video = {
    ...quickPoster, id: crypto.randomUUID(), request_id: crypto.randomUUID(),
    mime: 'video/mp4', file_size: 150, category: 'Fashion & Retail', segment: 'Fashion Industry'
};
const videoPath = (await manage('reserve', video)).path;
assert.match(videoPath, /\.mp4$/);
await db.query('INSERT INTO storage.objects(bucket_id,name,metadata) VALUES($1,$2,$3)', [
    'marketplace-flyers', videoPath, { mimetype: 'video/mp4', size: 150 }
]);
await assert.rejects(manage('submit', { id: video.id }), /pass video validation/);
await assert.rejects(db.query('SELECT public.mark_marketplace_video_verified($1,$2,12000)', [video.id, videoPath]), /permission denied/);
await db.exec('RESET ROLE');
assert.equal((await db.query('SELECT public.mark_marketplace_video_verified($1,$2,15001) verified', [video.id, videoPath])).rows[0].verified, false);
assert.equal((await db.query('SELECT public.mark_marketplace_video_verified($1,$2,12000) verified', [video.id, videoPath])).rows[0].verified, true);
await as(admin);
assert.equal((await manage('submit', { id: video.id })).status, 'published');
assert.equal((await browse({format:'mini-ad'})).rows[0].video_duration_ms, 12000);
assert.match(marketCard({ ...video, video_duration_ms: 12000 }), /<video controls playsinline/);

const signedPath = '/object/sign/marketplace-flyers/' + videoPath;
const verifiedVideo = { ...video, video_duration_ms: 12000, image_path: videoPath };
const videoFetch = async url => {
    if (url.includes('/rpc/marketplace_public')) return Response.json({ rows: [verifiedVideo], total: 1 });
    assert(url.endsWith('/marketplace-flyers/' + videoPath));
    return Response.json({ signedURL: signedPath + '?token=test' });
};
assert.match(await marketplaceVideo(video.id, videoFetch), /\.mp4\?token=test$/);
const unverifiedVideoFetch = async () => Response.json({ rows: [{ ...verifiedVideo, video_duration_ms: null }], total: 1 });
assert.equal(await marketplaceVideo(video.id, unverifiedVideoFetch), null);
const miniAdPage = await renderMarketplace(new URL('https://ussehub.com/marketplace?id=' + video.id), process.cwd(), videoFetch);
assert.match(miniAdPage.body, /Share this mini-ad/);
assert.match(miniAdPage.body, /<video controls playsinline/);

await manage('withdraw', { id: video.id });

await db.query("RESET ROLE");
await db.query("UPDATE public.marketplace_flyers SET expires_at=now()-interval '1 second' WHERE id=$1", [quickPoster.id]);
await as('', 'anon');
assert.equal((await browse()).total, 0);
assert.equal((await db.query('SELECT * FROM storage.objects')).rows.length, 0);
console.log('Quick poster workflow passed: direct admin publish, live edits, revision conflicts, stable publication dates and artwork, and member/anonymous access checks.');
await db.exec(`RESET ROLE;INSERT INTO public.ad_subscriptions(id,user_id,listing_id,package_id,status,payment_method,expires_at) VALUES(gen_random_uuid(),'${member}','${lid}','${silver}','active','bank',now()+interval '60 days');INSERT INTO public.listing_webpages(listing_id,tier,page_status,gallery_urls,booking_url,created_by) VALUES('${lid}','silver','published',ARRAY['1','2','3'],'https://book.example.test','${member}');`);
await as(admin);const tp={id:crypto.randomUUID(),listing_id:lid,package_id:platinum,cohort:'internal',duration_days:30,consent:true};const before=(await db.query('SELECT * FROM public.listing_webpages')).rows[0];assert.equal((await trial('activate',tp)).complimentary,true);assert.equal((await trial('activate',tp)).duplicate,true);assert.deepEqual((await db.query('SELECT * FROM public.listing_webpages')).rows[0],before);await assert.rejects(trial('activate',{...tp,id:crypto.randomUUID()}),/already has/);
await db.exec(`RESET ROLE;UPDATE public.listing_webpages SET tier='platinum' WHERE listing_id='${lid}'`);await as('','anon');let page=(await db.query('SELECT public.public_entitled_webpage($1) r',[lid])).rows[0].r;assert.equal(page.tier,'platinum');assert.equal(page.booking_url,'https://book.example.test');assert.equal(page.created_by,undefined);
await db.exec(`RESET ROLE;UPDATE public.ad_subscriptions SET expires_at=now()-interval '1 second' WHERE trial_id='${tp.id}'`);await as('','anon');page=(await db.query('SELECT public.public_entitled_webpage($1) r',[lid])).rows[0].r;assert.equal(page.tier,'silver');assert.equal(page.booking_url,null);await db.exec('RESET ROLE');assert.equal((await db.query('SELECT booking_url FROM public.listing_webpages')).rows[0].booking_url,'https://book.example.test');
await as(admin);await trial('end',{id:tp.id});assert.equal((await db.query("SELECT count(*)::int n FROM public.ad_subscriptions WHERE trial_id IS NULL AND status='active'")).rows[0].n,1);
const dp={id:crypto.randomUUID(),listing_id:lid,package_id:banner,cohort:'public',duration_days:30,consent:true,headline:'Real advertiser headline',body_text:'Actual products for local customers',cta_url:'https://example.test',media_url:'https://example.test/art.png',banner_size:'rectangle'};await assert.rejects(trial('activate',{...dp,duration_days:15}),/30 days/);await trial('activate',dp);const ad=(await db.query("SELECT * FROM public.advertisements WHERE placement='marketplace-top'")).rows[0];assert.equal(ad.creative_metadata.source,'complimentary_trial');await db.query('INSERT INTO public.ad_events(advertisement_id,event_type,metadata) VALUES($1,$2,$3)',[ad.id,'click',{trial_id:'forged'}]);assert.equal((await trial('list')).rows.find(t=>t.id===dp.id).clicks,1);await trial('end',{id:dp.id});assert.equal((await db.query('SELECT status FROM public.advertisements WHERE id=$1',[ad.id])).rows[0].status,'cancelled');const publicCatalogSnapshot = await catalog();await db.close();
assert.equal(secureUrl('javascript:alert(1)'), '');assert.equal(secureUrl('https://user:secret@example.test'),'');const card=marketCard({...payload,title:'<script>alert(1)</script>'});assert(!card.includes('<script>'));assert(card.includes('&lt;script&gt;'));const png=new File([new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,0])],'flyer.png',{type:'image/png'});assert.equal((await validateMarketImage(png)).mime,'image/png');await assert.rejects(validateMarketImage(new File(['<svg/>'],'bad.svg')),/JPG/);
const fake=async()=>new Response(JSON.stringify({rows:[{...payload,image_path:payload.id+'/'+crypto.randomUUID()+'.png'}],total:1}),{status:200});const rendered=await renderMarketplace(new URL('https://ussehub.com/marketplace?id='+payload.id),process.cwd(),fake);assert.equal(rendered.status,200);assert(rendered.body.includes('application/ld+json'));assert(rendered.body.includes('/marketplace/flyers/'+payload.id));assert.equal((await renderMarketplace(new URL('https://ussehub.com/marketplace?id=invalid'),process.cwd(),fake)).status,404);assert.equal(await marketplaceImage('invalid',fake),null);
console.log('Marketplace passed: role isolation, private uploads, moderation, permission checks, weekly limits, retries, withdrawal/expiry, real-business trials, paid preservation, automatic entitlement fallback, accurate trial event attribution, safe images/links and server-rendered share pages.');

// The public browse route uses six records per page, while the showcase pools
// approved flyers across categories and keeps the full detail route intact.
const sampleFlyers = Array.from({ length: 13 }, (_, index) => ({
    ...payload,
    id: crypto.randomUUID(),
    title: `Test flyer ${index + 1}`,
    category: index % 2 ? 'Hardware' : 'Suppliers'
}));

const fixture = async (_url, options) => {
    if (String(_url).endsWith('/business_taxonomy')) return Response.json(publicCatalogSnapshot);
    const { p_payload: filter } = JSON.parse(options.body);
    const matching = sampleFlyers.filter(item =>
        (!filter.id || item.id === filter.id) &&
        (!filter.category || item.category === filter.category) &&
        (!filter.search || item.title.includes(filter.search))
    );
    const offset = filter.offset || 0;
    return Response.json({ rows: matching.slice(offset, offset + 24), total: matching.length });
};

const browsePage = path => renderMarketplace(new URL(path, 'https://ussehub.com'), process.cwd(), fixture);
const visibleCards = html => [...html.matchAll(/class="market-card flyer-card flyer-card-compact"/g)].length;
const firstPage = await browsePage('/marketplace');
assert.equal(visibleCards(firstPage.body), 6);
assert.match(firstPage.body, /New market category/);
assert.match(firstPage.body, /Gospel Concerts/);
assert.match(firstPage.body, /1–6 of 13 posts/);
assert.match(firstPage.body, /href="\/marketplace\?offset=6#marketplace-results"/);

const secondPage = await browsePage('/marketplace?offset=6');
assert.equal(visibleCards(secondPage.body), 6);
assert.match(secondPage.body, /7–12 of 13 posts/);
assert.match(secondPage.body, /href="\/marketplace\?offset=12#marketplace-results"/);
assert.equal(secondPage.noindex, true);

const lastPage = await browsePage('/marketplace?offset=12');
assert.equal(visibleCards(lastPage.body), 1);
assert.match(lastPage.body, /13–13 of 13 posts/);
assert.doesNotMatch(lastPage.body, /Next →/);

const filtered = await browsePage('/marketplace?category=Suppliers');
assert.equal(visibleCards(filtered.body), 6);
assert.match(filtered.body, /category=Suppliers&amp;offset=6/);
const previewPool = JSON.parse(filtered.body.match(/id="marketplace-previews" type="application\/json">(.*?)<\/script>/)[1]);
assert.equal(previewPool.length, 13);
assert.deepEqual(Object.keys(previewPool[0]), ['id', 'title', 'mime']);

assert.equal((await browsePage('/marketplace?offset=18')).status, 404);
assert.equal(visibleCards(rendered.body), 0);
assert.match(rendered.body, /class="market-grid flyer-grid marketplace-detail"/);
assert.doesNotMatch(firstPage.body, /id="marketplace-share"/);
assert.match(firstPage.body, /View &amp; share/);
const sharePage = await browsePage('/marketplace?id=' + sampleFlyers[0].id + '&ref=directory#marketplace-results');
const expectedShareUrl = 'https://ussehub.com/marketplace?id=' + sampleFlyers[0].id;
assert.match(sharePage.body, /id="marketplace-share"/);
assert.match(sharePage.body, /data-copy-flyer hidden>Copy link/);
assert.match(sharePage.body, /data-share-flyer hidden>More apps/);
const shareLinks = Object.fromEntries(
    [...sharePage.body.matchAll(/<a class="button" href="([^"]+)"(?: target="_blank" rel="noopener noreferrer")?>(WhatsApp|Facebook|X|LinkedIn|Telegram|Email)<\/a>/g)]
        .map(([, href, name]) => [name, new URL(href.replaceAll('&amp;', '&'))])
);
assert.equal(shareLinks.WhatsApp.searchParams.get('text'), 'Test flyer 1 | AJM Marketplace\n' + expectedShareUrl);
assert.equal(shareLinks.Facebook.searchParams.get('u'), expectedShareUrl);
for (const name of ['X', 'LinkedIn', 'Telegram']) {
    assert.equal(shareLinks[name].searchParams.get('url'), expectedShareUrl);
}
assert.equal(shareLinks.Email.searchParams.get('body'), 'Test flyer 1 | AJM Marketplace\n' + expectedShareUrl);

for (const size of [0, 1, 2, 3, 4, 6, 13]) {
    const pool = sampleFlyers.slice(0, size);
    const before = marketplacePreviewOrder(pool);
    assert.equal(new Set(before.map(item => item.id)).size, Math.min(size, 3));
    const after = marketplacePreviewOrder(pool, before[0]?.id);
    if (size > 1) assert(after.every((item, index) => item.id !== before[index].id));
    if (size >= 6) assert(after.every(item => !before.includes(item)));
}
assert.match(marketplacePreviewTile(sampleFlyers[0]), /href="\/marketplace\?id=/);
console.log('Marketplace browse passed: six flyers per page, retained filters, full detail artwork, and previews rotating without fixed slots.');
