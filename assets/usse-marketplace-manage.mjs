import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.108.2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './usse-public-config.mjs';
import { MARKET_CATEGORIES, MARKET_SEGMENTS, MINI_AD_MAX_SECONDS, MINI_AD_MAX_BYTES, escapeHtml as e, marketCard, validateMarketImage } from './usse-marketplace-core.mjs?v=taxonomy2';
import { placementLabel } from './usse-banner-core.mjs';

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = id => document.getElementById(id);
const form = $('market-flyer-form');
const editForm = $('market-edit-form');
const editDialog = $('market-edit-flyer');
const flyerFields = ['business_name', 'title', 'tagline', 'category', 'segment', 'contact_url'];
const quickDefaults = {
    business_name: 'Business details on flyer',
    title: 'Marketplace flyer',
    tagline: 'See the flyer for details.',
    category: 'General'
};

let admin = false, user = null, file = null, format = null, preview = null, attempt = null;
let offset = 0, packages = [], trials = [], trialAttempt = null, busy = false, imageSequence = 0;
let flyers = new Map(), editFlyer = null, savingEdit = false;

const date = value => value
    ? new Date(value).toLocaleString('en-JM', { timeZone: 'America/Jamaica', dateStyle: 'medium', timeStyle: 'short' })
    : 'Not active';

function note(message, error = false) {
    $('manage-notice').textContent = message;
    $('manage-notice').dataset.error = String(error);
}

async function rpc(fn, action, payload = {}) {
    const { data, error } = await sb.rpc(fn, { p_action: action, p_payload: payload });
    if (error) throw new Error(error.message);
    return data;
}

async function validateVideoDraft(id) {
    const { error } = await sb.functions.invoke('marketplace-validate-video', { body: { id } });
    if (error) {
        const details = await error.context?.json?.().catch(() => null);
        throw new Error(details?.error || 'Could not verify the mini-ad. Retry or choose a new clip.');
    }
}

let marketSegments = MARKET_SEGMENTS;
let marketCategories = MARKET_CATEGORIES;
try {
    const response = await fetch('/business-taxonomy.json', { cache: 'no-store' });
    if (!response.ok) throw new Error('Category service unavailable');
    const data = await response.json();
    if (data.marketplace && !Array.isArray(data.marketplace)) {
        marketSegments = data.marketplace;
        marketCategories = Object.keys(marketSegments);
    }
} catch {
    note('Using the saved category list. Refresh to check for newly added choices.');
}

const categoryOptions = marketCategories.map(category => `<option>${e(category)}</option>`).join('');
form.elements.category.innerHTML = '<option value="">Choose a category</option>' + categoryOptions;
editForm.elements.category.innerHTML = categoryOptions;

function updateSegments(target, value = '', preserveExisting = false) {
    const segments = marketSegments[target.elements.category.value] || [];
    const select = target.elements.segment;
    select.innerHTML = '<option value="">No subsegment</option>' +
        segments.map(segment => `<option>${e(segment)}</option>`).join('');
    if (preserveExisting && value && !segments.includes(value)) select.append(new Option(value + ' (existing choice)', value));
    select.disabled = segments.length === 0 && !(preserveExisting && value);
    select.value = segments.includes(value) || preserveExisting ? value : '';
}

for (const target of [form, editForm]) {
    target.elements.category.addEventListener('change', () => updateSegments(target));
    updateSegments(target);
}

function readFlyerFields(source) {
    return Object.fromEntries(flyerFields.map(name => [name, source.elements[name].value.trim()]));
}

function configureFlyerForm() {
    const details = $('market-flyer-details');
    details.open = !admin;
    $('market-details-summary').textContent = admin ? 'Flyer details (optional)' : 'Flyer details';
    for (const name of Object.keys(quickDefaults)) form.elements[name].required = !admin;
    if (admin) form.elements.category.value = quickDefaults.category;
    updateSegments(form);
}

function clearFile() {
    file = null;
    format = null;
    attempt = null;
    form.elements.image.value = '';
    if (preview) URL.revokeObjectURL(preview);
    preview = null;
    $('market-preview').hidden = true;
    $('market-preview').removeAttribute('src');
    const video = $('market-video-preview');
    video.hidden = true;
    video.removeAttribute('src');
    video.load();
    if (admin) $('market-flyer-save').textContent = 'Publish poster';
}

