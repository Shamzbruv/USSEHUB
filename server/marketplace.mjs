import {businessTaxonomy} from './business-taxonomy.mjs';
import fs from'node:fs';import path from'node:path';
import{SUPABASE_URL,SUPABASE_ANON_KEY}from'../assets/usse-public-config.mjs';
import{marketCard,escapeHtml as e,MARKETPLACE_PAGE_SIZE}from'../assets/usse-marketplace-core.mjs';
import{head,replaceHead,jsonLd,ORIGIN,breadcrumbs}from'./seo-core.mjs';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export async function marketplaceData(payload,fetchImpl=fetch){const r=await fetchImpl(SUPABASE_URL+'/rest/v1/rpc/marketplace_public',{method:'POST',headers:{apikey:SUPABASE_ANON_KEY,Authorization:'Bearer '+SUPABASE_ANON_KEY,'Content-Type':'application/json'},body:JSON.stringify({p_payload:payload}),signal:AbortSignal.timeout(7000)});if(!r.ok)throw new Error('Marketplace service unavailable');const data=await r.json();if(!Array.isArray(data?.rows)||!Number.isFinite(Number(data.total)))throw new Error('Invalid Marketplace response');return{rows:data.rows.filter(f=>uuid.test(f.id)),total:Number(data.total)};}
function marketplaceBrowseUrl({ category, segment, search, offset, format }) {
    const query = new URLSearchParams();
    if (category) query.set('category', category);
    if (search) query.set('search', search);
    if (segment) query.set('segment', segment);
    if (format) query.set('format', format);
    if (offset) query.set('offset', String(offset));
    return '/marketplace' + (query.size ? '?' + query : '');
}

function marketplaceFilters({ category, segment, search, format }, taxonomy) {
    const categories = ['', ...Object.keys(taxonomy)];
    const links = categories.map(value => {
        const href = marketplaceBrowseUrl({ category: value, search, format }) + '#marketplace-results';
        return `<a class="button" href="${e(href)}"${value === category ? ' aria-current="true"' : ''}>${e(value || 'All opportunities')}</a>`;
    }).join('');
    const options = categories.map(value => (
        `<option value="${e(value)}"${value === category ? ' selected' : ''}>${e(value || 'All categories')}</option>`
    )).join('');
    const segments = category ? taxonomy[category] || [] : Object.values(taxonomy).flat();
    const segmentOptions = segments.map(value =>
        `<option value="${e(value)}"${value === segment ? ' selected' : ''}>${e(value)}</option>`
    ).join('');
    return `<nav class="market-category-bar" aria-label="Marketplace categories">${links}</nav>
        <form id="marketplace-search" class="market-filters" action="/marketplace#marketplace-results" method="get">
            <label>Search businesses and flyers<input name="search" value="${e(search)}" maxlength="100" placeholder="A business, product or service"></label>
            <label>Category<select name="category">${options}</select></label>
            <label>Subsegment<select name="segment"><option value="">All subsegments</option>${segmentOptions}</select></label>
            <label>Post type<select name="format"><option value="">All posts</option><option value="mini-ad"${format ? ' selected' : ''}>Mini-Ads only</option></select></label>
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
        <span>${offset + 1}–${offset + visibleCount} of ${total} posts</span>
        ${offset + MARKETPLACE_PAGE_SIZE < total ? link(offset + MARKETPLACE_PAGE_SIZE, 'Next →') : '<span></span>'}
    </nav>`;
}

