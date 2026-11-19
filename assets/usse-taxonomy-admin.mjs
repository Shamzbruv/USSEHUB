import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.108.2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './usse-public-config.mjs';
import { escapeHtml as e } from './usse-marketplace-core.mjs?v=taxonomy2';

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = id => document.getElementById(id);
const form = $('taxonomy-add-form');
let catalogue = null;
let allChoices = null;
let hiddenChoices = [];
let pendingRemoval = null;
let authorized = false;
let saving = false;
let authVersion = 0;

function notice(message, error = false) {
    $('taxonomy-notice').textContent = message;
    $('taxonomy-notice').dataset.error = String(error);
}

function setOptions(select, choices, placeholder) {
    const previous = select.value;
    select.replaceChildren(new Option(placeholder, ''), ...choices.map(value => new Option(value, value)));
    select.value = choices.includes(previous) ? previous : '';
}

function parentPath() {
    return ['category', 'secondary', 'tertiary'].slice(0, Number(form.elements.level.value) - 1)
        .map(name => form.elements[name].value);
}

function updateParents() {
    if (!catalogue) return;
    const { scope, level, category, secondary, tertiary } = form.elements;
    const source = catalogue[scope.value];
    const depth = Number(level.value);
    setOptions(category, Object.keys(source), 'Choose a category');
    setOptions(secondary, scope.value === 'directory' ? Object.keys(source[category.value] || {}) : [], 'Choose a subcategory');
    setOptions(tertiary, source[category.value]?.[secondary.value]?.tertiary || [], 'Choose a specialization');
    for (const [index, name] of ['category', 'secondary', 'tertiary'].entries()) {
        const needed = index < depth - 1;
        form.elements[name].disabled = !needed;
        form.elements[name].required = needed;
        $('taxonomy-' + name + '-field').hidden = !needed;
    }
    $('taxonomy-placement').textContent = depth === 1 ? 'This choice will appear as a main category.'
        : 'Add under ' + (parentPath().filter(Boolean).join(' › ') || 'the parent you choose above') + '.';
    render();
}

function changeScope() {
    const levels = form.elements.scope.value === 'marketplace'
        ? ['Category', 'Subsegment'] : ['Category', 'Subcategory', 'Specialization', 'Specific type'];
    form.elements.level.replaceChildren(...levels.map((name, index) => new Option(name, String(index + 1))));
    form.elements.level.value = '2';
    for (const name of ['category', 'secondary', 'tertiary']) form.elements[name].value = '';
    updateParents();
}

function choiceValue(source, path) {
    const parent = path.slice(0, -1).reduce((value, key) => value?.[key], source);
    return Array.isArray(parent) ? parent.find(value => value === path.at(-1)) : parent?.[path.at(-1)];
}

function isRemoved(scope, path) {
    return hiddenChoices.some(choice => choice.scope === scope && choice.path.length === path.length &&
        choice.path.every((name, index) => name === path[index]));
}

function choiceRow(scope, path, label) {
    const removed = isRemoved(scope, path);
    const action = removed ? 'restore' : 'remove';
    return `<div class="taxonomy-choice${removed ? ' taxonomy-removed' : ''}"><span>${e(label)}${removed ? ' <small>Removed</small>' : ''}</span>
        <button type="button" data-taxonomy-action="${action}" data-path="${e(JSON.stringify(path))}" aria-label="${removed ? 'Restore' : 'Remove'} ${e(label)}">${removed ? 'Restore' : 'Remove'}</button></div>`;
}

function render() {
    if (!allChoices) return;
    const scope = form.elements.scope.value;
    const source = allChoices[scope];
    const query = $('taxonomy-search').value.trim().toLocaleLowerCase();
    const rows = Object.entries(source).filter(([category, children]) =>
        JSON.stringify([category, children]).toLocaleLowerCase().includes(query));
    const openCategories = new Set([...$('taxonomy-list').querySelectorAll('details[open]')].map(node => node.dataset.category));
    $('taxonomy-list').innerHTML = rows.map(([category, children]) => {
        const removed = isRemoved(scope, [category]);
        let content = '';
        if (!removed && Array.isArray(children)) {
            content = children.map(name => choiceRow(scope, [category, name], name)).join('');
        } else if (!removed) {
            content = Object.entries(children).map(([name, group]) => {
                let choices = '';
                if (!isRemoved(scope, [category, name])) {
                    choices = ['tertiary', 'specific', 'qualifiers'].map(kind => (group[kind] || []).map(value =>
                        choiceRow(scope, [category, name, kind, value], value)).join('')).join('');
                }
                return `<section class="taxonomy-subgroup">${choiceRow(scope, [category, name], name)}<div class="taxonomy-subchoices">${choices}</div></section>`;
            }).join('');
        }
        return `<details data-category="${e(category)}"${query || openCategories.has(category) ? ' open' : ''}>
            <summary>${e(category)}${removed ? ' · Removed' : ''}</summary>
            ${choiceRow(scope, [category], category)}${content}</details>`;
    }).join('') || '<p>No matching choices.</p>';
}

function acceptState(data) {
    catalogue = data.catalogue;
    allChoices = data.all;
    hiddenChoices = data.hidden;
    updateParents();
}

async function refresh(version = authVersion) {
    const { data, error } = await sb.rpc('manage_business_taxonomy', {
        p_action: 'list', p_scope: form.elements.scope.value
    });
    if (version !== authVersion) return false;
    if (error) throw new Error('The category editor could not load. Please refresh and try again.');
    acceptState(data);
    return true;
}