async function pick(next) {
    if (busy) return;
    const sequence = ++imageSequence;
    clearFile();
    $('market-new-flyer-link').hidden = true;
    try {
        const isVideo = next && (next.type === 'video/mp4' || /\.mp4$/i.test(next.name));
        if (isVideo && (!next.size || next.size > MINI_AD_MAX_BYTES)) {
            throw new Error('Choose an MP4 up to 20 MB.');
        }
        const valid = isVideo ? { mime: 'video/mp4', file_size: next.size } : await validateMarketImage(next);
        if (!isVideo && typeof createImageBitmap === 'function') {
            const bitmap = await createImageBitmap(next);
            const allowed = bitmap.width > 0 && bitmap.height > 0 && bitmap.width * bitmap.height <= 24000000;
            bitmap.close();
            if (!allowed) throw new Error('Choose an image under 24 megapixels.');
        }
        if (sequence !== imageSequence) return;
        file = next;
        format = valid;
        preview = URL.createObjectURL(file);
        const player = isVideo ? $('market-video-preview') : $('market-preview');
        if (isVideo) {
            player.onloadedmetadata = () => {
                if (sequence !== imageSequence) return;
                if (!Number.isFinite(player.duration) || player.duration > MINI_AD_MAX_SECONDS) {
                    clearFile();
                    $('market-flyer-result').textContent = 'Mini-ads can be at most 15 seconds long.';
                }
            };
            player.onerror = () => {
                if (sequence !== imageSequence || !file) return;
                clearFile();
                $('market-flyer-result').textContent = 'This video could not be played. Try exporting it as H.264 MP4.';
            };
        }
        player.src = preview;
        player.hidden = false;
        if (admin) $('market-flyer-save').textContent = isVideo ? 'Publish mini-ad' : 'Publish poster';
        $('market-flyer-result').textContent = admin
            ? 'Ready to post. Check the classification and confirm permission before publishing.'
            : 'Complete the business details and confirm permission before submitting.';
    } catch (error) {
        if (sequence !== imageSequence) return;
        clearFile();
        $('market-flyer-result').textContent = error.message;
    }
}

form.elements.image.onchange = () => pick(form.elements.image.files[0]);
const drop = $('market-drop');
drop.addEventListener('dragover', event => {
    event.preventDefault();
    if (!busy) drop.dataset.drag = 'true';
});
drop.addEventListener('dragleave', () => delete drop.dataset.drag);
drop.addEventListener('drop', event => {
    event.preventDefault();
    delete drop.dataset.drag;
    pick(event.dataTransfer.files[0]);
});
drop.addEventListener('paste', event => {
    const item = [...event.clipboardData.items].find(entry => entry.kind === 'file' && entry.type.startsWith('image/'));
    if (item) {
        event.preventDefault();
        pick(item.getAsFile());
    }
});

form.addEventListener('invalid', event => {
    const details = $('market-flyer-details');
    if (details.contains(event.target)) details.open = true;
}, true);

form.onsubmit = async event => {
    event.preventDefault();
    if (busy || !user) return;
    const button = $('market-flyer-save');
    const notice = $('market-flyer-result');
    const liveLink = $('market-new-flyer-link');

    try {
        if (!file || !format) throw new Error('Choose an image or MP4 first.');
        const fields = readFlyerFields(form);
        if (admin) {
            for (const [name, fallback] of Object.entries(quickDefaults)) {
                if (!fields[name]) fields[name] = fallback;
            }
        }

        const payload = {
            ...fields,
            display_days: form.elements.display_days.value,
            permission_confirmed: form.elements.permission_confirmed.checked,
            ajm_sponsored: admin && form.elements.ajm_sponsored.checked,
            ...format
        };
        const key = JSON.stringify(payload);
        if (!attempt || attempt.key !== key) {
            attempt = {
                key,
                payload: { ...payload, id: crypto.randomUUID(), request_id: crypto.randomUUID() },
                uploaded: false
            };
        }

        busy = true;
        button.disabled = true;
        form.elements.image.disabled = true;
        liveLink.hidden = true;
        notice.textContent = 'Uploading and checking your flyer…';
        const upload = attempt;
        const artwork = file;
        const reserved = await rpc('manage_marketplace', 'reserve', upload.payload);
        if (!upload.uploaded) {
            const { error } = await sb.storage.from('marketplace-flyers').upload(reserved.path, artwork, {
                contentType: upload.payload.mime,
                upsert: false
            });
            if (error && !['409', 'Duplicate'].includes(String(error.statusCode || error.error))) {
                throw new Error('The upload did not finish. Keep this image selected and submit again to retry.');
            }
            upload.uploaded = true;
        }
        if (upload.payload.mime === 'video/mp4' && reserved.status === 'draft') {
            notice.textContent = 'Checking the mini-ad duration and format…';
            await validateVideoDraft(upload.payload.id);
        }
        const result = await rpc('manage_marketplace', 'submit', { id: upload.payload.id });
        notice.textContent = result.status === 'published'
            ? 'Your post is live. Use Edit post in the register to update the details.'
            : 'Your flyer is awaiting AJM review. Its display period starts on approval.';
        if (result.status === 'published') {
            liveLink.href = '/marketplace?id=' + encodeURIComponent(result.id);
            liveLink.hidden = false;
        }

        form.reset();
        clearFile();
        configureFlyerForm();
        offset = 0;
        await loadFlyers().catch(() => note('Flyer saved. Use Refresh to update the register.', true));
    } catch (error) {
        notice.textContent = error.message;
        if (attempt?.uploaded) await loadFlyers().catch(() => {});
    } finally {
        busy = false;
        button.disabled = false;
        form.elements.image.disabled = false;
    }
};