function marketplaceShare(flyer, canonical) {
    const url = ORIGIN + canonical;
    const title = flyer.title + ' | AJM Marketplace';
    const link = encodeURIComponent(url);
    const text = encodeURIComponent(title);
    const message = encodeURIComponent(title + '\n' + url);
    const destinations = [
        ['WhatsApp', 'https://wa.me/?text=' + message],
        ['Facebook', 'https://www.facebook.com/sharer/sharer.php?u=' + link],
        ['X', 'https://twitter.com/intent/tweet?url=' + link + '&text=' + text],
        ['LinkedIn', 'https://www.linkedin.com/sharing/share-offsite/?url=' + link],
        ['Telegram', 'https://t.me/share/url?url=' + link + '&text=' + text]
    ];
    const socialLinks = destinations.map(([label, href]) =>
        `<a class="button" href="${e(href)}" target="_blank" rel="noopener noreferrer">${label}</a>`
    ).join('');

    return `<section id="marketplace-share" aria-labelledby="marketplace-share-title" data-url="${e(url)}" data-title="${e(title)}">
        <h2 id="marketplace-share-title">Share this flyer</h2>
        <div class="market-actions">
            ${socialLinks}
            <a class="button" href="mailto:?subject=${e(text)}&amp;body=${e(message)}">Email</a>
            <button class="button" type="button" data-copy-flyer hidden>Copy link</button>
            <button class="button" type="button" data-share-flyer hidden>More apps</button>
        </div>
        <p class="marketplace-share-status" role="status" aria-atomic="true"></p>
        <label class="marketplace-share-fallback" hidden>
            Flyer link
            <input type="url" value="${e(url)}" readonly>
        </label>
        <noscript><p>Share the flyer link <a href="${e(url)}">${e(url)}</a>.</p></noscript>
    </section>`;
}

