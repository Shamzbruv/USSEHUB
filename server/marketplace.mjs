import fs from'node:fs';import path from'node:path';
import{SUPABASE_URL,SUPABASE_ANON_KEY}from'../assets/usse-public-config.mjs';
import{marketCard,escapeHtml as e,MARKET_CATEGORIES,MARKETPLACE_PAGE_SIZE}from'../assets/usse-marketplace-core.mjs';
import{head,replaceHead,jsonLd,ORIGIN,breadcrumbs}from'./seo-core.mjs';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export async function marketplaceData(payload,fetchImpl=fetch){const r=await fetchImpl(SUPABASE_URL+'/rest/v1/rpc/marketplace_public',{method:'POST',headers:{apikey:SUPABASE_ANON_KEY,Authorization:'Bearer '+SUPABASE_ANON_KEY,'Content-Type':'application/json'},body:JSON.stringify({p_payload:payload}),signal:AbortSignal.timeout(7000)});if(!r.ok)throw new Error('Marketplace service unavailable');const data=await r.json();if(!Array.isArray(data?.rows)||!Number.isFinite(Number(data.total)))throw new Error('Invalid Marketplace response');return{rows:data.rows.filter(f=>uuid.test(f.id)),total:Number(data.total)};}
function marketplaceBrowseUrl({ category, search, offset }) {
    const query = new URLSearchParams();
    if (category) query.set('category', category);
    if (search) query.set('search', search);
    if (offset) query.set('offset', String(offset));
    return '/marketplace' + (query.size ? '?' + query : '');
}

function marketplaceFilters({ category, search }) {
    const categories = ['', ...MARKET_CATEGORIES];
    const links = categories.map(value => {
        const href = marketplaceBrowseUrl({ category: value, search }) + '#marketplace-results';
        return `<a class="button" href="${e(href)}"${value === category ? ' aria-current="true"' : ''}>${e(value || 'All opportunities')}</a>`;
    }).join('');
    const options = categories.map(value => (
        `<option value="${e(value)}"${value === category ? ' selected' : ''}>${e(value || 'All categories')}</option>`
    )).join('');
    return `<nav class="market-category-bar" aria-label="Marketplace categories">${links}</nav>
        <form id="marketplace-search" class="market-filters" action="/marketplace#marketplace-results" method="get">
            <label>Search businesses and flyers<input name="search" value="${e(search)}" maxlength="100" placeholder="A business, product or service"></label>
            <label>Category<select name="category">${options}</select></label>
            <button type="submit" class="primary">Search</button>
        </form>`;
}

function marketplacePagination(filters, total, visibleCount) {
    if (!total) return '';
    const { offset } = filters;
    const link = (target, label) => {
        const href = marketplaceBrowseUrl({ ...filters, offset: target }) + '#marketplace-results';
        return `<a class="button" href="${e(href)}">${label}</a>`;
    };
    return `<nav class="market-pagination marketplace-pagination" aria-label="Marketplace pages">
        ${offset ? link(offset - MARKETPLACE_PAGE_SIZE, '← Previous') : '<span></span>'}
        <span>${offset + 1}–${offset + visibleCount} of ${total} flyers</span>
        ${offset + MARKETPLACE_PAGE_SIZE < total ? link(offset + MARKETPLACE_PAGE_SIZE, 'Next →') : '<span></span>'}
    </nav>`;
}