function registerCard(flyer, imageUrl) {
    const status = flyer.status;
    let schedule = 'Display period: ' + e(flyer.display_days) + ' days from approval';
    if (status === 'draft') schedule = 'Draft: image upload must finish before submission.';
    if (status === 'published') schedule = e(date(flyer.published_at)) + ' – ' + e(date(flyer.expires_at));

    const review = admin && status === 'pending' ? `
        <label>Review note<textarea data-review-note maxlength="1000" placeholder="Required when returning a flyer"></textarea></label>
        <div class="market-actions">
            <button data-action="publish">Approve &amp; publish</button>
            <button data-action="reject">Return flyer</button>
        </div>` : '';
    const published = status === 'published' ? `
        ${Date.parse(flyer.expires_at) > Date.now() ? `<a href="/marketplace?id=${encodeURIComponent(flyer.id)}">Open public share page ↗</a>` : ''}` : '';

    return `<div>
        ${marketCard(flyer, { manage: true, imageUrl })}
        <div class="review-actions" data-flyer="${e(flyer.id)}">
            ${flyer.review_note ? `<p>${e(flyer.review_note)}</p>` : ''}
            <p>${schedule}</p>
            ${review}
            ${published}
            ${canEditPost(flyer) ? '<button class="primary" data-action="edit">Edit post</button>' : ''}
            ${status === 'draft' ? '<button data-action="submit">Submit saved draft</button>' : ''}
            ${!['withdrawn', 'rejected'].includes(status) ? '<button data-action="withdraw">Withdraw flyer</button>' : ''}
        </div>
    </div>`;
}

async function loadFlyers() {
    const activeUser = user;
    const { rows } = await rpc('manage_marketplace', 'list', { offset });
    let urls = new Map();
    if (rows.length) {
        const { data: signed } = await sb.storage.from('marketplace-flyers').createSignedUrls(rows.map(row => row.image_path), 300);
        urls = new Map((signed || []).map(entry => [entry.path, entry.signedUrl]));
    }
    if (activeUser !== user) return;

    flyers = new Map(rows.map(flyer => [flyer.id, flyer]));
    $('manage-flyers').innerHTML = rows.length
        ? rows.map(row => registerCard(row, urls.get(row.image_path) || '')).join('')
        : '<div class="market-empty"><h3>No flyers yet.</h3><p>Upload a real business flyer above to begin.</p></div>';
    $('manage-prev').disabled = offset === 0;
    $('manage-next').disabled = rows.length < 100;
    $('manage-count').textContent = rows.length ? `${offset + 1}–${offset + rows.length}` : '0 flyers';
}

function canEditPost(flyer) {
    return Boolean(flyer && (admin || flyer.owner_id === user?.id) &&
        ['draft', 'pending', 'published'].includes(flyer.status) &&
        (!flyer.published_at || Date.parse(flyer.expires_at) > Date.now()));
}

function openFlyerEditor(flyer) {
    if (!canEditPost(flyer) || editDialog.open) return;
    editFlyer = flyer;
    editForm.elements.category.innerHTML = categoryOptions;
    if (flyer.category && !marketCategories.includes(flyer.category)) {
        editForm.elements.category.append(new Option(flyer.category + ' (existing choice)', flyer.category));
    }
    for (const name of flyerFields) editForm.elements[name].value = flyer[name] || '';
    updateSegments(editForm, flyer.segment, true);
    $('market-edit-help').textContent = !admin && flyer.status === 'published'
        ? 'Saving changes sends this post back to AJM for review. It will return to the same link once approved.'
        : 'Update the text, classification or contact link for this post.';
    $('market-edit-result').textContent = '';
    editDialog.showModal();
}