async function changeChoice(action, path, expected = null) {
    if (!authorized || saving) return;
    const version = authVersion;
    const scope = form.elements.scope.value;
    const name = path.at(-1);
    saving = true;
    form.querySelectorAll('input,select,button').forEach(control => { control.disabled = true; });
    $('taxonomy-list').inert = true;
    $('taxonomy-remove-confirm').disabled = true;
    $('taxonomy-remove-cancel').disabled = true;
    try {
        const { data, error } = await sb.rpc('manage_business_taxonomy', {
            p_action: action, p_scope: scope, p_path: path, p_expected: expected
        });
        if (error) throw error;
        if (version !== authVersion || !authorized) return;
        acceptState(data);
        $('taxonomy-remove-dialog').close();
        notice(name + (action === 'remove' ? ' removed from new posting choices. Existing posts keep their classification.' : ' restored to posting choices.'));
    } catch (error) {
        notice(error.message, true);
        $('taxonomy-remove-result').textContent = error.message;
    } finally {
        saving = false;
        $('taxonomy-list').inert = false;
        $('taxonomy-remove-confirm').disabled = false;
        $('taxonomy-remove-cancel').disabled = false;
        form.querySelectorAll('input,select,button').forEach(control => { control.disabled = false; });
        if (authorized) updateParents();
    }
}

$('taxonomy-list').onclick = event => {
    const button = event.target.closest('[data-taxonomy-action]');
    if (!button || saving || !authorized) return;
    const path = JSON.parse(button.dataset.path);
    if (button.dataset.taxonomyAction === 'restore') {
        changeChoice('restore', path);
        return;
    }
    const scope = form.elements.scope.value;
    pendingRemoval = { path, expected: choiceValue(allChoices[scope], path) };
    $('taxonomy-remove-title').textContent = 'Remove ' + path.at(-1) + '?';
    $('taxonomy-remove-description').textContent = path.length === 1 || scope === 'directory' && path.length === 2
        ? 'This removes the category and its subchoices from new posting forms. Existing posts keep their classification. You can restore it here.'
        : 'This removes the choice from new posting forms. Existing posts keep their classification. You can restore it here.';
    $('taxonomy-remove-result').textContent = '';
    $('taxonomy-remove-dialog').showModal();
};
$('taxonomy-remove-confirm').onclick = () => {
    if (pendingRemoval) changeChoice('remove', pendingRemoval.path, pendingRemoval.expected);
};
$('taxonomy-remove-cancel').onclick = () => $('taxonomy-remove-dialog').close();
$('taxonomy-remove-dialog').addEventListener('cancel', event => { if (saving) event.preventDefault(); });
$('taxonomy-remove-dialog').addEventListener('close', () => { pendingRemoval = null; });

form.elements.scope.onchange = changeScope;
for (const name of ['level', 'category', 'secondary', 'tertiary']) form.elements[name].onchange = updateParents;
$('taxonomy-search').oninput = render;
$('taxonomy-refresh').onclick = async () => {
    try { await refresh(); notice('Choices refreshed.'); }
    catch (error) { notice(error.message, true); }
};
form.onsubmit = async event => {
    event.preventDefault();
    if (!authorized || saving) return;
    saving = true;
    const scope = form.elements.scope.value;
    const name = form.elements.name.value.trim();
    const parent = parentPath();
    form.querySelectorAll('input,select,button').forEach(control => { control.disabled = true; });
    $('taxonomy-result').textContent = 'Saving…';
    try {
        const { error } = await sb.rpc('add_business_taxonomy_entry', {
            p_scope: scope, p_parent: parent, p_name: name
        });
        if (error) throw error;
        if (!authorized) return;
        await refresh();
        form.elements.name.value = '';
        $('taxonomy-result').textContent = name + ' is available. Refresh any open posting form to use it.';
        notice('Category catalogue updated.');
    } catch (error) {
        $('taxonomy-result').textContent = error.message;
    } finally {
        saving = false;
        form.querySelectorAll('input,select,button').forEach(control => { control.disabled = false; });
        if (authorized) updateParents();
    }
};

async function init() {
    const version = ++authVersion;
    authorized = false;
    $('taxonomy-workspace').hidden = true;
    try {
        const { data: { user }, error } = await sb.auth.getUser();
        if (version !== authVersion) return;
        if (error || !user) {
            $('taxonomy-login').hidden = false;
            notice('Sign in to manage categories and subsegments.');
            return;
        }
        const { data: profile, error: profileError } = await sb.from('profiles')
            .select('role,account_status').eq('id', user.id).maybeSingle();
        if (version !== authVersion) return;
        if (profileError || profile?.role !== 'admin' || profile.account_status !== 'active' || !user.email_confirmed_at) {
            throw new Error('An active administrator account with a confirmed email is required.');
        }
        $('taxonomy-login').hidden = true;
        if (!await refresh(version)) return;
        authorized = true;
        $('taxonomy-workspace').hidden = false;
        changeScope();
        notice('Choose a catalogue to add, remove or restore categories and subsegments.');
    } catch (error) {
        notice(error.message, true);
    }
}
$('taxonomy-login-form').onsubmit = async event => {
    event.preventDefault();
    const target = event.currentTarget;
    const button = target.querySelector('button');
    button.disabled = true;
    try {
        const { error } = await sb.auth.signInWithPassword({ email: target.elements.email.value.trim(), password: target.elements.password.value });
        if (error) throw error;
        target.elements.password.value = '';
        await init();
    } catch (error) { notice(error.message, true); }
    finally { button.disabled = false; }
};
sb.auth.onAuthStateChange(event => {
    if (event === 'SIGNED_OUT') {
        authVersion++;
        authorized = false;
        catalogue = null;
        allChoices = null;
        hiddenChoices = [];
        $('taxonomy-remove-dialog').close();
        $('taxonomy-workspace').hidden = true;
        $('taxonomy-login').hidden = false;
        $('taxonomy-list').replaceChildren();
        notice('Signed out.');
    }
});
await init();