export async function renderMarketplace(url, root, fetchImpl = fetch) {
    const id = url.searchParams.get('id');
    if (id && !uuid.test(id)) return { status: 404, body: 'Flyer not found.' };

    const category = url.searchParams.get('category') || '';
    const requestedOffset = Number(url.searchParams.get('offset')) || 0;
    const payload = id ? { id } : {
        offset: Math.floor(Math.max(0, Math.min(requestedOffset, 100000)) / MARKETPLACE_PAGE_SIZE) * MARKETPLACE_PAGE_SIZE,
        category: MARKET_CATEGORIES.includes(category) ? category : '',
        search: (url.searchParams.get('search') || '').trim().slice(0, 100)
    };
    const isFirstPage = !id && !payload.category && !payload.search && !payload.offset;
    const [data, separatePreviews] = await Promise.all([
        marketplaceData(payload, fetchImpl),
        id || isFirstPage ? null : marketplaceData({}, fetchImpl).catch(() => null)
    ]);

    if (id && !data.rows.length) {
        return { status: 404, body: 'This flyer has expired or is no longer available. <a href="/marketplace">Explore current flyers</a>.' };
    }
    if (!id && payload.offset && payload.offset >= data.total) {
        return { status: 404, body: 'This Marketplace page is no longer available. <a href="/marketplace">Explore current flyers</a>.' };
    }

    const rows = data.rows.slice(0, id ? 1 : MARKETPLACE_PAGE_SIZE);
    const flyer = id ? rows[0] : null;
    const title = flyer ? `${flyer.title} — ${flyer.business_name} | AJM Marketplace` : 'AJM Marketplace | Jamaican Business Flyers & Opportunities';
    const description = flyer ? flyer.tagline : 'Explore Jamaican business flyers, farm products, vehicles, hardware, suppliers, events and services on AJM Marketplace.';
    const canonical = flyer ? '/marketplace?id=' + id : '/marketplace';
    const schema = flyer
        ? { '@context': 'https://schema.org', '@type': 'WebPage', name: flyer.title, description: flyer.tagline,
            url: ORIGIN + canonical, primaryImageOfPage: ORIGIN + '/marketplace/flyers/' + id }
        : { '@context': 'https://schema.org', '@type': 'CollectionPage', name: 'AJM Marketplace', url: ORIGIN + canonical,
            mainEntity: { '@type': 'ItemList', itemListElement: rows.map((item, index) => ({
                '@type': 'ListItem', position: payload.offset + index + 1, name: item.title, url: ORIGIN + '/marketplace?id=' + item.id
            })) } };

    const metadata = head({
        title, description, image: flyer ? '/marketplace/flyers/' + id : '/assets/seo/usse-hub-share.png',
        path: canonical, noindex: !flyer && !isFirstPage,
        schemas: [schema, breadcrumbs([['USSE Hub', '/'], ['AJM Marketplace', '/marketplace']])]
    });
    let html = replaceHead(fs.readFileSync(path.join(root, 'ajm-marketplace.html'), 'utf8'), metadata);
    if (flyer) {
        html = html
            .replace(/<h1>[\s\S]*?<\/h1>/, () => '<h1>' + e(flyer.title) + '</h1>')
            .replace('Explore products, services and events from businesses across Jamaica. A flyer, a brief introduction and a direct connection to the advertiser.', () => e(flyer.tagline))
            .replace('class="market-grid flyer-grid"', 'class="market-grid flyer-grid marketplace-detail"')
            .replace('href="#marketplace-results">Explore the Marketplace ↓', 'href="/marketplace#marketplace-results">← All Marketplace flyers')
            .replace(/<meta property="og:image:(width|height)" content="[^"]*">/g, '');
    } else {
        const pool = (isFirstPage ? data.rows : separatePreviews?.rows || []);
        const previews = pool.map(({ id, title }) => ({ id, title }));
        html = html
            .replace('<!-- marketplace filters -->', () => marketplaceFilters(payload))
            .replace('<!-- marketplace pagination -->', () => marketplacePagination(payload, data.total, rows.length))
            .replace('</main>', () => `<script id="marketplace-previews" type="application/json">${jsonLd(previews)}</script></main>`);
    }

    const empty = '<div class="market-empty"><h3>No flyers match this view.</h3><p>Browse all approved flyers or explore the business directory.</p><a href="/marketplace#marketplace-results">All Marketplace flyers →</a></div>';
    html = html.replace('<!-- marketplace rows -->', () => rows.length ? rows.map(item => marketCard(item, { compact: !flyer })).join('') : empty);
    return { status: 200, body: html, noindex: !flyer && !isFirstPage };
}

export async function marketplaceImage(id,fetchImpl=fetch){if(!uuid.test(id))return null;const data=await marketplaceData({id},fetchImpl),f=data.rows[0];if(!f||!uuid.test(f.id)||!/^[a-f0-9-]{36}\/[a-f0-9-]{36}\.(png|jpg|webp)$/i.test(f.image_path))return null;const signed=await fetchImpl(SUPABASE_URL+'/storage/v1/object/sign/marketplace-flyers/'+f.image_path,{method:'POST',headers:{apikey:SUPABASE_ANON_KEY,Authorization:'Bearer '+SUPABASE_ANON_KEY,'Content-Type':'application/json'},body:JSON.stringify({expiresIn:60}),signal:AbortSignal.timeout(7000)});if(!signed.ok)throw new Error('Marketplace image unavailable');const value=await signed.json();if(!value.signedURL?.startsWith('/object/sign/marketplace-flyers/'))throw new Error('Invalid image target');const target=new URL('/storage/v1'+value.signedURL,SUPABASE_URL);if(target.origin!==SUPABASE_URL||!target.pathname.startsWith('/storage/v1/object/sign/marketplace-flyers/'))throw new Error('Invalid image target');const image=await fetchImpl(target,{redirect:'error',signal:AbortSignal.timeout(7000)}),type=(image.headers.get('content-type')||'').split(';')[0];if(!image.ok||!['image/jpeg','image/png','image/webp'].includes(type)||Number(image.headers.get('content-length'))>5242880)throw new Error('Invalid image');const body=Buffer.from(await image.arrayBuffer());if(body.length>5242880)throw new Error('Image too large');return{body,type};}