$('market-edit-cancel').onclick = () => editDialog.close();
editDialog.addEventListener('cancel', event => {
    if (savingEdit) event.preventDefault();
});
editDialog.addEventListener('close', () => {
    editFlyer = null;
    editForm.reset();
});
editForm.onsubmit = async event => {
    event.preventDefault();
    if (!canEditPost(editFlyer) || savingEdit) return;
    const id = editFlyer.id;
    const controls = editForm.querySelectorAll('button');
    const notice = $('market-edit-result');
    savingEdit = true;
    controls.forEach(button => { button.disabled = true; });
    notice.textContent = 'Saving changes…';

    try {
        const result = await rpc('manage_marketplace', 'edit', {
            ...readFlyerFields(editForm),
            id,
            expected_updated_at: editFlyer.updated_at
        });
        editDialog.close();
        note(result.status === 'pending' ? 'Post details saved. The post is awaiting AJM review.' : 'Post details saved.');
        try {
            await loadFlyers();
            $('manage-flyers').querySelector(`[data-flyer="${CSS.escape(id)}"] [data-action="edit"]`)?.focus();
        } catch {
            note('Flyer details saved. Use Refresh to update the register.', true);
        }
    } catch (error) {
        notice.textContent = error.message;
    } finally {
        savingEdit = false;
        controls.forEach(button => { button.disabled = false; });
    }
};

$('manage-flyers').onclick = async event => {
    const button = event.target.closest('[data-action]');
    const row = button?.closest('[data-flyer]');
    if (!row) return;
    const action = button.dataset.action;
    if (action === 'edit') {
        openFlyerEditor(flyers.get(row.dataset.flyer));
        return;
    }

    button.disabled = true;
    try {
        const review = action === 'publish' || action === 'reject';
        if (action === 'submit' && flyers.get(row.dataset.flyer)?.mime === 'video/mp4') {
            await validateVideoDraft(row.dataset.flyer);
        }
        await rpc('manage_marketplace', review ? 'review' : action, {
            id: row.dataset.flyer,
            status: action === 'publish' ? 'published' : 'rejected',
            note: row.querySelector('[data-review-note]')?.value || ''
        });
        note('Flyer updated.');
        await loadFlyers();
    } catch (error) {
        note(error.message, true);
    } finally {
        button.disabled = false;
    }
};

