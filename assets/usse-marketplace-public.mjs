import { marketplacePreviewOrder, marketplacePreviewTile } from './usse-marketplace-core.mjs?v=20261114-edit';

const previewData = document.getElementById('marketplace-previews');
const showcase = document.getElementById('marketplace-showcase');
if (previewData && showcase) {
    const storageKey = 'ajm-marketplace-preview';
    let lastFirstId;
    try {
        lastFirstId = sessionStorage.getItem(storageKey);
    } catch {
        // The showcase still works when the browser blocks storage.
    }

    const previews = marketplacePreviewOrder(JSON.parse(previewData.textContent), lastFirstId);
    if (previews.length) {
        showcase.querySelector('.marketplace-showcase-grid').innerHTML = previews.map(marketplacePreviewTile).join('');
        showcase.dataset.count = String(previews.length);
        showcase.hidden = false;
        try {
            sessionStorage.setItem(storageKey, previews[0].id);
        } catch {
            // Rotation falls back to a randomly selected starting point.
        }
    }
}

import('./ajm-ad-delivery.mjs').then(({ mountAjmAdDelivery }) => mountAjmAdDelivery({
    target: document.getElementById('marketplace-sponsored'),
    placement: 'webpage-network',
    pageKey: 'ajm-marketplace'
})).catch(() => {});
