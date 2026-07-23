const DEFAULT_BASE_ORIGIN = 'https://ussehub.com';

export const VIDEO_HOSTS = Object.freeze({
    youtube: ['youtube.com', 'youtube-nocookie.com'],
    youtubeShort: ['youtu.be'],
    vimeo: ['vimeo.com']
});

export const GOOGLE_MAP_HOSTS = Object.freeze([
    'google.com',
    'google.com.jm',
    'maps.app.goo.gl',
    'goo.gl'
]);

export const VIRTUAL_TOUR_HOSTS = Object.freeze([
    'matterport.com',
    'kuula.co',
    'momento360.com',
    'cloudpano.com',
    'roundme.com'
]);

export function hostnameMatches(hostname, allowedDomains) {
    const normalized = String(hostname || '').toLowerCase().replace(/\.$/, '');
    return allowedDomains.some((domain) => {
        const allowed = String(domain).toLowerCase().replace(/\.$/, '');
        return normalized === allowed || normalized.endsWith(`.${allowed}`);
    });
}

export function safeHttpUrl(input, baseOrigin = globalThis.location?.origin || DEFAULT_BASE_ORIGIN) {
    if (!input) return '';
    try {
        const url = new URL(String(input).trim(), baseOrigin);
        return ['https:', 'http:'].includes(url.protocol) ? url.href : '';
    } catch {
        return '';
    }
}

function validMediaId(value, pattern) {
    const decoded = decodeURIComponent(String(value || '')).trim();
    return pattern.test(decoded) ? decoded : '';
}

export function videoEmbedUrl(input, baseOrigin) {
    const url = safeHttpUrl(input, baseOrigin);
    if (!url) return '';

    try {
        const parsed = new URL(url);
        const pathParts = parsed.pathname.split('/').filter(Boolean);

        if (hostnameMatches(parsed.hostname, VIDEO_HOSTS.youtubeShort)) {
            const id = validMediaId(pathParts[0], /^[A-Za-z0-9_-]{6,64}$/);
            return id ? `https://www.youtube-nocookie.com/embed/${id}` : '';
        }

        if (hostnameMatches(parsed.hostname, VIDEO_HOSTS.youtube)) {
            const pathId = ['embed', 'shorts', 'live'].includes(pathParts[0]) ? pathParts[1] : '';
            const id = validMediaId(parsed.searchParams.get('v') || pathId, /^[A-Za-z0-9_-]{6,64}$/);
            return id ? `https://www.youtube-nocookie.com/embed/${id}` : '';
        }

        if (hostnameMatches(parsed.hostname, VIDEO_HOSTS.vimeo)) {
            const id = validMediaId(pathParts.at(-1), /^\d{5,20}$/);
            return id ? `https://player.vimeo.com/video/${id}` : '';
        }
    } catch {
        return '';
    }

    return '';
}

export function googleMapsUrl(input, baseOrigin) {
    const url = safeHttpUrl(input, baseOrigin);
    if (!url) return '';
    try {
        const parsed = new URL(url);
        return hostnameMatches(parsed.hostname, GOOGLE_MAP_HOSTS) ? parsed.href : '';
    } catch {
        return '';
    }
}

export function googleMapsEmbedUrl(input, baseOrigin) {
    const url = googleMapsUrl(input, baseOrigin);
    if (!url) return '';
    const parsed = new URL(url);
    const isDirectEmbed = hostnameMatches(parsed.hostname, ['google.com', 'google.com.jm'])
        && parsed.pathname.includes('/embed');
    return isDirectEmbed ? parsed.href : `https://www.google.com/maps?q=${encodeURIComponent(parsed.href)}&output=embed`;
}

export function virtualTourEmbedUrl(input, baseOrigin) {
    const url = safeHttpUrl(input, baseOrigin);
    if (!url) return '';
    try {
        const parsed = new URL(url);
        return hostnameMatches(parsed.hostname, VIRTUAL_TOUR_HOSTS) ? parsed.href : '';
    } catch {
        return '';
    }
}