function trialFields(){const f=$('trial-form'),p=packages.find(p=>p.id===f.elements.package_id.value),display=p?.type==='display_ad';$('trial-creative').hidden=!display;for(const name of['headline','body_text','media_url','cta_url','banner_size']){f.elements[name].disabled=!display;f.elements[name].required=display;}f.elements.duration_days.querySelector('[value="15"]').disabled=display;if(display)f.elements.duration_days.value='30';$('trial-placements').textContent='Current package positions: '+(p?.placements||[]).map(placementLabel).join(' · ')+'. These positions are snapshotted when the trial starts.';}
async function loadTrials(){const data=await rpc('manage_ajm_trials','list');trials=data.rows;$('trial-report-period').textContent=`Activity: ${data.report_from} through ${data.report_to} (UTC, last 30 days). Run dates below use Jamaica time. Complimentary trials generate no sales revenue.`;$('trial-list').innerHTML=trials.length?trials.map(t=>`<article class="market-card trial-card"><span class="market-tag">Complimentary · ${e(t.status)}</span><span class="market-tag">${e(t.cohort)}</span><h3>${e(t.business_name)}</h3><p>${e(t.package_snapshot.name)}</p><p>${e(date(t.starts_at))} – ${e(date(t.expires_at))}</p><p>${Number(t.impressions)} views · ${Number(t.clicks)} clicks · ${Number(t.leads)} actions</p><div class="market-actions"><a class="button" href="/ajm-webpage-builder?listing=${encodeURIComponent(t.listing_id)}">Open webpage studio</a>${t.status==='active'?`<button data-end-trial="${e(t.id)}">End this trial</button>`:''}</div></article>`).join(''):'<div class="market-empty"><h3>No trials activated.</h3><p>Choose confirmed businesses and package details above. No customers have been enrolled automatically.</p></div>';$('trial-coverage').innerHTML=packages.map(p=>{const active=trials.filter(t=>t.status==='active'&&t.package_snapshot.name===p.name);return`<article><strong>${e(p.name)}</strong><span>${active.length?'Live demonstration: '+active.map(t=>e(t.business_name)).join(', '):'Awaiting a confirmed candidate'}</span></article>`;}).join('');}
$('trial-form').elements.package_id.onchange=trialFields;
$('trial-form').onsubmit=async ev=>{ev.preventDefault();const f=ev.currentTarget,b=f.querySelector('button');if(b.disabled)return;try{b.disabled=true;const payload=Object.fromEntries(new FormData(f));payload.consent=f.elements.consent.checked;const key=JSON.stringify(payload);if(!trialAttempt||trialAttempt.key!==key)trialAttempt={key,payload:{...payload,id:crypto.randomUUID()}};const result=await rpc('manage_ajm_trials','activate',trialAttempt.payload);$('trial-result').textContent='Complimentary trial active until '+date(result.expires_at)+'. No payment or automatic renewal.';trialAttempt=null;f.elements.consent.checked=false;await loadTrials();}catch(error){$('trial-result').textContent=error.message;}finally{b.disabled=false;}};
$('trial-list').onclick=async ev=>{const b=ev.target.closest('[data-end-trial]');if(!b)return;b.disabled=true;try{await rpc('manage_ajm_trials','end',{id:b.dataset.endTrial});await loadTrials();note('Trial ended. Existing paid subscriptions remain in place.');}catch(error){note(error.message,true);b.disabled=false;}};
async function init(){try{const{data:{user:current},error}=await sb.auth.getUser();if(error||!current){user=null;$('market-login').hidden=false;$('market-workspace').hidden=true;$('market-signout').hidden=true;note('Sign in with a verified account to submit flyers.');return;}const{data:p,error:profileError}=await sb.from('profiles').select('role,account_status').eq('id',current.id).maybeSingle();if(profileError)throw profileError;if(p?.account_status!=='active'||!current.email_confirmed_at)throw new Error('An active account and confirmed email are required.');user=current;admin=p.role==='admin';$('market-login').hidden=true;$('market-workspace').hidden=false;$('market-signout').hidden=false;$('trial-workspace').hidden=!admin;$('trial-nav').hidden=!admin;$('category-nav').hidden=!admin;$('sponsored-option').hidden=!admin;$('market-flyer-save').textContent=admin?'Publish poster':'Submit for review';configureFlyerForm();$('flyer-register-title').textContent=admin?'All Marketplace flyers':'Your flyers';if(admin)$('flyer-rule').textContent='Publish a poster or mini-ad directly. Select a category and subsegment now, or edit the post later from the register.';if(location.hash==='#flyer-editor')$('market-flyer-heading').focus();await loadFlyers();if(admin){const c=await rpc('manage_ajm_trials','catalog');packages=c.packages;const f=$('trial-form');f.elements.listing_id.innerHTML='<option value="">Choose a confirmed business</option>'+c.listings.map(l=>`<option value="${e(l.id)}">${e(l.name)}</option>`).join('');f.elements.package_id.innerHTML='<option value="">Choose a package</option>'+packages.map(p=>`<option value="${e(p.id)}">${e(p.name)} · ${e(p.type)}</option>`).join('');trialFields();await loadTrials();}note(admin?'Administrator workspace ready. Review flyers or activate agreed complimentary trials.':'Your Marketplace workspace is ready.');}catch(error){note(error.message,true);}}
$('market-login-form').onsubmit=async ev=>{ev.preventDefault();const f=ev.currentTarget,b=f.querySelector('button');b.disabled=true;try{const{error}=await sb.auth.signInWithPassword({email:f.elements.email.value.trim(),password:f.elements.password.value});if(error)throw error;f.elements.password.value='';await init();}catch(error){note(error.message,true);}finally{b.disabled=false;}};
$('market-signout').onclick=async()=>{await sb.auth.signOut();};sb.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'){user=null;admin=false;packages=[];trials=[];flyers.clear();if(editDialog.open)editDialog.close();imageSequence++;clearFile();$('manage-flyers').replaceChildren();$('trial-list').replaceChildren();$('market-workspace').hidden=true;$('market-login').hidden=false;$('market-signout').hidden=true;note('Signed out.');}});
$('manage-refresh').onclick=async()=>{try{await loadFlyers();if(admin)await loadTrials();note('Workspace refreshed.');}catch(error){note(error.message,true);}};$('manage-prev').onclick=()=>{offset=Math.max(0,offset-100);loadFlyers().catch(err=>note(err.message,true));};$('manage-next').onclick=()=>{offset+=100;loadFlyers().catch(err=>note(err.message,true));};window.addEventListener('pagehide',()=>{if(preview)URL.revokeObjectURL(preview);});await init();
