import fs from 'node:fs';
import vm from 'node:vm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from '../assets/usse-public-config.mjs';
import { MARKET_CATEGORIES, MARKET_SEGMENTS } from '../assets/usse-marketplace-core.mjs';

const context = { window: {} };
vm.runInNewContext(fs.readFileSync(new URL('../taxonomy.js', import.meta.url), 'utf8'), context);
export const defaultTaxonomy = {
    directory: JSON.parse(JSON.stringify(context.window.TAXONOMY)),
    marketplace: Object.fromEntries(MARKET_CATEGORIES.map(category => [category, MARKET_SEGMENTS[category] || []]))
};

export async function businessTaxonomy(fetchImpl = fetch) {
    try {
        const response = await fetchImpl(SUPABASE_URL + '/rest/v1/rpc/business_taxonomy', {
            method: 'POST',
            headers: {
                apikey: SUPABASE_ANON_KEY,
                Authorization: 'Bearer ' + SUPABASE_ANON_KEY,
                'Content-Type': 'application/json'
            },
            body: '{}',
            signal: AbortSignal.timeout(7000)
        });
        if (!response.ok) throw new Error('Category service unavailable');
        const data = await response.json();
        if (!data?.directory || !data?.marketplace || Array.isArray(data.directory) || Array.isArray(data.marketplace)) {
            throw new Error('Invalid category catalogue');
        }
        return { directory: data.directory, marketplace: data.marketplace, available: true };
    } catch {
        return { ...defaultTaxonomy, available: false };
    }
}
