import { MARKET_SEGMENTS, marketplacePreviewOrder, marketplacePreviewTile } from './usse-marketplace-core.mjs?v=taxonomy2';

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

const search = document.getElementById('marketplace-search');
if (search) {
    const { category, segment } = search.elements;
    const taxonomy = JSON.parse(document.getElementById('marketplace-taxonomy')?.textContent || JSON.stringify(MARKET_SEGMENTS));
    category.addEventListener('change', () => {
        const current = segment.value;
        const allowed = category.value ? taxonomy[category.value] || [] : Object.values(taxonomy).flat();
        segment.replaceChildren(new Option('All subsegments', ''), ...allowed.map(name => new Option(name, name)));
        segment.value = allowed.includes(current) ? current : '';
    });
}

const sharePanel = document.getElementById('marketplace-share');
if (sharePanel) {
    const { url, title } = sharePanel.dataset;
    const copyButton = sharePanel.querySelector('[data-copy-flyer]');
    const shareButton = sharePanel.querySelector('[data-share-flyer]');
    const status = sharePanel.querySelector('[role="status"]');
    const fallback = sharePanel.querySelector('.marketplace-share-fallback');
    const linkInput = fallback.querySelector('input');

    copyButton.hidden = false;
    copyButton.addEventListener('click', async () => {
        status.textContent = '';
        try {
            await navigator.clipboard.writeText(url);
            status.textContent = 'Flyer link copied.';
        } catch {
            fallback.hidden = false;
            linkInput.focus();
            linkInput.select();
            status.textContent = 'Select and copy the flyer link below.';
        }
    });

    if (typeof navigator.share === 'function') {
        shareButton.hidden = false;
        shareButton.addEventListener('click', async () => {
            status.textContent = '';
            try {
                await navigator.share({ title, url });
            } catch (error) {
                if (error.name !== 'AbortError') {
                    status.textContent = 'Choose a sharing option above or copy the link.';
                }
            }
        });
    }
}

import('./ajm-ad-delivery.mjs').then(({ mountAjmAdDelivery }) => mountAjmAdDelivery({
    target: document.getElementById('marketplace-sponsored'),
    placement: 'webpage-network',
    pageKey: 'ajm-marketplace'
})).catch(() => {});
