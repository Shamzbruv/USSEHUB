import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.108.2/+esm';

const SUPABASE_URL = 'https://zcptuqrlovflcpqszery.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpjcHR1cXJsb3ZmbGNwcXN6ZXJ5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMDMxMzcsImV4cCI6MjA5NTU3OTEzN30.kl9BwGqwWEVWYtxYWrG7xigK_EOGZxLQBNbZZp7tfPw';
const DEFAULT_PLACEMENT = 'webpage-network';
const SESSION_KEY = 'ajm_ad_session_token';
const SPOTLIGHT_KEY_PREFIX = 'ajm_spotlight_seen:';
const SPOTLIGHT_CAP_MS = 7 * 24 * 60 * 60 * 1000;
const STYLE_ID = 'ajm-ad-delivery-styles';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function safeStorage(storage) {
    try {
        const probe = '__ajm_ad_storage_probe__';
        storage.setItem(probe, '1');
        storage.removeItem(probe);
        return storage;
    } catch {
        return null;
    }
}

function stableSessionToken() {
    const storage = safeStorage(globalThis.localStorage);
    const existing = storage?.getItem(SESSION_KEY);
    if (existing && existing.length >= 8 && existing.length <= 512) return existing;

    const token = globalThis.crypto?.randomUUID?.()
        || `ajm-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
    try { storage?.setItem(SESSION_KEY, token); } catch { /* Storage is optional. */ }
    return token;
}

// A small deterministic hash gives each browser/page pair a stable ordering,
// while different visitors and pages distribute delivery across the full set.
function stableHash(value) {
    let hash = 2166136261;
    for (let index = 0; index < value.length; index += 1) {
        hash ^= value.charCodeAt(index);
        hash = Math.imul(hash, 16777619);
    }
    return hash >>> 0;
}

function safeHttpUrl(value, base = globalThis.location?.origin || 'https://www.ussehub.com') {
    if (!value) return '';
    try {
        const url = new URL(String(value).trim(), base);
        return ['http:', 'https:'].includes(url.protocol) ? url.href : '';
    } catch {
        return '';
    }
}

function creativeMetadata(ad) {
    return ad?.creative_metadata
        && typeof ad.creative_metadata === 'object'
        && !Array.isArray(ad.creative_metadata)
        ? ad.creative_metadata
        : {};
}

function adFormat(ad) {
    const metadata = creativeMetadata(ad);
    const requested = String(metadata.format || metadata.ad_format || metadata.layout || 'native').toLowerCase();
    return ['native', 'banner', 'spotlight'].includes(requested) ? requested : 'native';
}

function creativeUrl(ad) {
    const metadata = creativeMetadata(ad);
    const direct = safeHttpUrl(
        metadata.media_url
        || metadata.public_url
        || metadata.image_url
        || metadata.video_url
        || ''
    );
    if (direct) return direct;

    const rawPath = String(ad?.creative_path || '').trim();
    if (!rawPath) return '';
    const directPath = /^https?:\/\//i.test(rawPath) ? safeHttpUrl(rawPath) : '';
    if (directPath) return directPath;
    const encodedPath = rawPath.split('/').filter(Boolean).map(encodeURIComponent).join('/');
    return encodedPath
        ? `${SUPABASE_URL}/storage/v1/object/public/ad-creatives/${encodedPath}`
        : '';
}

function isVideoCreative(ad, url) {
    const metadata = creativeMetadata(ad);
    const type = String(metadata.mime_type || metadata.media_type || metadata.type || '').toLowerCase();
    return type.startsWith('video/') || /\.(mp4|webm)(?:$|[?#])/i.test(url);
}

function appendText(parent, tag, text, className) {
    const node = document.createElement(tag);
    node.textContent = String(text || '');
    if (className) node.className = className;
    parent.appendChild(node);
    return node;
}

function buildMedia(ad, destination) {
    const url = creativeUrl(ad);
    if (!url) return null;

    if (isVideoCreative(ad, url)) {
        const video = document.createElement('video');
        video.className = 'ajm-network-ad__media';
        video.src = url;
        video.controls = true;
        video.muted = true;
        video.playsInline = true;
        video.preload = 'metadata';
        video.setAttribute('aria-label', ad.headline || ad.business_name || 'Sponsored video');
        return video;
    }

    const image = document.createElement('img');
    image.className = 'ajm-network-ad__media';
    image.src = url;
    image.alt = ad.headline || ad.business_name || 'Sponsored advertisement';
    image.loading = 'lazy';
    image.decoding = 'async';
    image.referrerPolicy = 'no-referrer';

    if (!destination) return image;
    const link = document.createElement('a');
    link.className = 'ajm-network-ad__media-link';
    link.href = destination;
    link.target = '_blank';
    link.rel = 'noopener noreferrer sponsored';
    link.appendChild(image);
    return link;
}

function recordEvent(ad, eventType, sessionToken, pageKey) {
    if (!ad?.id) return;
    void supabase.rpc('record_ad_event', {
        p_advertisement_id: ad.id,
        p_event_type: eventType,
        p_session_token: sessionToken,
        p_metadata: {
            page: String(pageKey).slice(0, 240),
            placement: ad.placement || DEFAULT_PLACEMENT,
            format: adFormat(ad)
        }
    }).then(() => {}).catch(() => {});
}

function observeImpression(node, ad, sessionToken, pageKey) {
    let recorded = false;
    const record = () => {
        if (recorded || !node.isConnected) return;
        recorded = true;
        recordEvent(ad, 'impression', sessionToken, pageKey);
    };

    if (!('IntersectionObserver' in globalThis)) {
        globalThis.requestAnimationFrame?.(record) || globalThis.setTimeout(record, 0);
        return;
    }

    const observer = new IntersectionObserver((entries) => {
        if (!entries.some((entry) => entry.isIntersecting && entry.intersectionRatio >= 0.5)) return;
        observer.disconnect();
        record();
    }, { threshold: [0.5] });
    observer.observe(node);
}

function buildAd(ad, sessionToken, pageKey) {
    const format = adFormat(ad);
    const destination = safeHttpUrl(ad.cta_url);
    const article = document.createElement('article');
    article.className = `ajm-network-ad ajm-network-ad--${format}`;
    article.dataset.advertisementId = ad.id;
    article.dataset.format = format;
    article.setAttribute('role', 'region');
    article.setAttribute('aria-label', 'Sponsored advertisement');

    const media = buildMedia(ad, destination);
    if (media) {
        media.addEventListener('click', () => {
            if (destination) recordEvent(ad, 'click', sessionToken, pageKey);
        });
        article.appendChild(media);
    }

    const copy = document.createElement('div');
    copy.className = 'ajm-network-ad__copy';
    appendText(
        copy,
        'span',
        ad.business_name ? `Sponsored · ${ad.business_name}` : 'Sponsored advertisement',
        'ajm-network-ad__label'
    );
    appendText(
        copy,
        'h2',
        ad.headline || ad.business_name || ad.package_name || 'Featured business',
        'ajm-network-ad__title'
    );
    if (ad.body_text) appendText(copy, 'p', ad.body_text, 'ajm-network-ad__body');

    if (destination) {
        const cta = document.createElement('a');
        cta.className = 'ajm-network-ad__cta';
        cta.href = destination;
        cta.target = '_blank';
        cta.rel = 'noopener noreferrer sponsored';
        cta.textContent = `${ad.cta_label || 'Learn more'} →`;
        cta.addEventListener('click', () => recordEvent(ad, 'click', sessionToken, pageKey));
        copy.appendChild(cta);
    }

    article.appendChild(copy);
    return article;
}

function spotlightWasSeen(adId) {
    const storage = safeStorage(globalThis.localStorage);
    if (!storage) return false;
    const seenAt = Number(storage.getItem(`${SPOTLIGHT_KEY_PREFIX}${adId}`));
    return Number.isFinite(seenAt) && Date.now() - seenAt < SPOTLIGHT_CAP_MS;
}

function markSpotlightSeen(adId) {
    try {
        safeStorage(globalThis.localStorage)?.setItem(`${SPOTLIGHT_KEY_PREFIX}${adId}`, String(Date.now()));
    } catch { /* The cap degrades gracefully when storage is unavailable. */ }
}

function injectStyles() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = `
        .ajm-ad-network-mount:not([hidden]){display:block;width:min(1180px,calc(100% - 32px));margin:26px auto 42px}
        .ajm-network-ad{position:relative;isolation:isolate;overflow:hidden;display:grid;grid-template-columns:minmax(180px,.72fr) minmax(0,1.28fr);color:#f8f9ff;background:linear-gradient(145deg,#101625,#090d17);border:1px solid rgba(255,255,255,.14);border-radius:22px;box-shadow:0 20px 60px rgba(0,0,0,.24);font-family:"Space Grotesk",system-ui,sans-serif}
        .ajm-network-ad--native{grid-template-columns:minmax(150px,.48fr) minmax(0,1.52fr)}
        .ajm-network-ad--banner{grid-template-columns:minmax(240px,.9fr) minmax(0,1.1fr);border-color:rgba(255,207,51,.3)}
        .ajm-network-ad__media-link{display:block;min-height:100%}
        .ajm-network-ad__media{display:block;width:100%;height:100%;min-height:180px;max-height:300px;object-fit:cover;background:#070a11}
        video.ajm-network-ad__media{object-fit:contain}
        .ajm-network-ad__copy{display:flex;min-width:0;flex-direction:column;align-items:flex-start;justify-content:center;padding:clamp(22px,4vw,42px)}
        .ajm-network-ad__label{margin-bottom:9px;color:#6ff0ab;font-size:.7rem;font-weight:800;letter-spacing:.12em;text-transform:uppercase}
        .ajm-network-ad__title{margin:0;color:#fff;font-size:clamp(1.3rem,3vw,2rem);line-height:1.08;letter-spacing:-.025em}
        .ajm-network-ad__body{max-width:680px;margin:12px 0 0;color:#c1c9db;font-size:.95rem;line-height:1.65}
        .ajm-network-ad__cta{display:inline-flex;margin-top:18px;padding:10px 16px;color:#06100b;background:linear-gradient(135deg,#2dd6a4,#ffcf33);border-radius:999px;font-size:.84rem;font-weight:800;text-decoration:none}
        .ajm-network-ad__cta:hover{filter:brightness(1.06);transform:translateY(-1px)}
        .ajm-network-ad__cta:focus-visible,.ajm-network-ad__media-link:focus-visible,.ajm-network-ad__dismiss:focus-visible{outline:3px solid #ffcf33;outline-offset:3px}
        .ajm-network-ad--spotlight{position:fixed;right:18px;bottom:86px;z-index:1000;width:min(430px,calc(100vw - 36px));grid-template-columns:1fr;border-color:rgba(45,214,164,.38);box-shadow:0 28px 90px rgba(0,0,0,.58);animation:ajm-ad-arrive .28s ease-out}
        .ajm-network-ad--spotlight .ajm-network-ad__media{min-height:0;max-height:190px;aspect-ratio:16/8}
        .ajm-network-ad--spotlight .ajm-network-ad__copy{padding:22px}
        .ajm-network-ad__dismiss{position:absolute;top:10px;right:10px;z-index:2;width:36px;height:36px;display:grid;place-items:center;padding:0;color:#fff;background:rgba(5,7,13,.86);border:1px solid rgba(255,255,255,.25);border-radius:50%;font:700 1.25rem/1 system-ui;cursor:pointer}
        @keyframes ajm-ad-arrive{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:translateY(0)}}
        @media (max-width:680px){.ajm-network-ad,.ajm-network-ad--native,.ajm-network-ad--banner{grid-template-columns:1fr}.ajm-network-ad__media{min-height:0;max-height:220px;aspect-ratio:16/9}.ajm-network-ad__copy{padding:22px}.ajm-network-ad--spotlight{bottom:82px}.ajm-network-ad--spotlight .ajm-network-ad__media{max-height:150px}}
        @media (prefers-reduced-motion:reduce){.ajm-network-ad--spotlight{animation:none}.ajm-network-ad__cta{transition:none}}
    `;
    document.head.appendChild(style);
}

function resolveTarget(target) {
    if (target instanceof Element) return target;
    if (typeof target === 'string') return document.querySelector(target);
    return document.querySelector('[data-ajm-ad-network]');
}

function rankedEligibleAds(ads, sessionToken, pageKey) {
    return ads
        .filter((ad) => ad?.id)
        .map((ad) => ({ ad, score: stableHash(`${sessionToken}:${pageKey}:${ad.id}`) }))
        .sort((left, right) => left.score - right.score || String(left.ad.id).localeCompare(String(right.ad.id)))
        .map(({ ad }) => ad)
        .filter((ad) => adFormat(ad) !== 'spotlight' || !spotlightWasSeen(ad.id));
}

function showSpotlight(ad, sessionToken, pageKey, delayMs) {
    globalThis.setTimeout(() => {
        if (document.visibilityState === 'hidden' || spotlightWasSeen(ad.id)) return;
        const article = buildAd(ad, sessionToken, pageKey);
        const dismiss = document.createElement('button');
        dismiss.type = 'button';
        dismiss.className = 'ajm-network-ad__dismiss';
        dismiss.setAttribute('aria-label', 'Dismiss sponsored advertisement');
        dismiss.textContent = '×';
        dismiss.addEventListener('click', () => article.remove());
        article.prepend(dismiss);
        document.body.appendChild(article);
        markSpotlightSeen(ad.id);
        observeImpression(article, ad, sessionToken, pageKey);
    }, Math.max(0, Number(delayMs) || 0));
}

export async function mountAjmAdDelivery({
    target,
    placement = DEFAULT_PLACEMENT,
    pageKey = globalThis.location?.pathname || 'public-page',
    limit = 50,
    spotlightDelayMs = 5000
} = {}) {
    const mount = resolveTarget(target);
    if (!mount || mount.dataset.ajmAdInitialized === 'true') return null;
    mount.dataset.ajmAdInitialized = 'true';

    try {
        const sessionToken = stableSessionToken();
        const { data, error } = await supabase.rpc('get_active_advertisements', {
            p_placement: String(placement || DEFAULT_PLACEMENT),
            p_limit: Math.max(1, Math.min(Number(limit) || 50, 50))
        });
        if (error) return null;

        const ads = Array.isArray(data?.advertisements)
            ? data.advertisements
            : Array.isArray(data) ? data : [];
        const ad = rankedEligibleAds(ads, sessionToken, String(pageKey))[0];
        if (!ad) return null;

        injectStyles();
        if (adFormat(ad) === 'spotlight') {
            showSpotlight(ad, sessionToken, String(pageKey), spotlightDelayMs);
            return ad;
        }

        const article = buildAd(ad, sessionToken, String(pageKey));
        mount.replaceChildren(article);
        mount.hidden = false;
        observeImpression(article, ad, sessionToken, String(pageKey));
        return ad;
    } catch {
        return null;
    }
}
