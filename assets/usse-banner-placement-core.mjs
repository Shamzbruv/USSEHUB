import {BANNER_PAGES,BANNER_POSITIONS} from './usse-banner-core.mjs';
export function bannerPlacementDraft(pkg,page,position) {
    if (!Object.hasOwn(BANNER_PAGES,page) || !Object.hasOwn(BANNER_POSITIONS,position)) throw new Error('Choose a supported page and banner position.');
    if (pkg && pkg.product_type !== 'display_ad') throw new Error('Choose a display-ad package. Business webpage promotions use automatic placement.');
    const placements = Array.isArray(pkg?.placements) ? pkg.placements : [];
    return [...new Set([...placements, page+'-'+position])];
}