export async function renderMarketplace(url, root, fetchImpl = fetch) {
    const id = url.searchParams.get('id');
    if (id && !uuid.test(id)) return { status: 404, body: 'Flyer not found.' };

    const { marketplace: taxonomy } = await businessTaxonomy(fetchImpl);
    const requestedCategory = url.searchParams.get('category');
    const category = Object.hasOwn(taxonomy, requestedCategory) ? requestedCategory : '';
    const validSegments = category ? taxonomy[category] || [] : Object.values(taxonomy).flat();
    const requestedSegment = url.searchParams.get('segment');
    const segment = validSegments.includes(requestedSegment) ? requestedSegment : '';
    const format = url.searchParams.get('format') === 'mini-ad' ? 'mini-ad' : '';
    const requestedOffset = Number(url.searchParams.get('offset')) || 0;
    const payload = id ? { id } : {
        offset: Math.floor(Math.max(0, Math.min(requestedOffset, 100000)) / MARKETPLACE_PAGE_SIZE) * MARKETPLACE_PAGE_SIZE,
        category, segment, format,
        search: (url.searchParams.get('search') || '').trim().slice(0, 100)
    };
    const isFirstPage = !id && !payload.category && !payload.segment && !payload.format && !payload.search && !payload.offset;
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
    const isVideo = flyer?.mime === 'video/mp4';
    const title = flyer ? `${flyer.title} — ${flyer.business_name} | AJM Marketplace` : 'AJM Marketplace | Jamaican Business Flyers & Opportunities';
    const description = flyer ? flyer.tagline : 'Explore Jamaican business flyers, farm products, vehicles, hardware, suppliers, events and services on AJM Marketplace.';
    const canonical = flyer ? '/marketplace?id=' + id : '/marketplace';
    const schema = flyer
        ? { '@context': 'https://schema.org', '@type': 'WebPage', name: flyer.title, description: flyer.tagline,
            url: ORIGIN + canonical,
            ...(isVideo ? {} : { primaryImageOfPage: ORIGIN + '/marketplace/flyers/' + id }) }
        : { '@context': 'https://schema.org', '@type': 'CollectionPage', name: 'AJM Marketplace', url: ORIGIN + canonical,
            mainEntity: { '@type': 'ItemList', itemListElement: rows.map((item, index) => ({
                '@type': 'ListItem', position: payload.offset + index + 1, name: item.title, url: ORIGIN + '/marketplace?id=' + item.id
            })) } };

    const metadata = head({
        title, description, image: flyer && !isVideo ? '/marketplace/flyers/' + id : '/assets/seo/usse-hub-share.png',
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
            .replace('<a class="button" href="/ajm-marketplace-manage#flyer-editor">Post a flyer →</a>', '')
            .replace('<!-- marketplace share -->', () => marketplaceShare(flyer, canonical))
            .replace(/<meta property="og:image:(width|height)" content="[^"]*">/g, '');
        if (isVideo) {
            html = html.replace('Share this flyer</h2>', 'Share this mini-ad</h2>')
                .replace('</head>', `<meta property="og:video" content="${ORIGIN}/marketplace/videos/${id}">
<meta property="og:video:type" content="video/mp4"></head>`);
        }
    } else {
        const pool = (isFirstPage ? data.rows : separatePreviews?.rows || []);
        const previews = pool.map(({ id, title, mime }) => ({ id, title, mime }));
        html = html
            .replace('<!-- marketplace filters -->', () => marketplaceFilters(payload, taxonomy))
            .replace('</main>', () => `<script id="marketplace-taxonomy" type="application/json">${jsonLd(taxonomy)}</script></main>`)
            .replace('<!-- marketplace pagination -->', () => marketplacePagination(payload, data.total, rows.length))
            .replace('</main>', () => `<script id="marketplace-previews" type="application/json">${jsonLd(previews)}</script></main>`);
    }

    const empty = '<div class="market-empty"><h3>No posts match this view.</h3><p>Browse all approved posts or explore the business directory.</p><a href="/marketplace#marketplace-results">All Marketplace flyers →</a></div>';
    html = html.replace('<!-- marketplace rows -->', () => rows.length ? rows.map(item => marketCard(item, { compact: !flyer })).join('') : empty);
    return { status: 200, body: html, noindex: !flyer && !isFirstPage };
}

async function signedMarketplaceMedia(id, kind, fetchImpl) {
    if (!uuid.test(id)) return null;
    const data = await marketplaceData({ id }, fetchImpl);
    const flyer = data.rows[0];
    if (!flyer || !uuid.test(flyer.id)) return null;
    const pathPattern = kind === 'video'
        ? /^[a-f0-9-]{36}\/[a-f0-9-]{36}\.mp4$/i
        : /^[a-f0-9-]{36}\/[a-f0-9-]{36}\.(png|jpg|webp)$/i;
    if (!pathPattern.test(flyer.image_path)) return null;
    if (kind === 'video' && (flyer.mime !== 'video/mp4' || !(flyer.video_duration_ms > 0 && flyer.video_duration_ms <= 15000))) return null;

    const signed = await fetchImpl(SUPABASE_URL + '/storage/v1/object/sign/marketplace-flyers/' + flyer.image_path, {
        method: 'POST',
        headers: { apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiresIn: kind === 'video' ? 600 : 60 }),
        signal: AbortSignal.timeout(7000)
    });
    if (!signed.ok) throw new Error('Marketplace media unavailable');
    const { signedURL } = await signed.json();
    if (!signedURL?.startsWith('/object/sign/marketplace-flyers/')) throw new Error('Invalid media target');
    const target = new URL('/storage/v1' + signedURL, SUPABASE_URL);
    if (target.origin !== SUPABASE_URL || target.pathname !== '/storage/v1/object/sign/marketplace-flyers/' + flyer.image_path) {
        throw new Error('Invalid media target');
    }
    return target.href;
}

export async function marketplaceImage(id, fetchImpl = fetch) {
    const target = await signedMarketplaceMedia(id, 'image', fetchImpl);
    if (!target) return null;
    const image = await fetchImpl(target, { redirect: 'error', signal: AbortSignal.timeout(7000) });
    const type = (image.headers.get('content-type') || '').split(';')[0];
    if (!image.ok || !['image/jpeg', 'image/png', 'image/webp'].includes(type) ||
        Number(image.headers.get('content-length')) > 5242880) throw new Error('Invalid image');
    const body = Buffer.from(await image.arrayBuffer());
    if (body.length > 5242880) throw new Error('Image too large');
    return { body, type };
}

export function marketplaceVideo(id, fetchImpl = fetch) {
    return signedMarketplaceMedia(id, 'video', fetchImpl);
}
