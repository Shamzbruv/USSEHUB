export const MARKET_SEGMENTS = {
    "Fashion & Retail": [
        "Fashion Industry",
        "Retail Clothing"
    ],
    "Events & Entertainment": [
        "Attractions",
        "Musical Studio Services"
    ],
    "Food & Catering": [
        "Catering Services",
        "Cooking Services",
        "Bakery Supplier",
        "Ice Production Services"
    ],
    "Business Services": [
        "Cleaning Services"
    ],
    "Beauty & Personal Care": [
        "Hair Grooming Services",
        "Cosmetic Services",
        "Nail Technicians",
        "Hair Stylists"
    ],
    "Transport & Logistics": [
        "Delivery Services",
        "Haulage Services",
        "Import & Export Services"
    ],
    "Financial Services": [
        "Micro Loan Services"
    ],
    "Education & Coaching": [
        "Educational Services",
        "Coaching Services"
    ]
};
export const MARKET_CATEGORIES = [
    'Farm Products', 'Motor Vehicles', 'Hardware', 'Suppliers',
    ...Object.keys(MARKET_SEGMENTS), 'General'
];
export const MINI_AD_MAX_BYTES = 20 * 1024 * 1024;
export const MINI_AD_MAX_SECONDS = 15;

export const escapeHtml=v=>String(v??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
export function secureUrl(value){try{const u=new URL(String(value||''));return u.protocol==='https:'&&!u.username&&!u.password?u.href:'';}catch{return '';}}
export function marketCard(flyer, { manage = false, imageUrl = '', compact = false } = {}) {
    const e = escapeHtml;
    const id = encodeURIComponent(flyer.id);
    const detailUrl = '/marketplace?id=' + id;
    const video = flyer.mime === 'video/mp4';
    const contact = secureUrl(flyer.contact_url);
    const mediaUrl = manage ? secureUrl(imageUrl) : (video ? '/marketplace/videos/' : '/marketplace/flyers/') + id;
    const classification = [flyer.category, flyer.segment].filter(Boolean).join(' · ');
    const status = flyer.status === 'published' && Date.parse(flyer.expires_at) <= Date.now() ? 'expired' : flyer.status;
    let artwork = '<p>Media preview unavailable. Refresh to retry.</p>';
    if (mediaUrl && video) {
        artwork = `<video controls playsinline preload="${compact ? 'none' : 'metadata'}" aria-label="${e(flyer.title)}" src="${e(mediaUrl)}"></video>`;
    } else if (mediaUrl) {
        artwork = `<a href="${e(mediaUrl)}" target="_blank" rel="noopener" aria-label="Open full flyer: ${e(flyer.title)}"><img src="${e(mediaUrl)}" alt="${e(flyer.title)} — ${e(flyer.business_name)}" loading="lazy" width="600" height="700"></a>`;
    }

    return `<article class="market-card flyer-card${compact ? ' flyer-card-compact' : ''}">
        <div class="flyer-art${video ? ' flyer-art-video' : ''}">${artwork}</div>
        <div class="flyer-copy">
            <small class="market-eyebrow">${e(classification)}</small>
            ${video ? `<span class="market-tag">Mini-Ad${flyer.video_duration_ms ? ' · ' + Math.ceil(flyer.video_duration_ms / 1000) + 's' : ''}</span>` : ''}
            ${flyer.ajm_sponsored ? '<span class="market-tag">AJM-sponsored introduction</span>' : ''}
            ${manage ? `<span class="market-tag">${e(status)}</span>` : ''}
            <h3>${e(flyer.title)}</h3><strong>${e(flyer.business_name)}</strong><p>${e(flyer.tagline)}</p>
            <div class="market-actions">
                ${contact ? `<a class="button" href="${e(contact)}" target="_blank" rel="noopener noreferrer">Contact business ↗</a>` : ''}
                ${!manage && compact ? `<a class="button" href="${detailUrl}">View &amp; share →</a>` : ''}
                ${!manage && !compact ? '<a class="button" href="#marketplace-share">Share post ↑</a>' : ''}
            </div>
            ${!manage && !compact ? '<small>Contact the advertiser directly for availability and terms.</small>' : ''}
        </div>
    </article>`;
}
export async function validateMarketImage(file){if(!file?.size||file.size>5242880)throw new Error('Choose a JPG, PNG or WebP image up to 5 MB.');const b=new Uint8Array(await file.slice(0,12).arrayBuffer()),a=(s,e)=>String.fromCharCode(...b.slice(s,e));const mime=b[0]===137&&a(1,4)==='PNG'&&b[4]===13&&b[5]===10&&b[6]===26&&b[7]===10?'image/png':b[0]===255&&b[1]===216&&b[2]===255?'image/jpeg':a(0,4)==='RIFF'&&a(8,12)==='WEBP'?'image/webp':'';if(!mime||file.type&&!['image/jpeg','image/png','image/webp'].includes(file.type))throw new Error('Use a JPG, PNG or WebP image.');return{mime,file_size:file.size};}

export const MARKETPLACE_PAGE_SIZE = 6;

export function marketplacePreviewOrder(flyers, lastFirstId) {
    if (!flyers.length) return [];

    // The next group uses fresh artwork wherever the current pool allows.
    const previousStart = flyers.findIndex(flyer => flyer.id === lastFirstId);
    const step = Math.min(3, flyers.length - 1);
    const start = previousStart < 0
        ? Math.floor(Math.random() * flyers.length)
        : (previousStart + step) % flyers.length;
    return Array.from({ length: Math.min(3, flyers.length) }, (_, index) => (
        flyers[(start + index) % flyers.length]
    ));
}

export function marketplacePreviewTile(flyer) {
    const id = encodeURIComponent(flyer.id);
    const title = escapeHtml(flyer.title);
    return `<a class="marketplace-showcase-tile" href="/marketplace?id=${id}#marketplace-results" aria-label="View Marketplace post: ${title}">
        ${flyer.mime === 'video/mp4' ? '<span class="marketplace-showcase-video">▶ Mini-Ad</span>' : `<img src="/marketplace/flyers/${id}" alt="" decoding="async">`}
        <span>${title}</span>
    </a>`;
}
