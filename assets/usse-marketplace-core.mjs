export const MARKET_CATEGORIES=['Farm Products','Motor Vehicles','Hardware','Suppliers','Events & Entertainment','Business Services'];
export const escapeHtml=v=>String(v??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
export function secureUrl(value){try{const u=new URL(String(value||''));return u.protocol==='https:'&&!u.username&&!u.password?u.href:'';}catch{return '';}}
export function marketCard(f,{manage=false,imageUrl='',compact=false}={}){const e=escapeHtml,url=secureUrl(f.contact_url),image=manage?secureUrl(imageUrl):'/marketplace/flyers/'+encodeURIComponent(f.id);return `<article class="market-card flyer-card${compact?' flyer-card-compact':''}"><div class="flyer-art">${image?`<a href="${e(image)}" target="_blank" rel="noopener" aria-label="Open full flyer: ${e(f.title)}"><img src="${e(image)}" alt="${e(f.title)} — ${e(f.business_name)}" loading="lazy" width="600" height="700"></a>`:'<p>Image preview unavailable. Refresh to retry.</p>'}</div><div class="flyer-copy"><small class="market-eyebrow">${e(f.category)}</small>${f.ajm_sponsored?'<span class="market-tag">AJM-sponsored introduction</span>':''}${manage?`<span class="market-tag">${e(f.status==='published'&&Date.parse(f.expires_at)<=Date.now()?'expired':f.status)}</span>`:''}<h3>${e(f.title)}</h3><strong>${e(f.business_name)}</strong><p>${e(f.tagline)}</p><div class="market-actions">${url?`<a class="button" href="${e(url)}" target="_blank" rel="noopener noreferrer">Contact business ↗</a>`:''}${!manage?`<a class="button" href="/marketplace?id=${encodeURIComponent(f.id)}">View &amp; share →</a>`:''}</div>${!manage&&!compact?'<small>Contact the advertiser directly for availability and terms.</small>':''}</div></article>`;}
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
    return `<a class="marketplace-showcase-tile" href="/marketplace?id=${id}#marketplace-results" aria-label="View flyer: ${title}">
        <img src="/marketplace/flyers/${id}" alt="" decoding="async">
        <span>${title}</span>
    </a>`;
}
